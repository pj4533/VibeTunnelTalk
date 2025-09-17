import Foundation
import OSLog

/// Real implementation of WebSocketProtocol using URLSessionWebSocketTask.
/// Provides WebSocket functionality using native macOS URLSession APIs.
@MainActor
class URLSessionWebSocket: NSObject, WebSocketProtocol {
    weak var delegate: WebSocketDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isReceiving = false
    private let logger = AppLogger.webSocket

    override init() {
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(to url: URL, with headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        isReceiving = true
        receiveNextMessage()

        // Send initial ping to verify connection
        do {
            try await sendPing()
            Task { @MainActor in
                self.delegate?.webSocketDidConnect(self)
            }
        } catch {
            Task { @MainActor in
                self.delegate?.webSocket(self, didFailWithError: error)
            }
            throw error
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard let task = webSocketTask else {
            throw WebSocketError.connectionFailed
        }

        switch message {
        case .string(let text):
            try await task.send(.string(text))
        case .data(let data):
            try await task.send(.data(data))
        }
    }

    func sendPing() async throws {
        guard let task = webSocketTask else {
            throw WebSocketError.connectionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func disconnect(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isReceiving = false
        webSocketTask?.cancel(with: code, reason: reason)
        Task { @MainActor in
            self.delegate?.webSocketDidDisconnect(self, closeCode: code, reason: reason)
        }
    }

    private func receiveNextMessage() {
        guard isReceiving, let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                let wsMessage: WebSocketMessage
                switch message {
                case .string(let text):
                    wsMessage = .string(text)
                case .data(let data):
                    wsMessage = .data(data)
                @unknown default:
                    return
                }

                Task { @MainActor in
                    self.delegate?.webSocket(self, didReceiveMessage: wsMessage)
                }

                // Continue receiving
                Task { @MainActor in
                    self.receiveNextMessage()
                }

            case .failure(let error):
                Task { @MainActor in
                    self.isReceiving = false
                    self.delegate?.webSocket(self, didFailWithError: error)
                }
            }
        }
    }
}

extension URLSessionWebSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Connection opened - already handled in connect()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            self.isReceiving = false
            self.delegate?.webSocketDidDisconnect(self, closeCode: closeCode, reason: reason)
        }
    }
}