import Foundation

/// Factory protocol for creating WebSocket instances.
/// Enables dependency injection and testing by allowing mock WebSocket creation.
@MainActor
protocol WebSocketFactory {
    func createWebSocket() -> WebSocketProtocol
}

/// Default WebSocket factory that creates real URLSession-based WebSockets.
@MainActor
class DefaultWebSocketFactory: WebSocketFactory {
    func createWebSocket() -> WebSocketProtocol {
        return URLSessionWebSocket()
    }
}