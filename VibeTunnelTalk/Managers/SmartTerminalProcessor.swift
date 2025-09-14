import Foundation
import Combine
import OSLog

/// Processes terminal buffer snapshots intelligently by detecting changes and sending them to OpenAI
class SmartTerminalProcessor: ObservableObject {
    let logger = AppLogger.terminalProcessor
    private let debouncedLogger: DebouncedLogger

    // Dependencies
    private let openAIManager: OpenAIRealtimeManager
    private var bufferService: VibeTunnelBufferService?

    // Configuration
    @Published var minChangeThreshold: Int = 5 // Minimum character changes to trigger update

    // State tracking
    @Published var isProcessing = false
    @Published var lastUpdate = Date()
    @Published var totalSnapshotsProcessed = 0
    @Published var totalUpdatesSent = 0
    @Published var dataReductionRatio: Double = 0.0

    // For diffing
    private var lastSentContent = ""
    private var lastBufferSnapshot: BufferSnapshot?

    // Subscriptions
    private var bufferSubscription: AnyCancellable?

    // Debug file for OpenAI updates
    var debugFileHandle: FileHandle?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.terminalProcessor)
        createDebugFile()
    }

    /// Start processing buffer snapshots from buffer service
    func startProcessing(bufferService: VibeTunnelBufferService, sessionId: String) {
        logger.info("[PROCESSOR] Starting smart terminal processing for session: \(sessionId)")

        self.bufferService = bufferService

        // Subscribe to buffer updates
        bufferSubscription = bufferService.$currentBuffer
            .compactMap { $0 } // Filter out nil values
            .removeDuplicates { prev, current in
                // Only process if the buffer content has actually changed
                self.areBuffersEqual(prev, current)
            }
            .sink { [weak self] snapshot in
                self?.processBufferSnapshot(snapshot)
            }

        isProcessing = true
    }

    /// Stop processing
    func stopProcessing() {
        logger.info("[PROCESSOR] Stopping smart terminal processing")

        bufferSubscription?.cancel()
        bufferSubscription = nil
        bufferService = nil
        debugFileHandle?.closeFile()
        debugFileHandle = nil

        isProcessing = false
    }

    /// Cleanup resources
    func cleanup() {
        stopProcessing()
    }

    /// Get the current buffer snapshot for display
    func getCurrentBufferSnapshot() -> BufferSnapshot? {
        return bufferService?.currentBuffer
    }

    // MARK: - Buffer Processing

    /// Process a buffer snapshot
    private func processBufferSnapshot(_ snapshot: BufferSnapshot) {
        totalSnapshotsProcessed += 1

        // Extract text content from buffer
        let currentContent = extractTextFromBuffer(snapshot)

        // Check if content has changed significantly
        let changeCount = countChanges(from: lastSentContent, to: currentContent)

        // Log periodically to track processing
        if totalSnapshotsProcessed % 10 == 0 {
            logger.debug("[PROCESSOR] Snapshot #\(self.totalSnapshotsProcessed): \(changeCount) chars changed")
        }

        // Only send update if changes exceed threshold
        if changeCount >= minChangeThreshold {
            sendUpdateToOpenAI(currentContent, changeCount: changeCount)
            lastSentContent = currentContent
        }

        lastBufferSnapshot = snapshot
        lastUpdate = Date()
    }

    /// Extract text content from buffer snapshot
    private func extractTextFromBuffer(_ snapshot: BufferSnapshot) -> String {
        var lines: [String] = []

        for row in snapshot.cells {
            var line = ""
            for cell in row {
                line += cell.displayChar
            }
            // Trim trailing spaces but preserve intentional spacing
            lines.append(line.trimmingCharacters(in: .init(charactersIn: " ")))
        }

        // Remove empty lines from the end
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }

    /// Check if two buffers are effectively equal
    private func areBuffersEqual(_ buffer1: BufferSnapshot, _ buffer2: BufferSnapshot) -> Bool {
        // Quick dimension check
        if buffer1.cols != buffer2.cols || buffer1.rows != buffer2.rows {
            return false
        }

        // Check if cursor position changed significantly
        if abs(buffer1.cursorX - buffer2.cursorX) > 5 || abs(buffer1.cursorY - buffer2.cursorY) > 2 {
            return false
        }

        // Compare actual content
        let content1 = extractTextFromBuffer(buffer1)
        let content2 = extractTextFromBuffer(buffer2)

        return content1 == content2
    }

    /// Count the number of character changes between two strings
    private func countChanges(from old: String, to new: String) -> Int {
        // Simple character difference count
        if old.isEmpty { return new.count }
        if new.isEmpty { return old.count }

        // Find common prefix
        let commonPrefixLength = zip(old, new).prefix(while: { $0 == $1 }).count

        // Find common suffix
        let oldSuffix = old.suffix(old.count - commonPrefixLength)
        let newSuffix = new.suffix(new.count - commonPrefixLength)
        let commonSuffixLength = zip(oldSuffix.reversed(), newSuffix.reversed()).prefix(while: { $0 == $1 }).count

        // Calculate changed region
        let oldChangedLength = old.count - commonPrefixLength - commonSuffixLength
        let newChangedLength = new.count - commonPrefixLength - commonSuffixLength

        return max(oldChangedLength, newChangedLength)
    }

    // MARK: - OpenAI Integration

    /// Send update to OpenAI
    private func sendUpdateToOpenAI(_ content: String, changeCount: Int) {
        guard !content.isEmpty else { return }

        // Don't send updates if OpenAI is currently speaking
        guard !openAIManager.isSpeaking else {
            logger.debug("[PROCESSOR] Skipping update - OpenAI is speaking")
            return
        }

        totalUpdatesSent += 1

        // Calculate data reduction ratio
        let originalSize = totalSnapshotsProcessed * (80 * 24) // Approximate
        let sentSize = totalUpdatesSent * content.count
        if originalSize > 0 {
            dataReductionRatio = 1.0 - (Double(sentSize) / Double(originalSize))
        }

        logger.info("[PROCESSOR] Sending update to OpenAI: \(changeCount) chars changed, ratio: \(String(format: "%.1f%%", self.dataReductionRatio * 100))")

        // Write to debug file
        writeToDebugFile(content)

        // Format the terminal content for OpenAI
        let formattedContent = formatForOpenAI(content)

        // Send to OpenAI
        openAIManager.sendTerminalContext(formattedContent)
    }

    /// Format terminal content for OpenAI
    private func formatForOpenAI(_ content: String) -> String {
        // Add context about what this is
        return """
        [Terminal Output Update]
        \(content)
        """
    }

}