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

    // Buffer service for fetching terminal snapshots
    private var bufferService: VibeTunnelBufferService?

    // Smart terminal processor for intelligent data filtering
    private var terminalProcessor: SmartTerminalProcessor?

    // Debug file handle
    var debugFileHandle: FileHandle?
    let debugQueue = DispatchQueue(label: "vibetunnel.debug", qos: .background)

    // Debug output control
    var debugOutputEnabled = false

    /// Configure the smart terminal processor with OpenAI manager
    func configureSmartProcessing(with openAIManager: OpenAIRealtimeManager) {
        terminalProcessor = SmartTerminalProcessor(openAIManager: openAIManager)
        logger.info("[VIBETUNNEL] Smart terminal processing configured")
    }

    /// Get the terminal processor for UI access
    func getTerminalProcessor() -> SmartTerminalProcessor? {
        return terminalProcessor
    }

    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        logger.info("[VIBETUNNEL] Attempting to connect to session: \(sessionId)")

        // Disconnect existing connection but preserve the new sessionId
        disconnectInternal(clearSessionId: false)

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

        // Enable debug output if configured
        if debugOutputEnabled {
            createDebugFile(sessionId: sessionId)
        }
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

        // Close debug file if open
        if debugOutputEnabled {
            closeDebugFile()
        }

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

        // Write input to debug file if debug is enabled
        if debugOutputEnabled {
            writeToDebugFile(text, source: "INPUT")
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

    // MARK: - Buffer Service Management

    private func startBufferService(sessionId: String) {
        // Create buffer service for fetching terminal snapshots
        bufferService = VibeTunnelBufferService()

        // If we have a smart processor, let it handle the buffer snapshots
        if let terminalProcessor = terminalProcessor, let bufferService = bufferService {
            terminalProcessor.startProcessing(bufferService: bufferService, sessionId: sessionId)
        }

        // Start polling for buffer updates
        bufferService?.startPolling(sessionId: sessionId, interval: 0.5)
        logger.info("[VIBETUNNEL-BUFFER] Started buffer service for session: \(sessionId)")
    }

    private func stopBufferService() {
        // Stop the smart processor if it's running
        terminalProcessor?.stopProcessing()

        // Stop buffer polling
        bufferService?.stopPolling()
        bufferService = nil
        logger.info("[VIBETUNNEL-BUFFER] Stopped buffer service")
    }
}

