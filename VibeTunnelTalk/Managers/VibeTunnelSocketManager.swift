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
    }
    
    /// Disconnect from current session
    func disconnect() {
        logger.info("[VIBETUNNEL-SOCKET] 🔌 Disconnecting from session")
        connection?.cancel()
        connection = nil
        isConnected = false
        currentSessionId = nil
    }
    
    /// Send input to the terminal
    func sendInput(_ text: String) {
        guard isConnected else {
            logger.warning("[VIBETUNNEL-SOCKET] ⚠️ Cannot send input - not connected")
            return
        }
        
        let message = IPCMessage.createInput(text)
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
        
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.logger.info("[VIBETUNNEL-RX] 📥 Received \(data.count) bytes")
                self?.handleReceivedData(data)
            } else if data?.isEmpty == true {
                self?.logger.warning("[VIBETUNNEL-RX] ⚠️ Received empty data")
            }
            
            if let error = error {
                self?.logger.error("[VIBETUNNEL-RX] ❌ Receive error: \(error.localizedDescription)")
            }
            
            if isComplete {
                self?.logger.warning("[VIBETUNNEL-RX] ⚠️ Connection marked as complete")
            }
            
            if error == nil && !isComplete {
                self?.startReceiving()
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
            logger.info("[VIBETUNNEL-RX]    - Flags: 0x\(String(format: "%02x", header.flags))")
            logger.info("[VIBETUNNEL-RX]    - Payload length: \(header.length) bytes")
            
            let totalMessageSize = 8 + Int(header.length)
            
            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                logger.info("[VIBETUNNEL-RX] ⏳ Waiting for more data (need \(totalMessageSize) bytes, have \(self.receiveBuffer.count))")
                break
            }
            
            // Extract message payload
            let payload = receiveBuffer[8..<totalMessageSize]
            
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
        case .data:
            // Terminal output data
            logger.info("[VIBETUNNEL-MSG] 📺 Received terminal output: \(payload.count) bytes")
            
            if let text = String(data: payload, encoding: .utf8) {
                // Log first 200 chars of terminal output
                let preview = String(text.prefix(200)).replacingOccurrences(of: "\n", with: "\\n")
                logger.info("[VIBETUNNEL-MSG]    Terminal text preview: \"\(preview)\(text.count > 200 ? "..." : "")\"")
                
                // Remove ANSI escape codes for cleaner processing
                let cleanText = removeANSIEscapeCodes(from: text)
                logger.debug("[VIBETUNNEL-MSG]    Clean text length: \(cleanText.count) chars")
                
                DispatchQueue.main.async {
                    self.terminalOutput.send(cleanText)
                }
                logger.info("[VIBETUNNEL-MSG] ✅ Terminal output sent to subscribers")
            } else {
                logger.warning("[VIBETUNNEL-MSG] ⚠️ Could not decode terminal data as UTF-8")
            }
            
        case .error:
            logger.error("[VIBETUNNEL-MSG] 🚨 Received ERROR message")
            if let errorText = String(data: payload, encoding: .utf8) {
                logger.error("[VIBETUNNEL-MSG]    Error content: \(errorText)")
            } else {
                logger.error("[VIBETUNNEL-MSG]    Could not decode error message")
            }
            
        case .heartbeat:
            // Respond to heartbeat
            logger.info("[VIBETUNNEL-MSG] 💓 Received heartbeat")
            sendHeartbeat()
            
        case .updateTitle:
            logger.info("[VIBETUNNEL-MSG] 🏷️ Received title update")
            if let titleText = String(data: payload, encoding: .utf8) {
                logger.info("[VIBETUNNEL-MSG]    New title: \(titleText)")
            }
            
        case .kill:
            logger.warning("[VIBETUNNEL-MSG] ☠️ Received KILL message")
            
        case .resetSize:
            logger.info("[VIBETUNNEL-MSG] 📐 Received reset size message")
            
        case .input:
            logger.info("[VIBETUNNEL-MSG] ⌨️ Received INPUT message (unexpected)")
            
        case .resize:
            logger.info("[VIBETUNNEL-MSG] 📏 Received RESIZE message (unexpected)")
            
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