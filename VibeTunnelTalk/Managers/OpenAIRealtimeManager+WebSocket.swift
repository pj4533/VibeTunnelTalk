import Foundation
import OSLog

// MARK: - WebSocket Management
extension OpenAIRealtimeManager {

    /// Connect to OpenAI Realtime API
    func connect() {
        // Don't connect without an API key
        guard !apiKey.isEmpty else {
            logger.error("[OPENAI] ❌ Cannot connect without API key")
            return
        }

        logger.info("[OPENAI] 🔌 Connecting to OpenAI Realtime API...")

        // Create URLRequest exactly like swift-realtime-openai
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime")!.appending(queryItems: [
            URLQueryItem(name: "model", value: "gpt-4o-realtime-preview-2024-12-17")
        ]))
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        logger.info("[OPENAI] 📋 Request URL: \(request.url?.absoluteString ?? "nil")")

        // Use URLSession.shared instead of custom session - this is how swift-realtime-openai does it
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.delegate = self
        webSocketTask?.resume()

        // Start receiving messages immediately
        receiveMessage()
    }

    /// Disconnect from OpenAI
    func disconnect() {
        // Force log any pending statistics before disconnecting
        statsLogger.forceLogSummary()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stopAudioCapture()

        DispatchQueue.main.async {
            self.isConnected = false
            self.isListening = false
            self.isSpeaking = false
            self.isResponseInProgress = false
            self.activeResponseId = nil
            self.narrationQueue.removeAll()
        }
    }

    func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage() // Continue receiving

            case .failure(let error):
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let timestamp = formatter.string(from: Date())
                self?.logger.error("[OPENAI-RX @ \(timestamp)] ❌ WebSocket receive error: \(error.localizedDescription)")
                self?.handleDisconnection()
            }
        }
    }

    func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleDataMessage(data)

        case .string(let text):
            if let data = text.data(using: .utf8) {
                handleDataMessage(data)
            }

        @unknown default:
            break
        }
    }

    func sendEvent(_ event: [String: Any]) {
        guard let webSocketTask = webSocketTask else {
            logger.error("[OPENAI-TX] ❌ No WebSocket task available")
            return
        }

        // Create timestamp for logging
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to convert data to string")
                return
            }
            let message = URLSessionWebSocketTask.Message.string(jsonString)

            // Log event type
            if let eventType = event["type"] as? String {
                logger.debug("[OPENAI-TX @ \(timestamp)] 📨 Sending event: \(eventType)")
            }

            webSocketTask.send(message) { [weak self] error in
                if let error = error {
                    self?.logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to send event: \(error.localizedDescription)")

                    // If send fails, we might be disconnected
                    self?.handleDisconnection()
                }
            }
        } catch {
            logger.error("[OPENAI-TX @ \(timestamp)] ❌ Failed to serialize event: \(error.localizedDescription)")
        }
    }

    func handleDisconnection() {
        DispatchQueue.main.async {
            self.isConnected = false
            self.isListening = false
            self.isSpeaking = false
            self.isResponseInProgress = false
            self.activeResponseId = nil
            self.narrationQueue.removeAll()
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.error("[OPENAI @ \(timestamp)] 🔴 WebSocket disconnected - connection lost")
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAIRealtimeManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.info("[OPENAI-WS @ \(timestamp)] ✅ WebSocket opened with protocol: \(`protocol` ?? "none")")

        // Mark as connected and send configuration once WebSocket is open
        DispatchQueue.main.async {
            self.isConnected = true
            self.logger.info("[OPENAI-WS @ \(timestamp)] 🔄 Connection state updated to: connected")
        }
        self.sendSessionConfiguration()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        logger.error("[OPENAI-WS] ❌ WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")
        handleDisconnection()
    }
}