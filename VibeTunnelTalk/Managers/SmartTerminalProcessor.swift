import Foundation
import Combine
import OSLog

/// Processes terminal buffer snapshots intelligently by detecting changes and sending them to OpenAI
class SmartTerminalProcessor: ObservableObject {
    let logger = AppLogger.terminalProcessor
    private let debouncedLogger: DebouncedLogger
    private var statsLogger: BufferStatisticsLogger

    // Dependencies
    private let openAIManager: OpenAIRealtimeManager

    // Configuration
    @Published var minChangeThreshold: Int = 5 // Minimum character changes to trigger update

    // State tracking
    @Published var isProcessing = false
    @Published var lastUpdate = Date()
    @Published var totalSnapshotsProcessed = 0
    @Published var totalUpdatesSent = 0
    @Published var dataReductionRatio: Double = 0.0

    // For diffing
    internal var lastSentContent = ""
    internal var lastBufferSnapshot: BufferSnapshot?

    // Subscriptions

    // Debug file for OpenAI updates
    var debugFileHandle: FileHandle?

    // WebSocket accumulator
    private var currentAccumulator: BufferAccumulator?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.terminalProcessor)
        self.statsLogger = BufferStatisticsLogger(logger: AppLogger.terminalProcessor)
    }

    /// Start processing buffer snapshots from WebSocket client
    func startProcessingWithBufferClient(bufferClient: BufferWebSocketClient?, sessionId: String) async {
        logger.info("Starting smart terminal processor for session: \(sessionId)")

        // Create debug file for this session
        createDebugFile()
        logger.debug("Debug file created")

        // Subscribe to WebSocket updates
        guard let bufferClient = bufferClient else {
            logger.warning("No WebSocket client provided")
            return
        }

        // Create accumulator with intelligent thresholds
        let accumulator = BufferAccumulator(
            sizeThreshold: 100,    // Send when 100+ chars change (more responsive)
            timeThreshold: 2.0     // Send after 2 seconds of inactivity
        ) { [weak self] content, changeCount in
            guard let self = self else { return }

            // Update lastSentContent to track what we've sent
            self.lastSentContent = content

            // Send to OpenAI
            self.sendUpdateToOpenAI(content, changeCount: changeCount)
        }

        self.currentAccumulator = accumulator
        logger.debug("Created accumulator (100 chars / 2.0s thresholds)")

        logger.debug("Subscribing to WebSocket updates")

        // Subscribe to buffer updates from WebSocket
        bufferClient.subscribe(to: sessionId) { [weak self] event in
            guard let self = self else { return }

            switch event {
            case .bufferUpdate(let snapshot):
                // Process buffer update
                self.processWebSocketSnapshot(snapshot)

            case .bell:
                self.logger.debug("Bell event received")
                // Could play a bell sound here if desired

            default:
                break
            }
        }

        logger.debug("WebSocket subscription completed")
        isProcessing = true
        logger.info("✅ Processing started")
    }

    /// Process a snapshot received via WebSocket
    private func processWebSocketSnapshot(_ snapshot: BufferSnapshot) {
        totalSnapshotsProcessed += 1

        logger.verbose("Processing snapshot #\(self.totalSnapshotsProcessed)")

        // Extract text content from buffer
        let currentContent = extractTextFromBuffer(snapshot)
        logger.verbose("Extracted \(currentContent.count) characters")

        // Check if content has changed from what we last sent
        let changeCount = countChanges(from: lastSentContent, to: currentContent)

        // Record statistics instead of logging each snapshot
        statsLogger.recordSnapshot(charsExtracted: currentContent.count, charsChanged: changeCount, sentToOpenAI: false)

        // Pass to accumulator - it will decide when to flush based on thresholds
        currentAccumulator?.accumulate(snapshot, extractedContent: currentContent, changeCount: changeCount)

        lastBufferSnapshot = snapshot
        lastUpdate = Date()
    }

    /// Stop processing
    func stopProcessing() {
        logger.info("⏹️ Stopping smart terminal processing")
        statsLogger.forceLogSummary()

        // Stop accumulator and flush any pending data
        currentAccumulator?.stop()
        currentAccumulator = nil

        debugFileHandle?.closeFile()
        debugFileHandle = nil

        isProcessing = false
    }

    /// Cleanup resources
    func cleanup() {
        stopProcessing()
    }

    // MARK: - Buffer Processing

    /// Extract text content from buffer snapshot
    internal func extractTextFromBuffer(_ snapshot: BufferSnapshot) -> String {
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
    internal func countChanges(from old: String, to new: String) -> Int {
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
    internal func sendUpdateToOpenAI(_ content: String, changeCount: Int) {
        logger.debug("Sending \(changeCount) changed chars to OpenAI")

        guard !content.isEmpty else {
            logger.debug("Skipping empty content")
            return
        }

        // Log if OpenAI is speaking but still send the update
        // OpenAI can handle concurrent updates
        if openAIManager.isSpeaking {
            logger.verbose("OpenAI is speaking, sending update anyway")
        }

        totalUpdatesSent += 1

        // Calculate data reduction ratio
        let originalSize = totalSnapshotsProcessed * (80 * 24) // Approximate
        let sentSize = totalUpdatesSent * content.count
        if originalSize > 0 {
            dataReductionRatio = 1.0 - (Double(sentSize) / Double(originalSize))
        }

        // Update statistics
        statsLogger.recordSnapshot(charsExtracted: content.count, charsChanged: changeCount, sentToOpenAI: true)

        logger.info("📤 Update #\(self.totalUpdatesSent): \(changeCount) chars, reduction: \(String(format: "%.1f%%", self.dataReductionRatio * 100))")

        // Format the terminal content for OpenAI
        let formattedContent = formatForOpenAI(content)

        // Write the formatted content to debug file (what we're actually sending to OpenAI)
        writeToDebugFile(formattedContent)

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