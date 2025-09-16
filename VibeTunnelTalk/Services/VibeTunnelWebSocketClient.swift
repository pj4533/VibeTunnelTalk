import Foundation
import OSLog
import Combine

/// WebSocket client for real-time terminal buffer streaming from VibeTunnel
@MainActor
class VibeTunnelWebSocketClient: NSObject {
    private let logger = AppLogger.webSocket

    /// Magic byte for binary buffer messages
    private static let bufferMagicByte: UInt8 = 0xBF

    // WebSocket connection
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Authentication
    private var authService: VibeTunnelAuthService?

    // Connection state
    @Published var isConnected = false
    @Published var connectionError: Error?
    private var isConnecting = false

    // Subscription management
    private var subscribedSessionId: String?
    private var bufferHandler: ((BufferSnapshot) -> Void)?

    // Reconnection logic
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 30.0

    // Ping/pong keepalive
    private var pingTask: Task<Void, Never>?
    private let pingInterval: TimeInterval = 30.0

    override init() {
        super.init()
        // Create URLSession with delegate
        let configuration = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Configure with authentication service
    func configure(authService: VibeTunnelAuthService) {
        self.authService = authService
    }

    /// Connect to VibeTunnel WebSocket endpoint
    func connect() async {
        guard !isConnecting else {
            logger.warning("[WS-CLIENT] Already connecting, ignoring connect() call")
            return
        }
        guard !isConnected else {
            logger.warning("[WS-CLIENT] Already connected, ignoring connect() call")
            return
        }

        isConnecting = true
        connectionError = nil

        // Build WebSocket URL
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "localhost"
        components.port = 4020
        components.path = "/buffers"

        // Add authentication token as query parameter
        if let token = try? await authService?.getToken() {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            logger.debug("[WS-CLIENT] Added auth token to WebSocket URL")
        }

        guard let url = components.url else {
            logger.error("[WS-CLIENT] Failed to construct WebSocket URL")
            connectionError = URLError(.badURL)
            isConnecting = false
            return
        }

        logger.info("[WS-CLIENT] Connecting to \(url.absoluteString)")

        // Create WebSocket task
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0

        // Add auth header as well (some servers might check headers)
        if let token = try? await authService?.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessage()

        // Consider connected once the task is resumed
        await MainActor.run {
            self.isConnected = true
            self.isConnecting = false
            self.reconnectAttempts = 0
            self.logger.info("[WS-CLIENT] WebSocket connected")
        }

        // Start ping task for keepalive
        startPingTask()

        // Re-subscribe if we have a session
        if let sessionId = subscribedSessionId {
            await subscribe(to: sessionId)
        }
    }

    /// Disconnect from WebSocket
    func disconnect() {
        logger.info("[WS-CLIENT] Disconnecting WebSocket")

        // Cancel tasks
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil

        // Close WebSocket
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        // Update state
        isConnected = false
        isConnecting = false
    }

    /// Subscribe to a session for buffer updates
    func subscribe(to sessionId: String, handler: @escaping (BufferSnapshot) -> Void) async {
        self.subscribedSessionId = sessionId
        self.bufferHandler = handler

        // Send subscription message if connected
        if isConnected {
            await subscribe(to: sessionId)
        }
    }

    /// Unsubscribe from current session
    func unsubscribe() async {
        guard let sessionId = subscribedSessionId else { return }

        // Send unsubscribe message if connected
        if isConnected {
            await unsubscribe(from: sessionId)
        }

        self.subscribedSessionId = nil
        self.bufferHandler = nil
    }

    // MARK: - Private Methods

    /// Send subscription message
    private func subscribe(to sessionId: String) async {
        let message = ["type": "subscribe", "sessionId": sessionId]
        await sendJSON(message)
        logger.info("[WS-CLIENT] Sent subscription for session: \(sessionId)")
    }

    /// Send unsubscription message
    private func unsubscribe(from sessionId: String) async {
        let message = ["type": "unsubscribe", "sessionId": sessionId]
        await sendJSON(message)
        logger.info("[WS-CLIENT] Sent unsubscription for session: \(sessionId)")
    }

    /// Send JSON message through WebSocket
    private func sendJSON(_ message: [String: Any]) async {
        guard let webSocketTask = webSocketTask else {
            logger.warning("[WS-CLIENT] Cannot send message - WebSocket not connected")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            guard let string = String(data: data, encoding: .utf8) else {
                logger.error("[WS-CLIENT] Failed to encode JSON message")
                return
            }

            let message = URLSessionWebSocketTask.Message.string(string)
            try await webSocketTask.send(message)
        } catch {
            logger.error("[WS-CLIENT] Failed to send message: \(error.localizedDescription)")
        }
    }

    /// Receive messages from WebSocket
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                Task { @MainActor in
                    await self.handleMessage(message)
                    // Continue receiving
                    self.receiveMessage()
                }

            case .failure(let error):
                Task { @MainActor in
                    self.logger.error("[WS-CLIENT] Receive error: \(error.localizedDescription)")
                    self.handleDisconnection(error: error)
                }
            }
        }
    }

    /// Handle incoming WebSocket message
    @MainActor
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleBinaryMessage(data)

        case .string(let text):
            handleTextMessage(text)

        @unknown default:
            logger.warning("[WS-CLIENT] Received unknown message type")
        }
    }

    /// Handle text message (JSON)
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("[WS-CLIENT] Failed to parse text message")
            return
        }

        if let type = json["type"] as? String {
            switch type {
            case "ping":
                // Respond with pong
                Task {
                    await sendJSON(["type": "pong"])
                }
                logger.debug("[WS-CLIENT] Received ping, sent pong")

            case "error":
                if let message = json["message"] as? String {
                    logger.error("[WS-CLIENT] Server error: \(message)")
                }

            default:
                logger.debug("[WS-CLIENT] Unknown message type: \(type)")
            }
        }
    }

    /// Handle binary message (buffer data)
    private func handleBinaryMessage(_ data: Data) {
        logger.debug("[WS-CLIENT] Received binary message: \(data.count) bytes")

        guard data.count > 5 else {
            logger.warning("[WS-CLIENT] Binary message too short: \(data.count) bytes")
            return
        }

        var offset = 0

        // Check magic byte
        let magic = data[offset]
        offset += 1

        guard magic == Self.bufferMagicByte else {
            logger.warning("[WS-CLIENT] Invalid magic byte: 0x\(String(format: "%02X", magic))")
            return
        }

        // Read session ID length (4 bytes, little endian)
        let sessionIdLength = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4

        // Read session ID
        guard data.count >= offset + Int(sessionIdLength) else {
            logger.warning("[WS-CLIENT] Not enough data for session ID")
            return
        }

        let sessionIdData = data.subdata(in: offset..<(offset + Int(sessionIdLength)))
        guard let sessionId = String(data: sessionIdData, encoding: .utf8) else {
            logger.warning("[WS-CLIENT] Failed to decode session ID")
            return
        }
        offset += Int(sessionIdLength)

        logger.debug("[WS-CLIENT] Received buffer for session: \(sessionId)")

        // Check if this is for our subscribed session
        guard sessionId == subscribedSessionId else {
            logger.debug("[WS-CLIENT] Ignoring buffer for non-subscribed session: \(sessionId)")
            return
        }

        // Remaining data is the buffer snapshot
        let bufferData = data.subdata(in: offset..<data.count)

        // Decode buffer snapshot
        if let snapshot = decodeBinaryBuffer(bufferData) {
            logger.debug("[WS-CLIENT] Successfully decoded buffer: \(snapshot.cols)x\(snapshot.rows)")

            // Call handler with the snapshot
            bufferHandler?(snapshot)
        } else {
            logger.warning("[WS-CLIENT] Failed to decode buffer snapshot")
        }
    }

    /// Decode binary buffer format (reusing existing implementation)
    private func decodeBinaryBuffer(_ data: Data) -> BufferSnapshot? {
        var offset = 0

        // Read header
        guard data.count >= 32 else {
            logger.debug("[WS-CLIENT] Buffer too small for header: \(data.count) bytes")
            return nil
        }

        // Magic bytes "VT" (0x5654 in little endian)
        let magic = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
        offset += 2

        guard magic == 0x5654 else {
            logger.warning("[WS-CLIENT] Invalid buffer magic: 0x\(String(format: "%04X", magic))")
            return nil
        }

        // Version
        let version = data[offset]
        offset += 1

        guard version == 0x01 else {
            logger.warning("[WS-CLIENT] Unsupported buffer version: 0x\(String(format: "%02X", version))")
            return nil
        }

        // Flags
        _ = data[offset]
        offset += 1

        // Dimensions and cursor
        let cols = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4

        let rows = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4

        // Validate dimensions
        guard cols > 0 && cols <= 1000 && rows > 0 && rows <= 1000 else {
            logger.warning("[WS-CLIENT] Invalid dimensions: \(cols)x\(rows)")
            return nil
        }

        let viewportY = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4

        let cursorX = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4

        let cursorY = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4

        // Skip reserved
        offset += 4

        // Decode cells
        var cells: [[BufferCell]] = []
        var totalRows = 0

        while offset < data.count && totalRows < Int(rows) {
            guard offset < data.count else { break }

            let marker = data[offset]
            offset += 1

            if marker == 0xFE {
                // Empty row(s)
                guard offset < data.count else { break }

                let count = Int(data[offset])
                offset += 1

                // Create empty rows
                let emptyRow = Array(repeating: BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil), count: Int(cols))
                for _ in 0..<min(count, Int(rows) - totalRows) {
                    cells.append(emptyRow)
                    totalRows += 1
                }
            } else if marker == 0xFD {
                // Row with content
                guard offset + 2 <= data.count else { break }

                let cellCount = data.withUnsafeBytes { bytes in
                    bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
                }
                offset += 2

                var rowCells: [BufferCell] = []

                for _ in 0..<cellCount {
                    if let (cell, newOffset) = decodeCell(data, offset: offset) {
                        rowCells.append(cell)
                        offset = newOffset
                    } else {
                        break
                    }
                }

                // Pad row to full width
                while rowCells.count < Int(cols) {
                    rowCells.append(BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil))
                }

                cells.append(rowCells)
                totalRows += 1
            } else {
                // Unknown marker, skip
                break
            }
        }

        // Fill missing rows with empty rows if needed
        while cells.count < Int(rows) {
            cells.append(Array(repeating: BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil), count: Int(cols)))
        }

        return BufferSnapshot(
            cols: Int(cols),
            rows: Int(rows),
            viewportY: Int(viewportY),
            cursorX: Int(cursorX),
            cursorY: Int(cursorY),
            cells: cells
        )
    }

    /// Decode individual cell from binary data
    private func decodeCell(_ data: Data, offset: Int) -> (BufferCell, Int)? {
        guard offset < data.count else { return nil }

        var currentOffset = offset
        let typeByte = data[currentOffset]
        currentOffset += 1

        // Simple space optimization
        if typeByte == 0x00 {
            return (BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil), currentOffset)
        }

        // Decode type byte
        let hasExtended = (typeByte & 0x80) != 0
        let isUnicode = (typeByte & 0x40) != 0
        let hasFg = (typeByte & 0x20) != 0
        let hasBg = (typeByte & 0x10) != 0
        let isRgbFg = (typeByte & 0x08) != 0
        let isRgbBg = (typeByte & 0x04) != 0

        // Read character
        var char: String
        var width: Int = 1

        if isUnicode {
            // Unicode character
            guard currentOffset < data.count else { return nil }
            let charLen = Int(data[currentOffset])
            currentOffset += 1

            guard currentOffset + charLen <= data.count else { return nil }
            let charData = data.subdata(in: currentOffset..<(currentOffset + charLen))
            char = String(data: charData, encoding: .utf8) ?? "?"
            currentOffset += charLen

            // Calculate display width for Unicode characters
            if let scalar = char.unicodeScalars.first {
                if scalar.properties.isEmoji {
                    width = 2
                } else {
                    // Check for CJK characters
                    let value = scalar.value
                    if (0x4E00...0x9FFF).contains(value) || // CJK Unified Ideographs
                       (0xAC00...0xD7AF).contains(value) || // Hangul Syllables
                       (0xFF00...0xFF60).contains(value) {  // Fullwidth Forms
                        width = 2
                    }
                }
            }
        } else {
            // ASCII character
            guard currentOffset < data.count else { return nil }
            let asciiCode = data[currentOffset]
            currentOffset += 1

            if asciiCode < 32 || asciiCode > 126 {
                char = asciiCode == 0 ? " " : "?"
            } else {
                char = String(Character(UnicodeScalar(asciiCode)))
            }
        }

        // Read colors and attributes if present
        var fg: Int?
        var bg: Int?
        var attributes: Int?

        if hasExtended {
            // Read attributes byte
            guard currentOffset < data.count else { return nil }
            attributes = Int(data[currentOffset])
            currentOffset += 1
        }

        if hasFg {
            if isRgbFg {
                // RGB color (3 bytes)
                guard currentOffset + 3 <= data.count else { return nil }
                let r = Int(data[currentOffset])
                let g = Int(data[currentOffset + 1])
                let b = Int(data[currentOffset + 2])
                fg = 0xFF000000 | (r << 16) | (g << 8) | b
                currentOffset += 3
            } else {
                // Palette color (1 byte)
                guard currentOffset < data.count else { return nil }
                fg = Int(data[currentOffset])
                currentOffset += 1
            }
        }

        if hasBg {
            if isRgbBg {
                // RGB color (3 bytes)
                guard currentOffset + 3 <= data.count else { return nil }
                let r = Int(data[currentOffset])
                let g = Int(data[currentOffset + 1])
                let b = Int(data[currentOffset + 2])
                bg = 0xFF000000 | (r << 16) | (g << 8) | b
                currentOffset += 3
            } else {
                // Palette color (1 byte)
                guard currentOffset < data.count else { return nil }
                bg = Int(data[currentOffset])
                currentOffset += 1
            }
        }

        return (BufferCell(char: char, width: width, fg: fg, bg: bg, attributes: attributes), currentOffset)
    }

    // MARK: - Ping/Pong Keepalive

    /// Start periodic ping task
    private func startPingTask() {
        stopPingTask()

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.pingInterval ?? 30.0) * 1_000_000_000)

                if !Task.isCancelled {
                    await self?.sendPing()
                }
            }
        }
    }

    /// Stop ping task
    private func stopPingTask() {
        pingTask?.cancel()
        pingTask = nil
    }

    /// Send ping to server
    private func sendPing() async {
        guard let webSocketTask = webSocketTask else { return }

        await withCheckedContinuation { continuation in
            webSocketTask.sendPing { error in
                if let error = error {
                    Task { @MainActor in
                        self.logger.error("[WS-CLIENT] Ping failed: \(error.localizedDescription)")
                    }
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Reconnection Logic

    /// Handle disconnection and schedule reconnect
    @MainActor
    private func handleDisconnection(error: Error? = nil) {
        logger.info("[WS-CLIENT] Handling disconnection")

        isConnected = false
        isConnecting = false
        connectionError = error

        stopPingTask()
        webSocketTask = nil

        // Schedule reconnection
        scheduleReconnect()
    }

    /// Schedule automatic reconnection with exponential backoff
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = min(pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1

        logger.info("[WS-CLIENT] Scheduling reconnect in \(delay) seconds (attempt \(self.reconnectAttempts))")

        reconnectTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            if !Task.isCancelled {
                self?.reconnectTask = nil
                await self?.connect()
            }
        }
    }

    deinit {
        // Cleanup will happen when object is deallocated
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        reconnectTask?.cancel()
        pingTask?.cancel()
    }
}

// MARK: - URLSessionWebSocketDelegate

extension VibeTunnelWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            logger.info("[WS-CLIENT] WebSocket connection opened with protocol: \(`protocol` ?? "none")")
            isConnected = true
            isConnecting = false
            reconnectAttempts = 0
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            logger.info("[WS-CLIENT] WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")
            handleDisconnection()
        }
    }
}