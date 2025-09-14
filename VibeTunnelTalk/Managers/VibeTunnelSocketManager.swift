import Foundation
import Network
import Combine
import OSLog

class VibeTunnelSocketManager: ObservableObject {
    let logger = AppLogger.socketManager

    @Published var isConnected = false
    @Published var currentSessionId: String?
    let terminalOutput = PassthroughSubject<String, Never>()

    var connection: NWConnection?
    var receiveBuffer = Data()
    let queue = DispatchQueue(label: "vibetunnel.socket", qos: .userInitiated)

    // SSE client for terminal output streaming
    private var sseClient: VibeTunnelSSEClient?
    private var sseSubscription: AnyCancellable?

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

    /// Connect to a VibeTunnel session
    func connect(to sessionId: String) {
        logger.info("[VIBETUNNEL] Attempting to connect to session: \(sessionId)")

        // Disconnect existing connection
        disconnect()

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

        // Also start SSE client for terminal output
        startSSEClient(sessionId: sessionId)

        // Enable debug output if configured
        if debugOutputEnabled {
            createDebugFile(sessionId: sessionId)
        }
    }

    /// Disconnect from current session
    func disconnect() {
        logger.info("[VIBETUNNEL] Disconnecting...")

        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()

        // Stop SSE client
        stopSSEClient()

        // Clean up smart processor
        terminalProcessor?.cleanup()

        // Close debug file if open
        if debugOutputEnabled {
            closeDebugFile()
        }

        DispatchQueue.main.async {
            self.isConnected = false
            self.currentSessionId = nil
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

    // MARK: - SSE Client Management

    private func startSSEClient(sessionId: String) {
        // Create SSE client for streaming terminal output
        sseClient = VibeTunnelSSEClient()

        // If we have a smart processor, let it handle the SSE events directly
        if let terminalProcessor = terminalProcessor, let sseClient = sseClient {
            // Start the processor with the SSE client (this sets up the subscription internally)
            terminalProcessor.startProcessing(sseClient: sseClient)
        } else {
            // Fallback: Subscribe to asciinema events manually
            sseSubscription = sseClient?.asciinemaEvent.sink { [weak self] event in
                self?.handleSSEEvent(event)
            }
        }

        sseClient?.connect(sessionId: sessionId)
        logger.info("[VIBETUNNEL-SSE] Started SSE client for session: \(sessionId)")
    }

    private func stopSSEClient() {
        // Stop the smart processor if it's running
        terminalProcessor?.stopProcessing()

        // Cancel manual subscription if we have one
        sseSubscription?.cancel()
        sseSubscription = nil

        // Disconnect SSE client
        sseClient?.disconnect()
        sseClient = nil
        logger.info("[VIBETUNNEL-SSE] Stopped SSE client")
    }

    private func handleSSEEvent(_ event: AsciinemaEvent) {
        // Process terminal output through smart processor
        if let terminalProcessor = terminalProcessor {
            // Create JSON array format for processor
            let jsonArray = [event.timestamp, event.type.rawValue, event.data] as [Any]
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                terminalProcessor.processTerminalEvent(jsonString)
            }
        } else {
            // Fallback to direct output for output events
            if event.type == .output {
                let cleanedData = removeANSIEscapeCodes(from: event.data)
                DispatchQueue.main.async {
                    self.terminalOutput.send(cleanedData)
                }
            }
        }
    }

    private func cleanTerminalData(_ data: String) -> String? {
        // Parse the JSON array format [timestamp, "o", content]
        guard let jsonData = data.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              array.count >= 3,
              let content = array[2] as? String else {
            return nil
        }

        // Remove ANSI escape codes for cleaner output
        return removeANSIEscapeCodes(from: content)
    }
}

