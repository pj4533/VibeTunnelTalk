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
        
        logger.info("[VIBETUNNEL-DISCOVERY] 🔍 Starting session discovery")
        logger.debug("[VIBETUNNEL-DISCOVERY] Home directory: \(homeDir)")
        logger.debug("[VIBETUNNEL-DISCOVERY] Looking for control directory at: \(controlPath)")
        
        // Check if .vibetunnel directory exists
        let vibetunnelPath = homeDir + "/.vibetunnel"
        if !fm.fileExists(atPath: vibetunnelPath) {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ .vibetunnel directory does not exist at: \(vibetunnelPath)")
            return []
        }
        logger.info("[VIBETUNNEL-DISCOVERY] ✅ Found .vibetunnel directory")
        
        // Check if control directory exists
        if !fm.fileExists(atPath: controlPath) {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Control directory does not exist at: \(controlPath)")
            
            // List what's in .vibetunnel directory for debugging
            if let vibetunnelContents = try? fm.contentsOfDirectory(atPath: vibetunnelPath) {
                logger.debug("[VIBETUNNEL-DISCOVERY] Contents of .vibetunnel: \(vibetunnelContents.joined(separator: ", "))")
            }
            return []
        }
        logger.info("[VIBETUNNEL-DISCOVERY] ✅ Found control directory")
        
        // Get contents of control directory
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.error("[VIBETUNNEL-DISCOVERY] ❌ Failed to read contents of control directory at: \(controlPath)")
            return []
        }
        
        logger.info("[VIBETUNNEL-DISCOVERY] 📁 Found \(contents.count) items in control directory: \(contents.joined(separator: ", "))")
        
        // Filter for directories that contain an ipc.sock file
        let validSessions = contents.filter { sessionId in
            let sessionPath = "\(controlPath)/\(sessionId)"
            let socketPath = "\(sessionPath)/ipc.sock"
            
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: sessionPath, isDirectory: &isDirectory)
            
            if !exists || !isDirectory.boolValue {
                logger.debug("[VIBETUNNEL-DISCOVERY] ⏭️ Skipping \(sessionId) - not a directory")
                return false
            }
            
            // Check for ipc.sock file
            let hasSocket = fm.fileExists(atPath: socketPath)
            if hasSocket {
                logger.info("[VIBETUNNEL-DISCOVERY] ✅ Found valid session: \(sessionId) with socket at: \(socketPath)")
            } else {
                logger.debug("[VIBETUNNEL-DISCOVERY] ⏭️ Session \(sessionId) has no ipc.sock file")
                
                // List contents of session directory for debugging
                if let sessionContents = try? fm.contentsOfDirectory(atPath: sessionPath) {
                    logger.debug("[VIBETUNNEL-DISCOVERY] Contents of session \(sessionId): \(sessionContents.joined(separator: ", "))")
                }
            }
            
            return hasSocket
        }
        
        logger.info("[VIBETUNNEL-DISCOVERY] 🎯 Found \(validSessions.count) valid session(s): \(validSessions.joined(separator: ", "))")
        return validSessions
    }
    
    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = homeDir + "/.vibetunnel/control/\(sessionId)/ipc.sock"
        
        logger.info("[VIBETUNNEL-SOCKET] 🔌 Connecting to session \(sessionId) at \(socketPath)")
        
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
        logger.info("[VIBETUNNEL-SSE] 🌊 Starting SSE client for terminal output")
        
        // Create and configure SSE client
        sseClient = VibeTunnelSSEClient()
        
        // Subscribe to terminal output from SSE
        sseSubscription = sseClient?.terminalOutput
            .sink { [weak self] output in
                self?.logger.debug("[VIBETUNNEL-SSE] 📺 Received terminal output via SSE: \(output.count) chars")
                
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
        logger.info("[VIBETUNNEL-SOCKET] 🔌 Disconnecting from session")
        
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
        let messageSize = message.data.count
        
        logger.info("[VIBETUNNEL-TX] 📤 Sending input:")
        logger.info("[VIBETUNNEL-TX]    - Text: \"\(text.replacingOccurrences(of: "\n", with: "\\n"))\"")
        logger.info("[VIBETUNNEL-TX]    - Message size: \(messageSize) bytes")
        logger.info("[VIBETUNNEL-TX]    - Message type: INPUT (0x01)")
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL-TX] ❌ Failed to send input: \(error.localizedDescription)")
            } else {
                self?.logger.info("[VIBETUNNEL-TX] ✅ Successfully sent \(messageSize) bytes")
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
        let messageSize = message.data.count
        
        logger.info("[VIBETUNNEL-TX] 📤 Sending resize:")
        logger.info("[VIBETUNNEL-TX]    - Cols: \(cols), Rows: \(rows)")
        logger.info("[VIBETUNNEL-TX]    - Message size: \(messageSize) bytes")
        logger.info("[VIBETUNNEL-TX]    - Message type: RESIZE (0x03)")
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL-TX] ❌ Failed to send resize: \(error.localizedDescription)")
            } else {
                self?.logger.info("[VIBETUNNEL-TX] ✅ Successfully sent resize (\(messageSize) bytes)")
            }
        })
    }
    
    // MARK: - Private Methods
    
    private func handleStateChange(_ state: NWConnection.State) {
        logger.info("[VIBETUNNEL-STATE] 🔄 State changed to: \(String(describing: state))")
        
        switch state {
        case .ready:
            logger.info("[VIBETUNNEL-STATE] ✅ Socket connected and ready")
            logger.info("[VIBETUNNEL-STATE] 📡 Connection established with session: \(self.currentSessionId ?? "unknown")")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            startReceiving()
            
            // Send initial resize to trigger terminal output
            // Standard terminal size of 80x24 - this will cause VibeTunnel to send current buffer
            logger.info("[VIBETUNNEL-INIT] 📐 Sending initial resize to trigger terminal output")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.resize(cols: 80, rows: 24)
            }
            
        case .failed(let error):
            logger.error("[VIBETUNNEL-STATE] ❌ Connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .cancelled:
            logger.info("[VIBETUNNEL-STATE] 🛑 Connection cancelled")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .preparing:
            logger.info("[VIBETUNNEL-STATE] 🔧 Preparing connection...")
            
        case .setup:
            logger.info("[VIBETUNNEL-STATE] ⚙️ Setting up...")
            
        case .waiting(let error):
            logger.warning("[VIBETUNNEL-STATE] ⏳ Waiting: \(error.localizedDescription)")
            
        @unknown default:
            logger.warning("[VIBETUNNEL-STATE] ⚠️ Unknown state encountered")
            break
        }
    }
    
    private func startReceiving() {
        logger.info("[VIBETUNNEL-RX] 👂 Starting to listen for data...")
        logger.info("[VIBETUNNEL-RX] 🔌 Connection state: \(String(describing: self.connection?.state))")
        
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            // Log receive call details
            self?.logger.debug("[VIBETUNNEL-RX] 📡 Receive callback triggered")
            
            if let data = data, !data.isEmpty {
                self?.logger.info("[VIBETUNNEL-RX] 📥 Received \(data.count) bytes")
                
                // Log first 100 bytes as hex for debugging
                let hexBytes = data.prefix(100).map { String(format: "%02x", $0) }.joined(separator: " ")
                self?.logger.debug("[VIBETUNNEL-RX]    Raw data (first 100 bytes): \(hexBytes)")
                
                // Also try to decode as string for quick preview
                if let preview = String(data: data.prefix(100), encoding: .utf8) {
                    self?.logger.debug("[VIBETUNNEL-RX]    String preview: \"\(preview.replacingOccurrences(of: "\n", with: "\\n"))\"")
                }
                
                self?.handleReceivedData(data)
            } else if data?.isEmpty == true {
                self?.logger.warning("[VIBETUNNEL-RX] ⚠️ Received empty data")
            } else if data == nil {
                self?.logger.warning("[VIBETUNNEL-RX] ⚠️ Received nil data (no data available)")
            }
            
            if let error = error {
                self?.logger.error("[VIBETUNNEL-RX] ❌ Receive error: \(error.localizedDescription)")
                self?.logger.error("[VIBETUNNEL-RX]    Error domain: \(error._domain), code: \(error._code)")
            }
            
            if isComplete {
                self?.logger.warning("[VIBETUNNEL-RX] ⚠️ Connection marked as complete - remote side closed")
            }
            
            // Continue receiving if no error and connection not complete
            if error == nil && !isComplete {
                self?.logger.debug("[VIBETUNNEL-RX] 🔄 Scheduling next receive...")
                self?.startReceiving()
            } else {
                self?.logger.warning("[VIBETUNNEL-RX] 🛑 Stopping receive loop (error: \(error != nil), complete: \(isComplete))")
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        logger.info("[VIBETUNNEL-RX] 🔍 Processing data: \(data.count) bytes")
        
        // Log hex dump of first 32 bytes for debugging
        let hexPreview = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.debug("[VIBETUNNEL-RX]    Hex preview: \(hexPreview)")
        
        receiveBuffer.append(data)
        logger.debug("[VIBETUNNEL-RX]    Buffer size after append: \(self.receiveBuffer.count) bytes")
        
        var messagesProcessed = 0
        
        // Process complete messages from buffer
        while receiveBuffer.count >= 8 {
            // Try to parse header
            guard let header = MessageHeader.parse(from: receiveBuffer) else {
                logger.error("[VIBETUNNEL-RX] ❌ Failed to parse message header")
                logger.error("[VIBETUNNEL-RX]    Buffer contents: \(self.receiveBuffer.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
                receiveBuffer.removeAll()
                break
            }
            
            logger.info("[VIBETUNNEL-RX] 📨 Parsed message header:")
            logger.info("[VIBETUNNEL-RX]    - Type: \(String(describing: header.type)) (0x\(String(format: "%02x", header.type.rawValue)))")
            logger.info("[VIBETUNNEL-RX]    - Payload length: \(header.length) bytes")
            
            let totalMessageSize = 5 + Int(header.length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                logger.info("[VIBETUNNEL-RX] ⏳ Waiting for more data (need \(totalMessageSize) bytes, have \(self.receiveBuffer.count))")
                break
            }
            
            // Extract message payload
            let payload = receiveBuffer[5..<totalMessageSize]
            
            // Process the message
            processMessage(header: header, payload: payload)
            messagesProcessed += 1
            
            // Remove processed message from buffer
            receiveBuffer.removeFirst(totalMessageSize)
            logger.debug("[VIBETUNNEL-RX]    Buffer size after processing: \(self.receiveBuffer.count) bytes")
        }
        
        if messagesProcessed > 0 {
            logger.info("[VIBETUNNEL-RX] ✅ Processed \(messagesProcessed) message(s)")
        }
    }
    
    private func processMessage(header: MessageHeader, payload: Data) {
        logger.info("[VIBETUNNEL-MSG] 🎯 Processing message type: \(String(describing: header.type))")
        
        switch header.type {
        case .statusUpdate:
            // Status update (Claude activity, etc.)
            logger.info("[VIBETUNNEL-MSG] 📊 Received status update: \(payload.count) bytes")
            
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let app = json["app"] as? String,
               let status = json["status"] as? String {
                logger.info("[VIBETUNNEL-MSG]    App: \(app), Status: \(status)")
                // TODO: Handle status updates and forward to activity monitor
            } else {
                logger.warning("[VIBETUNNEL-MSG] ⚠️ Could not decode status update")
            }
            
        case .error:
            logger.error("[VIBETUNNEL-MSG] 🚨 Received ERROR message")
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let code = json["code"] as? String,
               let message = json["message"] as? String {
                logger.error("[VIBETUNNEL-MSG]    Error code: \(code), message: \(message)")
            } else {
                logger.error("[VIBETUNNEL-MSG]    Could not decode error message")
            }
            
        case .heartbeat:
            // Echo heartbeat back
            logger.info("[VIBETUNNEL-MSG] 💓 Received heartbeat")
            sendHeartbeat()
            
        case .stdinData:
            logger.info("[VIBETUNNEL-MSG] ⌨️ Received STDIN_DATA message (unexpected - we send these, not receive)")
            
        case .controlCmd:
            logger.info("[VIBETUNNEL-MSG] 🎮 Received CONTROL_CMD message (unexpected - we send these, not receive)")
            
        @unknown default:
            logger.warning("[VIBETUNNEL-MSG] ❓ Received unknown message type: 0x\(String(format: "%02x", header.type.rawValue))")
        }
    }
    
    private func sendHeartbeat() {
        let message = IPCMessage.createHeartbeat()
        let messageSize = message.data.count
        
        logger.info("[VIBETUNNEL-TX] 💗 Sending heartbeat response (\(messageSize) bytes)")
        
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL-TX] ❌ Failed to send heartbeat: \(error.localizedDescription)")
            } else {
                self?.logger.debug("[VIBETUNNEL-TX] ✅ Heartbeat sent successfully")
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