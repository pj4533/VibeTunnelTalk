import Foundation
import Combine
import OSLog

/// Service for fetching terminal buffer snapshots from VibeTunnel API
class VibeTunnelBufferService: ObservableObject {
    private let logger = AppLogger.network

    @Published var currentBuffer: BufferSnapshot?
    @Published var isLoading = false
    @Published var error: Error?

    private var timer: Timer?
    private var sessionId: String?
    private var authService: VibeTunnelAuthService?

    // Retry logic properties
    private var retryCount = 0
    private var maxRetries = 3
    private var lastAuthFailureTime: Date?
    private var isRefreshingToken = false

    /// Configure with authentication service
    func configure(authService: VibeTunnelAuthService) {
        self.authService = authService
    }

    /// Start polling for buffer updates
    func startPolling(sessionId: String, interval: TimeInterval = 0.5) {
        self.sessionId = sessionId
        stopPolling()

        // Initial fetch
        fetchBuffer()

        // Set up polling timer
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            self.fetchBuffer()
        }
    }

    /// Stop polling for buffer updates
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        // Reset retry state when stopping
        retryCount = 0
        isRefreshingToken = false
        lastAuthFailureTime = nil
    }

    /// Calculate exponential backoff delay
    private func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        // Base delay: 0.5 seconds
        // Max delay: 8 seconds
        // Formula: min(baseDelay * 2^(attempt-1), maxDelay)
        let baseDelay: TimeInterval = 0.5
        let maxDelay: TimeInterval = 8.0
        let delay = min(baseDelay * pow(2.0, Double(attempt - 1)), maxDelay)
        // Add jitter (0-25% of delay) to avoid thundering herd
        let jitter = Double.random(in: 0...0.25) * delay
        return delay + jitter
    }

    /// Fetch buffer snapshot from VibeTunnel API
    private func fetchBuffer() {
        guard let sessionId = sessionId else { return }

        // Build URL for local VibeTunnel server
        let urlString = "http://localhost:4020/api/sessions/\(sessionId)/buffer"
        guard let url = URL(string: urlString) else {
            logger.error("[BUFFER-SERVICE] Invalid URL: \(urlString)")
            return
        }

        Task {
            await fetchBufferAsync(from: url)
        }
    }

    @MainActor
    private func fetchBufferAsync(from url: URL) async {
        do {
            var request = URLRequest(url: url)

            // Add JWT token if authentication is required
            if let authService = authService,
               let token = try? await authService.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            switch httpResponse.statusCode {
            case 200:
                // Check content type
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

                if contentType.contains("application/octet-stream") {
                    // Binary buffer format
                    if let snapshot = try? decodeBinaryBuffer(data) {
                        self.currentBuffer = snapshot
                        self.error = nil
                    }
                } else if contentType.contains("application/json") {
                    // JSON format
                    let decoder = JSONDecoder()
                    let snapshot = try decoder.decode(BufferSnapshot.self, from: data)
                    self.currentBuffer = snapshot
                    self.error = nil
                }

            case 401:
                // Authentication failed, token might be expired
                logger.warning("[BUFFER-SERVICE] Received 401 - attempting to handle authentication issue")

                // Only attempt refresh if we're not already refreshing and haven't exceeded retry limit
                if let authService = authService,
                   !isRefreshingToken,
                   retryCount < maxRetries {

                    isRefreshingToken = true
                    retryCount += 1

                    // Calculate backoff delay
                    let delay = calculateBackoffDelay(attempt: retryCount)
                    logger.info("[BUFFER-SERVICE] Attempting token refresh after \(String(format: "%.2f", delay))s delay (attempt \(self.retryCount)/\(self.maxRetries))")

                    // Wait with exponential backoff before retrying
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                    // Attempt to refresh the token
                    let refreshSuccess = await authService.refreshToken()

                    if refreshSuccess {
                        logger.info("[BUFFER-SERVICE] Token refresh successful, retrying request")
                        // Reset retry count on successful refresh
                        retryCount = 0
                        isRefreshingToken = false

                        // Retry the fetch with new token
                        await fetchBufferAsync(from: url)
                        return
                    } else {
                        logger.warning("[BUFFER-SERVICE] Token refresh failed")
                    }

                    isRefreshingToken = false
                }

                // If we've exhausted retries or refresh failed, then mark as not authenticated
                if retryCount >= maxRetries {
                    logger.error("[BUFFER-SERVICE] Authentication failed after \(self.maxRetries) retry attempts")

                    // Only invalidate authentication after multiple failures within a short time
                    let now = Date()
                    if let lastFailure = lastAuthFailureTime,
                       now.timeIntervalSince(lastFailure) < 5.0 {
                        // Multiple failures within 5 seconds, invalidate authentication
                        if let authService = authService {
                            await MainActor.run {
                                authService.isAuthenticated = false
                                authService.authError = .tokenExpired
                            }
                        }
                        // Reset retry count for next session
                        retryCount = 0
                    }
                    lastAuthFailureTime = now
                }

                self.error = VibeTunnelAuthService.AuthError.tokenExpired

            default:
                logger.error("[BUFFER-SERVICE] HTTP error: \(httpResponse.statusCode)")
            }
        } catch {
            // Don't log every fetch error to avoid spam
            if self.error == nil {
                logger.error("[BUFFER-SERVICE] Failed to fetch buffer: \(error.localizedDescription)")
            }
            self.error = error
        }
    }

    /// Decode binary buffer format from VibeTunnel (based on iOS implementation)
    private func decodeBinaryBuffer(_ data: Data) throws -> BufferSnapshot? {
        var offset = 0

        // Read header
        guard data.count >= 32 else {
            logger.error("[BUFFER-SERVICE] Buffer too small for header: \(data.count) bytes (need 32)")
            return nil
        }

        // Magic bytes "VT" (0x5654 in little endian)
        let magic = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
        offset += 2

        guard magic == 0x5654 else {
            logger.error("[BUFFER-SERVICE] Invalid magic bytes: \(String(format: "0x%04X", magic)), expected 0x5654")
            return nil
        }

        // Version
        let version = data[offset]
        offset += 1

        guard version == 0x01 else {
            logger.error("[BUFFER-SERVICE] Unsupported version: 0x\(String(format: "%02X", version)), expected 0x01")
            return nil
        }

        // Flags
        let flags = data[offset]
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
            logger.error("[BUFFER-SERVICE] Invalid dimensions: \(cols)x\(rows)")
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
        let charType = typeByte & 0x03

        // Read character
        var char: String
        var width: Int = 1

        if charType == 0x00 {
            // Simple space
            char = " "
        } else if isUnicode {
            // Unicode character
            guard currentOffset < data.count else { return nil }
            let charLen = Int(data[currentOffset])
            currentOffset += 1

            guard currentOffset + charLen <= data.count else { return nil }
            let charData = data.subdata(in: currentOffset..<(currentOffset + charLen))
            char = String(data: charData, encoding: .utf8) ?? "?"
            currentOffset += charLen
            // Unicode chars can be wide
            width = char.unicodeScalars.first?.properties.isEmojiPresentation == true ? 2 : 1
        } else {
            // ASCII character
            guard currentOffset < data.count else { return nil }
            let asciiCode = data[currentOffset]
            currentOffset += 1
            char = String(Character(UnicodeScalar(asciiCode)))
        }

        // Read colors if present
        var fg: Int?
        var bg: Int?

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

        // Read attributes if extended flag is set
        var attributes: Int?
        if hasExtended {
            guard currentOffset < data.count else { return nil }
            attributes = Int(data[currentOffset])
            currentOffset += 1
        }

        return (BufferCell(char: char, width: width, fg: fg, bg: bg, attributes: attributes), currentOffset)
    }

    deinit {
        stopPolling()
    }
}