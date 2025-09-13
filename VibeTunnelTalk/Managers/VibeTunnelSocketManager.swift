import Foundation
import Network
import Combine
import OSLog

class VibeTunnelSocketManager: ObservableObject {
    private let logger = AppLogger.socketManager
    
    @Published var isConnected = false
    @Published var currentSessionId: String?
    let terminalOutput = PassthroughSubject<String, Never>()
    
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "vibetunnel.socket", qos: .userInitiated)
    
    // SSE client for terminal output streaming
    private var sseClient: VibeTunnelSSEClient?
    private var sseSubscription: AnyCancellable?
    
    /// Find available VibeTunnel sessions
    func findAvailableSessions() -> [String] {
        // Now that we're not sandboxed, this returns the real home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let controlPath = homeDir + "/.vibetunnel/control"
        let fm = FileManager.default
        
        // Silently discover sessions
        
        // Check if .vibetunnel directory exists
        let vibetunnelPath = homeDir + "/.vibetunnel"
        if !fm.fileExists(atPath: vibetunnelPath) {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ .vibetunnel directory does not exist at: \(vibetunnelPath)")
            return []
        }
        // Found .vibetunnel directory
        
        // Check if control directory exists
        if !fm.fileExists(atPath: controlPath) {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Control directory does not exist at: \(controlPath)")
            
            // List what's in .vibetunnel directory for debugging
            if let vibetunnelContents = try? fm.contentsOfDirectory(atPath: vibetunnelPath) {
                logger.debug("[VIBETUNNEL-DISCOVERY] Contents of .vibetunnel: \(vibetunnelContents.joined(separator: ", "))")
            }
            return []
        }
        // Found control directory
        
        // Get contents of control directory
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Failed to read contents of control directory at: \(controlPath)")
            return []
        }
        
        // Found items in control directory
        
        // Filter for directories that contain an ipc.sock file
        let validSessions = contents.filter { sessionId in
            let sessionPath = "\(controlPath)/\(sessionId)"
            let socketPath = "\(sessionPath)/ipc.sock"
            
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: sessionPath, isDirectory: &isDirectory)
            
            if !exists || !isDirectory.boolValue {
                // Not a directory
                return false
            }
            
            // Check for ipc.sock file
            let hasSocket = fm.fileExists(atPath: socketPath)
            if hasSocket {
                // Found valid session
            } else {
                // No socket file
            }
            
            return hasSocket
        }
        
        if validSessions.isEmpty {
            logger.warning("[VIBETUNNEL] No active sessions found")
        }
        return validSessions
    }
    
    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = homeDir + "/.vibetunnel/control/\(sessionId)/ipc.sock"
        
        logger.info("[VIBETUNNEL] Connecting to session: \(sessionId)")
        
        // Create Unix domain socket endpoint
        let endpoint = NWEndpoint.unix(path: socketPath)
        
        // Use .tcp parameters for Unix domain socket (this is correct in Network.framework)
        let parameters = NWParameters.tcp
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        
        connection?.start(queue: queue)
        currentSessionId = sessionId
        
        // Also start SSE client for terminal output
        startSSEClient(sessionId: sessionId)
    }
    
    private func startSSEClient(sessionId: String) {
        
        // Create and configure SSE client
        sseClient = VibeTunnelSSEClient()
        
        // Subscribe to terminal output from SSE
        sseSubscription = sseClient?.terminalOutput
            .sink { [weak self] output in
                // Only log very large output chunks for debugging
                if output.count > 1000 {
                    self?.logger.debug("[VIBETUNNEL] 📥 Large SSE chunk: \(output.count) chars")
                }

                // Remove ANSI escape codes for cleaner processing
                let cleanText = self?.removeANSIEscapeCodes(from: output) ?? output

                // Forward to our terminal output subject
                self?.terminalOutput.send(cleanText)
            }
        
        // Connect to SSE stream
        sseClient?.connect(sessionId: sessionId)
    }
    
    /// Disconnect from current session
    func disconnect() {
        
        // Stop IPC socket connection
        connection?.cancel()
        connection = nil
        
        // Stop SSE client
        sseClient?.disconnect()
        sseClient = nil
        sseSubscription?.cancel()
        sseSubscription = nil
        
        isConnected = false
        currentSessionId = nil
    }
    
    /// Send input to the terminal
    func sendInput(_ text: String) {
        guard isConnected else {
            logger.warning("[VIBETUNNEL-SOCKET] ⚠️ Cannot send input - not connected")
            return
        }
        
        let message = IPCMessage.createStdinData(text)
        
        // Sending input
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL] Failed to send input: \(error.localizedDescription)")
            } else {
                // Input sent
            }
        })
    }
    
    /// Request terminal to refresh/resend current buffer content
    func requestRefresh() {
        guard isConnected else {
            logger.warning("[VIBETUNNEL-SOCKET] ⚠️ Cannot request refresh - not connected")
            return
        }
        
        logger.info("[VIBETUNNEL-REFRESH] 🔄 Requesting terminal refresh")
        
        // Send a harmless control sequence that should trigger output
        // Ctrl+L is commonly used to refresh/redraw terminal
        let refreshCommand = "\u{000C}"  // Form feed (Ctrl+L)
        sendInput(refreshCommand)
        
        // Also send a resize to current size to trigger redraw
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.resize(cols: 80, rows: 24)
        }
    }
    
    /// Resize terminal
    func resize(cols: Int, rows: Int) {
        guard isConnected else {
            logger.warning("[VIBETUNNEL-SOCKET] ⚠️ Cannot resize - not connected")
            return
        }
        
        let message = IPCMessage.createResize(cols: cols, rows: rows)
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL] ❌ Failed to send resize: \(error.localizedDescription)")
            }
        })
    }
    
    // MARK: - Private Methods
    
    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("[VIBETUNNEL] Connected to session: \(self.currentSessionId ?? "unknown")")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            startReceiving()
            
            // Send initial resize to trigger terminal output
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.resize(cols: 80, rows: 24)
            }
            
        case .failed(let error):
            logger.error("[VIBETUNNEL] Connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .cancelled:
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .preparing, .setup:
            break
            
        case .waiting(let error):
            logger.warning("[VIBETUNNEL] Connection waiting: \(error.localizedDescription)")
            
        @unknown default:
            break
        }
    }
    
    private func startReceiving() {
        
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleReceivedData(data)
            }
            
            if let error = error {
                self?.logger.error("[VIBETUNNEL] Receive error: \(error.localizedDescription)")
            }
            
            // Connection complete
            
            // Continue receiving if no error and connection not complete
            if error == nil && !isComplete {
                self?.startReceiving()
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)
        
        // Process complete messages from buffer
        while receiveBuffer.count >= 8 {
            // Try to parse header
            guard let header = MessageHeader.parse(from: receiveBuffer) else {
                logger.error("[VIBETUNNEL] Failed to parse message header")
                receiveBuffer.removeAll()
                break
            }
            
            // Parsed message header
            
            let totalMessageSize = 5 + Int(header.length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                break
            }
            
            // Extract message payload
            let payload = receiveBuffer[5..<totalMessageSize]
            
            // Process the message
            processMessage(header: header, payload: payload)
            
            // Remove processed message from buffer
            receiveBuffer.removeFirst(totalMessageSize)
        }
    }
    
    private func processMessage(header: MessageHeader, payload: Data) {
        switch header.type {
        case .statusUpdate:
            // Status update (Claude activity, etc.)
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let _ = json["app"] as? String,
               let _ = json["status"] as? String {
                // TODO: Handle status updates and forward to activity monitor
            }
            
        case .error:
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let code = json["code"] as? String,
               let message = json["message"] as? String {
                logger.error("[VIBETUNNEL] Error from server: \(code) - \(message)")
            }
            
        case .heartbeat:
            // Echo heartbeat back
            sendHeartbeat()
            
        case .stdinData, .controlCmd:
            // Unexpected - we send these, not receive
            break
            
        @unknown default:
            break
        }
    }
    
    private func sendHeartbeat() {
        let message = IPCMessage.createHeartbeat()
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL] Failed to send heartbeat: \(error.localizedDescription)")
            }
        })
    }
    
    private func removeANSIEscapeCodes(from text: String) -> String {
        // Remove ANSI escape sequences
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
}