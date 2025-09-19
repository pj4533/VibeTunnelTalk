import Foundation
import Network
import Combine
import OSLog

class VibeTunnelSocketManager: ObservableObject {
    let logger = AppLogger.socketManager

    @Published var isConnected = false
    @Published var currentSessionId: String?

    var connection: NWConnection?
    var receiveBuffer = Data()
    let queue = DispatchQueue(label: "vibetunnel.socket", qos: .userInitiated)


    // Smart terminal processor for intelligent data filtering
    private var terminalProcessor: SmartTerminalProcessor?

    // Authentication service
    private var authService: VibeTunnelAuthService?


    /// Configure the smart terminal processor with OpenAI manager
    func configureSmartProcessing(with openAIManager: OpenAIRealtimeManager) {
        terminalProcessor = SmartTerminalProcessor(openAIManager: openAIManager)
        logger.debug("Smart terminal processing configured")
    }

    /// Configure authentication service
    func configureAuthentication(with authService: VibeTunnelAuthService) {
        self.authService = authService
        logger.debug("Authentication service configured")
    }

    /// Get the terminal processor for UI access
    func getTerminalProcessor() -> SmartTerminalProcessor? {
        return terminalProcessor
    }

    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        logger.info("🔌 Connecting to session: \(sessionId)")

        // Only disconnect if we're connecting to a different session
        if currentSessionId != nil && currentSessionId != sessionId {
            logger.debug("Disconnecting from previous session: \(self.currentSessionId ?? "")")
            // Disconnect existing connection but preserve the new sessionId
            disconnectInternal(clearSessionId: false)
        }

        // Store session ID
        currentSessionId = sessionId

        // Build socket path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = homeDir + "/.vibetunnel/control/\(sessionId)/ipc.sock"

        logger.debug("Socket path: \(socketPath)")

        // Create NWConnection for Unix domain socket
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        // Use TCP parameters without custom framer for Unix domain socket

        connection = NWConnection(to: endpoint, using: params)

        // Set up state handler
        connection?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }

        // Start connection
        connection?.start(queue: queue)

        // Start session monitoring
        startSessionMonitoring(sessionId: sessionId)

    }

    /// Disconnect from current session
    func disconnect() {
        disconnectInternal(clearSessionId: true)
    }

    /// Internal disconnect with option to preserve sessionId
    private func disconnectInternal(clearSessionId: Bool) {
        logger.debug("Disconnecting socket connection")

        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()

        // Stop session monitoring
        stopSessionMonitoring()

        // Clean up smart processor
        terminalProcessor?.cleanup()


        DispatchQueue.main.async {
            self.isConnected = false
            if clearSessionId {
                self.currentSessionId = nil
            }
        }
    }

    /// Send input to the terminal
    func sendInput(_ text: String) {
        guard isConnected else {
            logger.warning("Cannot send input - not connected")
            return
        }

        logger.info("💬 Sending input: \(text.debugDescription)")

        let message = IPCMessage.createStdinData(text)

        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send input: \(error.localizedDescription)")
            }
        })
    }

    /// Request terminal refresh by sending a redraw command
    func refreshTerminal() {
        guard isConnected else {
            logger.warning("[VIBETUNNEL-REFRESH] ⚠️ Cannot refresh - not connected")
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

        logger.debug("📐 Sending resize: \(cols)x\(rows)")

        let message = IPCMessage.createResize(cols: cols, rows: rows)

        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send resize: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Session Monitoring

    private func startSessionMonitoring(sessionId: String) {
        logger.debug("Starting session monitoring for session: \(sessionId)")

        // No WebSocket lifecycle monitoring needed - we use asciinema files

        // Start file-based terminal processing
        Task {
            if let terminalProcessor = terminalProcessor {
                logger.debug("Starting smart processor with file reader")
                await terminalProcessor.startProcessingWithFileReader(sessionId: sessionId)
                logger.debug("Smart processor configured with asciinema file")
            } else {
                logger.warning("Missing terminal processor")
            }
        }

        logger.debug("Session monitoring started")
    }

    private func stopSessionMonitoring() {
        logger.debug("Stopping session monitoring")

        // Stop the smart processor if it's running
        Task {
            if let terminalProcessor = terminalProcessor {
                logger.debug("Stopping file-based processing")
                terminalProcessor.stopProcessing()
            }
        }

        logger.info("Session monitoring stopped")
    }

}

