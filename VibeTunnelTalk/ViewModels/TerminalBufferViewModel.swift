import Foundation
import Combine
import OSLog

/// View model that passively observes WebSocket buffer updates for display in SwiftUI views
/// This is a read-only observer that doesn't manage the WebSocket connection lifecycle
@MainActor
class TerminalBufferViewModel: ObservableObject {
    private let logger = AppLogger.ui

    @Published private(set) var currentBuffer: BufferSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private var bufferClient: BufferWebSocketClient?
    private var sessionId: String?
    private var cancellables = Set<AnyCancellable>()

    init() {
        observeBufferClient()
    }

    /// Observes the shared BufferWebSocketClient instance for connection changes
    private func observeBufferClient() {
        BufferWebSocketClient.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self else { return }

                if !isConnected {
                    self.logger.info("WebSocket disconnected, clearing buffer")
                    self.currentBuffer = nil
                }

                // If we have a session and the client reconnected, resubscribe
                if isConnected, let sessionId = self.sessionId {
                    self.logger.info("WebSocket reconnected, resubscribing to session: \(sessionId)")
                    self.subscribeToSession(sessionId)
                }
            }
            .store(in: &cancellables)

        BufferWebSocketClient.shared.$connectionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.error = error
            }
            .store(in: &cancellables)
    }

    /// Start observing buffer updates for a specific session
    /// This is a passive observer - it doesn't manage the WebSocket connection
    func startObserving(sessionId: String) {
        self.sessionId = sessionId
        self.isLoading = true
        self.error = nil

        logger.info("Starting to observe buffer updates for session: \(sessionId)")

        // Use the shared BufferWebSocketClient instance
        bufferClient = BufferWebSocketClient.shared

        // The WebSocket connection should already be established by VibeTunnelSocketManager
        // We're just adding another observer to the existing stream
        if bufferClient!.isConnected {
            subscribeToSession(sessionId)
        } else {
            logger.warning("WebSocket not connected - waiting for connection from main service")
            // Connection will be handled by observeBufferClient when it comes online
        }
    }

    /// Subscribes to buffer updates for the current session
    /// This adds an additional observer to the existing WebSocket stream
    private func subscribeToSession(_ sessionId: String) {
        guard let bufferClient else {
            logger.error("No buffer client available for subscription")
            return
        }

        logger.info("Adding observer for session: \(sessionId)")

        // Add this view model as an additional observer
        // The WebSocket connection and session subscription are managed elsewhere
        bufferClient.subscribe(to: sessionId) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch event {
                case .bufferUpdate(let snapshot):
                    self.logger.debug("Terminal view received buffer: \(snapshot.cols)x\(snapshot.rows)")
                    self.currentBuffer = snapshot
                    self.isLoading = false
                    self.error = nil

                case .bell:
                    self.logger.debug("Received bell event")
                    // Could trigger a visual or audio notification here

                case .alert(let title, let message):
                    self.logger.info("Alert: \(title ?? "Alert") - \(message)")

                default:
                    // Other events are handled by SmartTerminalProcessor
                    break
                }
            }
        }
    }

    /// Stop observing - only clears local state, doesn't affect the connection
    /// The WebSocket connection continues running for other observers
    private func stopObserving() {
        guard let sessionId else { return }

        logger.info("Terminal view stopping observation of session: \(sessionId)")

        // Note: We do NOT unsubscribe from the WebSocket here
        // The connection should remain active for SmartTerminalProcessor
        // We just clear our local state

        // Clear local state only
        self.sessionId = nil
        self.bufferClient = nil
        self.currentBuffer = nil
        self.isLoading = false
    }

    deinit {
        // No cleanup needed - we're just a passive observer
        // The WebSocket connection is managed by VibeTunnelSocketManager
    }
}