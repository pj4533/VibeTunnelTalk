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
    
    /// Find available VibeTunnel sessions
    func findAvailableSessions() -> [String] {
        // Now that we're not sandboxed, this returns the real home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let controlPath = homeDir + "/.vibetunnel/control"
        let fm = FileManager.default
        
        logger.info("🔍 Starting VibeTunnel session discovery")
        logger.debug("User home directory: \(homeDir)")
        logger.debug("Looking for control directory at: \(controlPath)")
        
        // Check if .vibetunnel directory exists
        let vibetunnelPath = homeDir + "/.vibetunnel"
        if !fm.fileExists(atPath: vibetunnelPath) {
            logger.error("❌ .vibetunnel directory does not exist at: \(vibetunnelPath)")
            return []
        }
        logger.info("✅ Found .vibetunnel directory")
        
        // Check if control directory exists
        if !fm.fileExists(atPath: controlPath) {
            logger.error("❌ Control directory does not exist at: \(controlPath)")
            
            // List what's in .vibetunnel directory for debugging
            if let vibetunnelContents = try? fm.contentsOfDirectory(atPath: vibetunnelPath) {
                logger.debug("Contents of .vibetunnel: \(vibetunnelContents.joined(separator: ", "))")
            }
            return []
        }
        logger.info("✅ Found control directory")
        
        // Get contents of control directory
        guard let contents = try? fm.contentsOfDirectory(atPath: controlPath) else {
            logger.error("❌ Failed to read contents of control directory at: \(controlPath)")
            return []
        }
        
        logger.info("📁 Found \(contents.count) items in control directory: \(contents.joined(separator: ", "))")
        
        // Filter for directories that contain an ipc.sock file
        let validSessions = contents.filter { sessionId in
            let sessionPath = "\(controlPath)/\(sessionId)"
            let socketPath = "\(sessionPath)/ipc.sock"
            
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: sessionPath, isDirectory: &isDirectory)
            
            if !exists || !isDirectory.boolValue {
                logger.debug("⏭️ Skipping \(sessionId) - not a directory")
                return false
            }
            
            // Check for ipc.sock file
            let hasSocket = fm.fileExists(atPath: socketPath)
            if hasSocket {
                logger.info("✅ Found valid session: \(sessionId) with socket at: \(socketPath)")
            } else {
                logger.debug("⏭️ Session \(sessionId) has no ipc.sock file")
                
                // List contents of session directory for debugging
                if let sessionContents = try? fm.contentsOfDirectory(atPath: sessionPath) {
                    logger.debug("Contents of session \(sessionId): \(sessionContents.joined(separator: ", "))")
                }
            }
            
            return hasSocket
        }
        
        logger.info("🎯 Found \(validSessions.count) valid VibeTunnel session(s): \(validSessions.joined(separator: ", "))")
        return validSessions
    }
    
    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = homeDir + "/.vibetunnel/control/\(sessionId)/ipc.sock"
        
        logger.info("🔌 Connecting to session \(sessionId) at \(socketPath)")
        
        // Create Unix domain socket endpoint
        let endpoint = NWEndpoint.unix(path: socketPath)
        let parameters = NWParameters()
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        
        connection?.start(queue: queue)
        currentSessionId = sessionId
    }
    
    /// Disconnect from current session
    func disconnect() {
        logger.info("🔌 Disconnecting from session")
        connection?.cancel()
        connection = nil
        isConnected = false
        currentSessionId = nil
    }
    
    /// Send input to the terminal
    func sendInput(_ text: String) {
        guard isConnected else {
            logger.warning("⚠️ Cannot send input - not connected")
            return
        }
        
        let message = IPCMessage.createInput(text)
        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("❌ Failed to send input: \(error.localizedDescription)")
            }
        })
    }
    
    /// Resize terminal
    func resize(cols: Int, rows: Int) {
        guard isConnected else { return }
        
        let message = IPCMessage.createResize(cols: cols, rows: rows)
        connection?.send(content: message.data, completion: .contentProcessed { _ in })
    }
    
    // MARK: - Private Methods
    
    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("✅ Socket connected and ready")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            startReceiving()
            
        case .failed(let error):
            logger.error("❌ Socket connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        case .cancelled:
            logger.info("🛑 Socket connection cancelled")
            DispatchQueue.main.async {
                self.isConnected = false
            }
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleReceivedData(data)
            }
            
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
                logger.error("❌ Failed to parse message header")
                receiveBuffer.removeAll()
                break
            }
            
            let totalMessageSize = 8 + Int(header.length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                // Wait for more data
                break
            }
            
            // Extract message payload
            let payload = receiveBuffer[8..<totalMessageSize]
            
            // Process the message
            processMessage(header: header, payload: payload)
            
            // Remove processed message from buffer
            receiveBuffer.removeFirst(totalMessageSize)
        }
    }
    
    private func processMessage(header: MessageHeader, payload: Data) {
        switch header.type {
        case .data:
            // Terminal output data
            if let text = String(data: payload, encoding: .utf8) {
                // Remove ANSI escape codes for cleaner processing
                let cleanText = removeANSIEscapeCodes(from: text)
                
                DispatchQueue.main.async {
                    self.terminalOutput.send(cleanText)
                }
            }
            
        case .error:
            if let errorText = String(data: payload, encoding: .utf8) {
                logger.error("❌ Received error from VibeTunnel: \(errorText)")
            }
            
        case .heartbeat:
            // Respond to heartbeat
            logger.debug("💓 Received heartbeat, responding...")
            sendHeartbeat()
            
        default:
            logger.debug("📨 Received message type: \(String(describing: header.type))")
        }
    }
    
    private func sendHeartbeat() {
        let message = IPCMessage.createHeartbeat()
        connection?.send(content: message.data, completion: .contentProcessed { _ in })
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