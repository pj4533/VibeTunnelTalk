import Foundation
import Combine
import OSLog

/// View model that bridges WebSocket buffer updates to SwiftUI views
/// Replaces the deprecated REST API polling with real-time WebSocket subscriptions
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

    /// Starts receiving buffer updates for a specific session
    func startReceivingUpdates(for sessionId: String) {
        self.sessionId = sessionId
        self.isLoading = true
        self.error = nil

        logger.info("Starting to receive updates for session: \(sessionId)")

        // Use the shared BufferWebSocketClient instance
        bufferClient = BufferWebSocketClient.shared

        // Connect if not already connected
        if !bufferClient!.isConnected {
            logger.info("WebSocket not connected, initiating connection")
            bufferClient?.connect()
        } else {
            // Already connected, subscribe immediately
            subscribeToSession(sessionId)
        }
    }

    /// Subscribes to buffer updates for the current session
    private func subscribeToSession(_ sessionId: String) {
        guard let bufferClient else {
            logger.error("No buffer client available for subscription")
            return
        }

        logger.info("Subscribing to session: \(sessionId)")

        bufferClient.subscribe(to: sessionId) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch event {
                case .bufferUpdate(let snapshot):
                    self.logger.debug("Received buffer update: \(snapshot.cols)x\(snapshot.rows)")
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

    /// Stops receiving updates and cleans up subscriptions
    func stopReceivingUpdates() {
        guard let sessionId else { return }

        logger.info("Stopping updates for session: \(sessionId)")

        // Unsubscribe from the session
        bufferClient?.unsubscribe(from: sessionId)

        // Clear state
        self.sessionId = nil
        self.bufferClient = nil
        self.currentBuffer = nil
        self.isLoading = false
    }

    deinit {
        // Clean up is handled when the view disappears via stopReceivingUpdates()
        // We can't call @MainActor methods from deinit
    }
}