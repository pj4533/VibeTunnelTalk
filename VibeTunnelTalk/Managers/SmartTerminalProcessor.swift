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
    internal var lastBufferSnapshot: BufferSnapshot?

    // Accumulation for small changes
    internal var accumulatedDelta = "" // Stores just the accumulated text changes
    internal var accumulatedChangeCount = 0
    private var lastAccumulationTime = Date()
    private let maxAccumulationInterval: TimeInterval = 5.0 // Max time to hold accumulated changes

    // Subscriptions
    private var bufferSubscription: AnyCancellable?

    // Debug file for OpenAI updates
    var debugFileHandle: FileHandle?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.terminalProcessor)
    }

    /// Start processing buffer snapshots from buffer service
    func startProcessing(bufferService: VibeTunnelBufferService, sessionId: String) {
        logger.info("[PROCESSOR] Starting smart terminal processing for session: \(sessionId)")

        // Create debug file for this session
        createDebugFile()

        self.bufferService = bufferService

        // Subscribe to buffer updates
        bufferSubscription = bufferService.$currentBuffer
            .compactMap { $0 } // Filter out nil values
            // Removed duplicate detection - we want to process every buffer
            // to catch all changes, even small ones. The delta extraction
            // will handle identifying what actually changed.
            .sink { [weak self] snapshot in
                self?.logger.debug("[PROCESSOR] Received buffer snapshot from publisher")
                self?.processBufferSnapshot(snapshot)
            }

        isProcessing = true
    }

    /// Stop processing
    func stopProcessing() {
        logger.info("[PROCESSOR] Stopping smart terminal processing")

        // Flush any accumulated changes before stopping
        if accumulatedChangeCount > 0 {
            logger.info("[PROCESSOR] Discarding \(self.accumulatedChangeCount) accumulated chars on stop")
            accumulatedDelta = ""
            accumulatedChangeCount = 0
        }

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

        logger.info("[PROCESSOR] Processing buffer snapshot #\(self.totalSnapshotsProcessed)")

        // Extract text content from buffer
        let currentContent = extractTextFromBuffer(snapshot)
        logger.debug("[PROCESSOR] Extracted \(currentContent.count) characters from buffer")

        // Check if content has changed significantly
        let changeCount = countChanges(from: lastSentContent, to: currentContent)

        // Log periodically to track processing
        if totalSnapshotsProcessed % 10 == 0 {
            logger.debug("[PROCESSOR] Snapshot #\(self.totalSnapshotsProcessed): \(changeCount) chars changed")
        }

        // Handle changes based on threshold
        if changeCount >= minChangeThreshold {
            // Send current content with any accumulated deltas
            let totalChangeCount = accumulatedChangeCount + changeCount

            if !accumulatedDelta.isEmpty {
                // Combine current content with accumulated deltas
                let combinedContent = currentContent + "\n\n[Previous changes: " + accumulatedDelta + "]"
                logger.info("[PROCESSOR] Sending combined update: \(totalChangeCount) total chars (\(self.accumulatedChangeCount) accumulated + \(changeCount) current)")
                sendUpdateToOpenAI(combinedContent, changeCount: totalChangeCount)
            } else {
                // Send just the current content
                sendUpdateToOpenAI(currentContent, changeCount: changeCount)
            }

            // Reset accumulator
            accumulatedDelta = ""
            accumulatedChangeCount = 0
            lastSentContent = currentContent
            lastAccumulationTime = Date()
        } else if changeCount > 0 {
            // Extract and accumulate just the delta
            let delta = extractDelta(from: lastSentContent, to: currentContent)
            if !delta.isEmpty {
                if !accumulatedDelta.isEmpty {
                    accumulatedDelta += " "  // Add space between deltas
                }
                accumulatedDelta += delta
                accumulatedChangeCount += changeCount

                logger.debug("[PROCESSOR] Accumulated \(changeCount) chars (total accumulated: \(self.accumulatedChangeCount))")
            }

            // Check if accumulated changes now exceed threshold
            if accumulatedChangeCount >= minChangeThreshold {
                // Send current content with accumulated deltas
                let combinedContent = currentContent + "\n\n[Previous changes: " + accumulatedDelta + "]"
                logger.info("[PROCESSOR] Accumulated changes reached threshold: \(self.accumulatedChangeCount) chars")
                sendUpdateToOpenAI(combinedContent, changeCount: accumulatedChangeCount)
                lastSentContent = currentContent

                // Reset accumulator
                accumulatedDelta = ""
                accumulatedChangeCount = 0
                lastAccumulationTime = Date()
            } else {
                // Check if we should flush based on time
                let timeSinceLastAccumulation = Date().timeIntervalSince(lastAccumulationTime)
                if timeSinceLastAccumulation > maxAccumulationInterval && !accumulatedDelta.isEmpty {
                    // Send current content with accumulated deltas
                    let combinedContent = currentContent + "\n\n[Previous changes: " + accumulatedDelta + "]"
                    logger.info("[PROCESSOR] Flushing accumulated changes due to timeout: \(self.accumulatedChangeCount) chars after \(String(format: "%.1f", timeSinceLastAccumulation))s")
                    sendUpdateToOpenAI(combinedContent, changeCount: accumulatedChangeCount)
                    lastSentContent = currentContent

                    // Reset accumulator
                    accumulatedDelta = ""
                    accumulatedChangeCount = 0
                    lastAccumulationTime = Date()
                } else {
                    logger.debug("[PROCESSOR] Waiting for more changes (accumulated: \(self.accumulatedChangeCount)/\(self.minChangeThreshold))")
                    writeSkippedUpdateToDebugFile(currentContent, changeCount: changeCount, reason: "Accumulating (\(accumulatedChangeCount)/\(minChangeThreshold))")
                }
            }
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

    /// Extract just the delta (changed content) between two strings
    private func extractDelta(from old: String, to new: String) -> String {
        if old.isEmpty { return new }
        if new.isEmpty { return "[cleared]" }

        // Find common prefix
        let commonPrefixLength = zip(old, new).prefix(while: { $0 == $1 }).count

        // Find common suffix
        let oldSuffix = old.suffix(old.count - commonPrefixLength)
        let newSuffix = new.suffix(new.count - commonPrefixLength)
        let commonSuffixLength = zip(oldSuffix.reversed(), newSuffix.reversed()).prefix(while: { $0 == $1 }).count

        // Extract the changed portion
        let startIndex = new.index(new.startIndex, offsetBy: commonPrefixLength)
        let endIndex = new.index(new.endIndex, offsetBy: -commonSuffixLength)

        if startIndex < endIndex {
            return String(new[startIndex..<endIndex])
        }
        return ""
    }

    // MARK: - OpenAI Integration

    /// Send update to OpenAI
    private func sendUpdateToOpenAI(_ content: String, changeCount: Int) {
        logger.info("[PROCESSOR] sendUpdateToOpenAI called with \(content.count) chars, \(changeCount) changed")

        guard !content.isEmpty else {
            logger.warning("[PROCESSOR] Skipping update - content is empty")
            return
        }

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

        logger.info("[PROCESSOR] Sending update #\(self.totalUpdatesSent) to OpenAI: \(changeCount) chars changed, ratio: \(String(format: "%.1f%%", self.dataReductionRatio * 100))")

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