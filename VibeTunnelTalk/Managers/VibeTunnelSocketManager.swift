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

    // WebSocket client for real-time terminal snapshots
    private var bufferWebSocketClient: BufferWebSocketClient?

    // Smart terminal processor for intelligent data filtering
    private var terminalProcessor: SmartTerminalProcessor?

    // Authentication service
    private var authService: VibeTunnelAuthService?


    /// Configure the smart terminal processor with OpenAI manager
    func configureSmartProcessing(with openAIManager: OpenAIRealtimeManager) {
        terminalProcessor = SmartTerminalProcessor(openAIManager: openAIManager)
        logger.info("[VIBETUNNEL] Smart terminal processing configured")
    }

    /// Configure authentication service
    func configureAuthentication(with authService: VibeTunnelAuthService) {
        self.authService = authService
        logger.info("[VIBETUNNEL] Authentication service configured")
    }

    /// Get the terminal processor for UI access
    func getTerminalProcessor() -> SmartTerminalProcessor? {
        return terminalProcessor
    }

    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        logger.info("[VIBETUNNEL] Attempting to connect to session: \(sessionId)")

        // Only disconnect if we're connecting to a different session
        if currentSessionId != nil && currentSessionId != sessionId {
            logger.info("[VIBETUNNEL] Disconnecting from previous session: \(self.currentSessionId ?? "")")
            // Disconnect existing connection but preserve the new sessionId
            disconnectInternal(clearSessionId: false)
        }

        // Store session ID
        currentSessionId = sessionId

        // Build socket path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let socketPath = homeDir + "/.vibetunnel/control/\(sessionId)/ipc.sock"

        logger.info("[VIBETUNNEL] Socket path: \(socketPath)")

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

        // Start buffer service for terminal snapshots
        startBufferService(sessionId: sessionId)

    }

    /// Disconnect from current session
    func disconnect() {
        disconnectInternal(clearSessionId: true)
    }

    /// Internal disconnect with option to preserve sessionId
    private func disconnectInternal(clearSessionId: Bool) {
        logger.info("[VIBETUNNEL] Disconnecting...")

        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()

        // Stop buffer service
        stopBufferService()

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
            logger.warning("[VIBETUNNEL] Cannot send input - not connected")
            return
        }

        let message = IPCMessage.createStdinData(text)

        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL] Failed to send input: \(error.localizedDescription)")
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

        let message = IPCMessage.createResize(cols: cols, rows: rows)

        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("[VIBETUNNEL] ❌ Failed to send resize: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - WebSocket Management

    private func startBufferService(sessionId: String) {
        logger.info("[VIBETUNNEL-WEBSOCKET] startBufferService called for session: \(sessionId)")

        // Use shared WebSocket client for real-time terminal snapshots
        bufferWebSocketClient = BufferWebSocketClient.shared
        logger.info("[VIBETUNNEL-WEBSOCKET] Using shared BufferWebSocketClient instance")

        // Configure WebSocket client with auth service if available
        if let authService = authService {
            logger.info("[VIBETUNNEL-WEBSOCKET] Configuring BufferWebSocketClient with auth service")
            bufferWebSocketClient?.setAuthenticationService(authService)
        } else {
            logger.warning("[VIBETUNNEL-WEBSOCKET] No auth service available for WebSocket client")
        }

        // Store a strong reference to the WebSocket client
        let client = bufferWebSocketClient

        // Start WebSocket connection
        Task {
            logger.info("[VIBETUNNEL-WEBSOCKET] Starting async task for WebSocket connection")

            // Connect WebSocket (not async in BufferWebSocketClient)
            client?.connect()
            logger.info("[VIBETUNNEL-WEBSOCKET] WebSocket connect() initiated")

            // Double-check that we haven't been stopped in the meantime
            guard self.bufferWebSocketClient != nil else {
                logger.warning("[VIBETUNNEL-WEBSOCKET] WebSocket client was nil after connect, likely stopped during connection")
                return
            }

            // If we have a smart processor, let it handle the WebSocket updates
            if let terminalProcessor = terminalProcessor {
                logger.info("[VIBETUNNEL-WEBSOCKET] Starting smart processor with WebSocket client")
                await terminalProcessor.startProcessingWithBufferClient(bufferClient: bufferWebSocketClient, sessionId: sessionId)
                logger.info("[VIBETUNNEL-WEBSOCKET] Smart processor configured with WebSocket")
            } else {
                logger.warning("[VIBETUNNEL-WEBSOCKET] Missing terminal processor or WebSocket client")
            }
        }

        logger.info("[VIBETUNNEL-WEBSOCKET] startBufferService completed for session: \(sessionId)")
    }

    private func stopBufferService() {
        logger.info("[VIBETUNNEL-WEBSOCKET] stopBufferService called")

        // Capture reference to current webSocketClient before clearing it
        let currentWebSocketClient = bufferWebSocketClient
        bufferWebSocketClient = nil  // Clear reference immediately to prevent race conditions

        // Stop the smart processor if it's running
        Task {
            if let terminalProcessor = terminalProcessor, currentWebSocketClient != nil {
                logger.info("[VIBETUNNEL-WEBSOCKET] Stopping WebSocket processing in terminal processor")
                terminalProcessor.stopProcessing()
            }

            // Note: We don't disconnect the shared WebSocket client here since it might be
            // used by other components (like TerminalBufferView)
            logger.info("[VIBETUNNEL-WEBSOCKET] Keeping shared WebSocket client connected for other components")
        }

        logger.info("[VIBETUNNEL-WEBSOCKET] stopBufferService completed")
    }
}

