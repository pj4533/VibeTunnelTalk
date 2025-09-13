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

    // Smart terminal processor for intelligent data filtering
    private var terminalProcessor: SmartTerminalProcessor?

    // Debug file handle
    private var debugFileHandle: FileHandle?
    private let debugQueue = DispatchQueue(label: "vibetunnel.debug", qos: .background)

    // Debug output control
    var debugOutputEnabled = false

    /// Configure the smart terminal processor with OpenAI manager
    func configureSmartProcessing(with openAIManager: OpenAIRealtimeManager) {
        terminalProcessor = SmartTerminalProcessor(openAIManager: openAIManager)
        logger.info("[VIBETUNNEL] Smart terminal processing configured")
    }

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

        // Create debug file for this session if debug is enabled
        if debugOutputEnabled {
            createDebugFile(sessionId: sessionId)
        }

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

        // Start the smart terminal processor
        if let processor = terminalProcessor {
            logger.info("[VIBETUNNEL] Starting smart terminal processing")
            processor.startProcessing(sseClient: sseClient!)
        } else {
            logger.error("[VIBETUNNEL] ❌ Terminal processor not configured!")
        }

        // Connect to SSE stream
        sseClient?.connect(sessionId: sessionId)
    }
    
    /// Disconnect from current session
    func disconnect() {

        // Stop terminal processor if active
        terminalProcessor?.stopProcessing()

        // Stop IPC socket connection
        connection?.cancel()
        connection = nil

        // Stop SSE client
        sseClient?.disconnect()
        sseClient = nil
        sseSubscription?.cancel()
        sseSubscription = nil

        // Close debug file
        closeDebugFile()

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
        // Write raw IPC data to debug file if debug is enabled
        if debugOutputEnabled {
            if let hexString = data.map({ String(format: "%02hhx", $0) }).joined(separator: " ").data(using: .utf8) {
                writeToDebugFile(String(data: hexString, encoding: .utf8) ?? "", source: "IPC_HEX")
            }
        }

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

            // Write parsed IPC message to debug file if debug is enabled
            if debugOutputEnabled {
                writeToDebugFile("Type: \(header.type), Length: \(header.length), Payload: \(String(data: payload, encoding: .utf8) ?? "binary")", source: "IPC_PARSED")
            }

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

    // MARK: - Debug File Management

    private func createDebugFile(sessionId: String) {
        debugQueue.async { [weak self] in
            // Close any existing debug file
            self?.debugFileHandle?.closeFile()
            self?.debugFileHandle = nil

            // Create filename with session name and timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let filename = "\(sessionId)_\(timestamp).txt"

            // Create logs directory in Library/Logs/VibeTunnelTalk
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/VibeTunnelTalk")

            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

            let filePath = logsDir.appendingPathComponent(filename)

            // Create the file
            FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)

            // Open file handle for writing
            self?.debugFileHandle = try? FileHandle(forWritingTo: filePath)

            // Write header
            let header = """
            ========================================
            VibeTunnel Debug Log
            Session: \(sessionId)
            Started: \(Date())
            ========================================

            """
            if let headerData = header.data(using: .utf8) {
                self?.debugFileHandle?.write(headerData)
            }

            self?.logger.info("[DEBUG] Created debug file: \(filePath.path)")
        }
    }

    private func writeToDebugFile(_ content: String, source: String) {
        debugQueue.async { [weak self] in
            guard let fileHandle = self?.debugFileHandle else { return }

            // Clean the content before writing
            let cleanedContent = self?.cleanDebugContent(content) ?? content

            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeString = formatter.string(from: timestamp)

            let entry = """

            [\(timeString)] [\(source)]
            ----------------------------------------
            \(cleanedContent)
            ========================================

            """

            if let data = entry.data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }

    private func cleanDebugContent(_ text: String) -> String {
        var cleaned = text

        // First, handle JSON-escaped sequences
        // Convert \u001b to actual escape character
        cleaned = cleaned.replacingOccurrences(of: "\\u001b", with: "\u{001B}")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\r")
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\t", with: "\t")

        // Now remove ANSI escape sequences (color codes, cursor movements, etc.)
        // This matches ESC followed by [ and then any combination of numbers and semicolons, ending with a letter
        let ansiPattern = "\u{001B}\\[[0-9;]*[a-zA-Z]"
        cleaned = cleaned.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )

        // Remove other ANSI sequences
        let additionalPatterns = [
            "\u{001B}\\[\\?[0-9]+[hl]",     // DEC private mode (like ?2026h, ?2026l)
            "\u{001B}\\[[0-9]+(;[0-9]+)*m", // SGR sequences (colors, bold, etc)
            "\u{001B}\\].*;.*\u{0007}",     // OSC sequences
            "\u{001B}[\\(\\)].",             // Character set selection
            "\u{001B}.",                     // Any other ESC + single character
            "\r",                             // Carriage returns
        ]

        for pattern in additionalPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        // Remove remaining control characters
        let controlCharsPattern = "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]"
        cleaned = cleaned.replacingOccurrences(
            of: controlCharsPattern,
            with: "",
            options: .regularExpression
        )

        // Clean up the JSON array structure if present
        // Match patterns like [0,"o","..."] and extract just the content
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            // Try to parse as JSON array and extract the string content
            if let data = cleaned.data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any],
               jsonArray.count >= 3,
               let content = jsonArray[2] as? String {
                cleaned = content

                // Re-apply cleaning to the extracted content
                return cleanDebugContent(cleaned)
            }
        }

        // Clean up multiple consecutive newlines
        let multipleNewlines = "\n{3,}"
        cleaned = cleaned.replacingOccurrences(
            of: multipleNewlines,
            with: "\n\n",
            options: .regularExpression
        )

        // Trim whitespace from each line
        let lines = cleaned.components(separatedBy: .newlines)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        cleaned = trimmedLines.joined(separator: "\n")

        return cleaned
    }

    private func closeDebugFile() {
        debugQueue.async { [weak self] in
            // Write closing message
            let footer = """

            ========================================
            Session ended: \(Date())
            ========================================
            """
            if let footerData = footer.data(using: .utf8) {
                self?.debugFileHandle?.write(footerData)
            }

            // Close file handle
            self?.debugFileHandle?.closeFile()
            self?.debugFileHandle = nil

            self?.logger.info("[DEBUG] Closed debug file")
        }
    }
}