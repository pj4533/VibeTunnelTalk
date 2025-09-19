import Foundation
import OSLog
import Combine

/// Session lifecycle events from the WebSocket
enum SessionLifecycleEvent {
    case connected(sessionId: String)
    case disconnected(sessionId: String)
    case error(message: String)
}

/// WebSocket client for session lifecycle management only
/// No longer handles buffer streaming - that's done via asciinema files
@MainActor
class SessionLifecycleClient: NSObject, ObservableObject {
    static let shared = SessionLifecycleClient()

    private let logger = AppLogger.webSocket

    private var webSocket: WebSocketProtocol?
    private let webSocketFactory: WebSocketFactory
    private var lifecycleHandler: ((SessionLifecycleEvent) -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var isConnecting = false
    private var pingTask: Task<Void, Never>?
    private(set) var authenticationService: VibeTunnelAuthService?

    // Observable properties
    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: Error?

    private var baseURL: URL? {
        // For macOS, we're always connecting to localhost
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 4020
        return components.url
    }

    override init() {
        self.webSocketFactory = DefaultWebSocketFactory()
        super.init()
    }

    init(webSocketFactory: WebSocketFactory) {
        self.webSocketFactory = webSocketFactory
        super.init()
    }

    /// Set the authentication service for WebSocket connections
    func setAuthenticationService(_ authService: VibeTunnelAuthService) {
        self.authenticationService = authService
    }

    /// Set handler for lifecycle events
    func setLifecycleHandler(_ handler: @escaping (SessionLifecycleEvent) -> Void) {
        self.lifecycleHandler = handler
    }

    func connect() {
        guard !isConnecting else {
            logger.warning("Already connecting, ignoring connect() call")
            return
        }
        guard !isConnected else {
            logger.warning("Already connected, ignoring connect() call")
            return
        }
        guard let baseURL else {
            connectionError = WebSocketError.invalidURL
            return
        }

        isConnecting = true
        connectionError = nil

        // Convert HTTP URL to WebSocket URL
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/lifecycle"  // New endpoint for session lifecycle only

        // Add authentication token as query parameter
        Task {
            if let token = try? await authenticationService?.getToken() {
                components?.queryItems = [URLQueryItem(name: "token", value: token)]
            }

            guard let wsURL = components?.url else {
                connectionError = WebSocketError.invalidURL
                isConnecting = false
                return
            }

            logger.debug("Connecting to \(wsURL)")

            // Disconnect existing WebSocket if any
            webSocket?.disconnect(with: .goingAway, reason: nil)

            // Create new WebSocket
            webSocket = webSocketFactory.createWebSocket()
            webSocket?.delegate = self

            // Build headers
            var headers: [String: String] = [:]

            // Add authentication header
            if let token = try? await authenticationService?.getToken() {
                headers["Authorization"] = "Bearer \(token)"
            }

            // Connect
            do {
                try await webSocket?.connect(to: wsURL, with: headers)
            } catch {
                logger.error("Connection failed: \(error)")
                connectionError = error
                isConnecting = false
                scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: WebSocketMessage) {
        switch message {
        case .data:
            // Session lifecycle doesn't use binary messages
            break

        case .string(let text):
            handleTextMessage(text)
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let type = json["type"] as? String {
            switch type {
            case "connected":
                // Server welcome message
                let version = json["version"] as? String ?? "unknown"
                logger.debug("Server welcome: version \(version)")

            case "sessionConnected":
                if let sessionId = json["sessionId"] as? String {
                    logger.debug("Session connected: \(sessionId)")
                    lifecycleHandler?(.connected(sessionId: sessionId))
                }

            case "sessionDisconnected":
                if let sessionId = json["sessionId"] as? String {
                    logger.debug("Session disconnected: \(sessionId)")
                    lifecycleHandler?(.disconnected(sessionId: sessionId))
                }

            case "ping":
                // Respond with pong
                Task {
                    try? await sendMessage(["type": "pong"])
                }

            case "error":
                if let message = json["message"] as? String {
                    logger.warning("Server error: \(message)")
                    lifecycleHandler?(.error(message: message))
                }

            default:
                logger.debug("Unknown message type: \(type)")
            }
        }
    }

    private func sendMessage(_ message: [String: Any]) async throws {
        guard let webSocket else {
            throw WebSocketError.connectionFailed
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WebSocketError.invalidData
        }

        try await webSocket.send(.string(string))
    }

    private func sendPing() async throws {
        guard let webSocket else {
            throw WebSocketError.connectionFailed
        }
        try await webSocket.sendPing()
    }

    private func startPingTask() {
        stopPingTask()

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if !Task.isCancelled {
                    try? await self?.sendPing()
                }
            }
        }
    }

    private func stopPingTask() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func handleDisconnection() {
        isConnected = false
        webSocket = nil
        stopPingTask()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1

        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")

        reconnectTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            if !Task.isCancelled {
                self?.reconnectTask = nil
                self?.connect()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPingTask()

        webSocket?.disconnect(with: .goingAway, reason: nil)
        webSocket = nil

        isConnected = false
    }

    deinit {
        // Tasks will be cancelled automatically when the object is deallocated
        // WebSocket cleanup happens in disconnect()
    }
}

// MARK: - WebSocketDelegate

extension SessionLifecycleClient: WebSocketDelegate {
    func webSocketDidConnect(_ webSocket: WebSocketProtocol) {
        logger.info("Connected")
        isConnected = true
        isConnecting = false
        reconnectAttempts = 0
        startPingTask()
    }

    func webSocket(_ webSocket: WebSocketProtocol, didReceiveMessage message: WebSocketMessage) {
        handleMessage(message)
    }

    func webSocket(_ webSocket: WebSocketProtocol, didFailWithError error: Error) {
        logger.error("Error: \(error)")
        connectionError = error
        handleDisconnection()
    }

    func webSocketDidDisconnect(
        _ webSocket: WebSocketProtocol,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        logger.info("Disconnected with code: \(closeCode.rawValue)")
        handleDisconnection()
    }
}