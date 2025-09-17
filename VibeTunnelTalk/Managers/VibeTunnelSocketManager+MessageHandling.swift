import Foundation
import Network
import OSLog

// MARK: - Message Handling
extension VibeTunnelSocketManager {

    func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleReceivedData(data)
            }

            if let error = error {
                self?.logger.error("Receive error: \(error.localizedDescription)")
            }

            // Connection complete

            // Continue receiving if no error and connection not complete
            if error == nil && !isComplete {
                self?.startReceiving()
            }
        }
    }

    func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        // Process complete messages from buffer
        while receiveBuffer.count >= 8 {
            // Try to parse header
            guard let header = MessageHeader.parse(from: receiveBuffer) else {
                logger.error("Failed to parse message header")
                receiveBuffer.removeAll()
                break
            }

            // Parsed message header

            let totalMessageSize = 5 + Int(header.length)

            // Check if we have the complete message
            guard receiveBuffer.count >= totalMessageSize else {
                break
            }

            // Extract message payload
            let payload = receiveBuffer[5..<totalMessageSize]


            // Process the message
            processMessage(header: header, payload: payload)

            // Remove processed message from buffer
            receiveBuffer.removeFirst(totalMessageSize)
        }
    }

    func processMessage(header: MessageHeader, payload: Data) {
        switch header.type {
        case .statusUpdate:
            // Status update (Claude activity, etc.)
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let _ = json["app"] as? String,
               let _ = json["status"] as? String {
                // TODO: Handle status updates and forward to activity monitor
            }

        case .error:
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let code = json["code"] as? String,
               let message = json["message"] as? String {
                logger.error("Error from server: \(code) - \(message)")
            }

        case .heartbeat:
            // Echo heartbeat back
            sendHeartbeat()

        case .stdinData, .controlCmd:
            // Unexpected - we send these, not receive
            break

        @unknown default:
            break
        }
    }

    func sendHeartbeat() {
        let message = IPCMessage.createHeartbeat()

        connection?.send(content: message.data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send heartbeat: \(error.localizedDescription)")
            }
        })
    }

    func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("✅ Connected to session: \(self.currentSessionId ?? "unknown")")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            startReceiving()

            // Send initial resize to trigger terminal output
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.resize(cols: 80, rows: 24)
            }

        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConnected = false
            }

        case .cancelled:
            DispatchQueue.main.async {
                self.isConnected = false
            }

        case .preparing, .setup:
            break

        case .waiting(let error):
            logger.warning("Connection waiting: \(error.localizedDescription)")

        @unknown default:
            break
        }
    }

    func removeANSIEscapeCodes(from text: String) -> String {
        // Remove ANSI escape sequences
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
}