import Foundation

/// Protocol for WebSocket operations to enable testing.
/// Defines the interface for WebSocket connections and messaging.
@MainActor
protocol WebSocketProtocol: AnyObject {
    var delegate: WebSocketDelegate? { get set }

    func connect(to url: URL, with headers: [String: String]) async throws
    func send(_ message: WebSocketMessage) async throws
    func sendPing() async throws
    func disconnect(with code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// WebSocket message types.
/// Represents different types of messages that can be sent over WebSocket.
enum WebSocketMessage {
    case string(String)
    case data(Data)
}

/// Delegate protocol for WebSocket events.
/// Provides callbacks for connection state changes and message reception.
@MainActor
protocol WebSocketDelegate: AnyObject {
    func webSocketDidConnect(_ webSocket: WebSocketProtocol)
    func webSocket(_ webSocket: WebSocketProtocol, didReceiveMessage message: WebSocketMessage)
    func webSocket(_ webSocket: WebSocketProtocol, didFailWithError error: Error)
    func webSocketDidDisconnect(
        _ webSocket: WebSocketProtocol,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    )
}

/// Errors that can occur during WebSocket operations.
enum WebSocketError: Error {
    case invalidURL
    case connectionFailed
    case invalidData
    case invalidMagicByte
}