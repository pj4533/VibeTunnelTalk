import Foundation
import OSLog

/// Accumulates terminal buffer updates intelligently before sending to OpenAI
/// Handles both bursty data (lots of changes at once) and quiet periods (minimal changes over time)
/// Maintains a complete session transcript to preserve context even when terminal clears
class BufferAccumulator {
    private let logger = AppLogger.terminalProcessor

    // Configuration
    let sizeThreshold: Int         // Characters to accumulate before sending
    let timeThreshold: TimeInterval // Seconds to wait before sending accumulated data

    // State
    private var accumulatedContent = ""
    private var lastProcessedContent = "" // Track what we last processed to detect real changes
    private var firstAccumulationTime: Date?
    private var accumulationTimer: Timer?
    private var pendingSnapshots: [BufferSnapshot] = []
    private var totalAccumulatedChanges = 0

    // Session transcript tracking
    private var sessionTranscript = ""    // Complete history of all terminal content
    private var lastTranscriptSnapshot = "" // Last known terminal state for detecting clears
    private var lastSentIndex = 0          // Track what portion of transcript we've already sent

    // Callback
    private let onThresholdReached: (String, Int) -> Void

    init(sizeThreshold: Int = 100,  // Lower threshold for more responsive updates
         timeThreshold: TimeInterval = 2.0,
         onThresholdReached: @escaping (String, Int) -> Void) {
        self.sizeThreshold = sizeThreshold
        self.timeThreshold = timeThreshold
        self.onThresholdReached = onThresholdReached
    }

    /// Add a buffer snapshot to the accumulator
    func accumulate(_ snapshot: BufferSnapshot, extractedContent: String, changeCount: Int) {
        logger.debug("[ACCUMULATOR] Accumulating snapshot with \(changeCount) changed chars")

        // Update session transcript intelligently
        updateSessionTranscript(with: extractedContent)

        // Store the latest complete content (not incremental)
        accumulatedContent = extractedContent

        // Track total accumulated changes since last flush
        if changeCount > 0 {
            totalAccumulatedChanges += changeCount

            // Track when we started accumulating
            if firstAccumulationTime == nil {
                firstAccumulationTime = Date()
                logger.debug("[ACCUMULATOR] Starting new accumulation period")
            }
        }

        // Add to pending snapshots for potential analysis
        pendingSnapshots.append(snapshot)

        // Check if we should flush based on thresholds
        checkThresholds()
    }

    /// Intelligently update the session transcript with new content
    private func updateSessionTranscript(with newContent: String) {
        // If this is the first content, just set it
        if sessionTranscript.isEmpty {
            sessionTranscript = newContent
            lastTranscriptSnapshot = newContent
            logger.debug("[ACCUMULATOR] Initialized session transcript with \(newContent.count) chars")
            return
        }

        // Check if terminal was cleared (new content is significantly shorter or very different)
        let wasCleared = detectTerminalClear(from: lastTranscriptSnapshot, to: newContent)

        if wasCleared {
            // Terminal was cleared - append old content to transcript before adding new
            logger.info("[ACCUMULATOR] Terminal clear detected - preserving history")

            // If transcript doesn't already end with the last snapshot, append it
            if !sessionTranscript.hasSuffix(lastTranscriptSnapshot) {
                sessionTranscript += "\n" + lastTranscriptSnapshot
            }

            // Add a concise marker to indicate terminal was cleared
            sessionTranscript += "\n...\n"

            // Add the new content
            sessionTranscript += newContent
        } else {
            // Normal update - find what's truly new and append only that
            let newPortion = extractNewContent(from: lastTranscriptSnapshot, to: newContent)
            if !newPortion.isEmpty {
                sessionTranscript += newPortion
                logger.debug("[ACCUMULATOR] Appended \(newPortion.count) new chars to transcript")
            }
        }

        // Update our snapshot of the current terminal state
        lastTranscriptSnapshot = newContent
    }

    /// Detect if terminal was cleared based on content comparison
    private func detectTerminalClear(from old: String, to new: String) -> Bool {
        // Terminal clear indicators:
        // 1. New content is significantly shorter (>50% reduction)
        // 2. Common prefix is very small relative to old content

        if old.isEmpty { return false }

        // Check for significant size reduction
        let sizeReduction = Double(old.count - new.count) / Double(old.count)
        if sizeReduction > 0.5 {
            return true
        }

        // Check for minimal common prefix (terminal was cleared and rewritten)
        let commonPrefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let prefixRatio = Double(commonPrefix) / Double(old.count)
        if prefixRatio < 0.1 && new.count > 10 {  // Less than 10% common and new content exists
            return true
        }

        return false
    }

    /// Extract only the new content that was added
    private func extractNewContent(from old: String, to new: String) -> String {
        // Find the longest common prefix
        let commonPrefixLength = zip(old, new).prefix(while: { $0 == $1 }).count

        // Everything after the common prefix is new
        if commonPrefixLength < new.count {
            return String(new.suffix(new.count - commonPrefixLength))
        }

        return ""
    }

    private func checkThresholds() {
        // Don't flush empty content
        guard !accumulatedContent.isEmpty else { return }

        // Check if content actually changed from what we last processed
        let actualChanges = countChanges(from: lastProcessedContent, to: accumulatedContent)
        guard actualChanges > 0 else {
            logger.debug("[ACCUMULATOR] No actual changes detected from last processed content")
            return
        }

        var shouldFlush = false
        var reason = ""

        // Check size threshold based on accumulated changes
        if totalAccumulatedChanges >= sizeThreshold {
            shouldFlush = true
            reason = "size threshold (\(totalAccumulatedChanges) >= \(sizeThreshold))"
        }

        // Check time threshold if we've been accumulating
        if let startTime = firstAccumulationTime {
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime >= timeThreshold {
                shouldFlush = true
                reason = "time threshold (\(String(format: "%.1f", elapsedTime))s >= \(timeThreshold)s)"
            }
        }

        // For very large changes, flush immediately
        if actualChanges > sizeThreshold * 3 {
            shouldFlush = true
            reason = "large change detected (\(actualChanges) chars)"
        }

        if shouldFlush {
            logger.info("[ACCUMULATOR] Flushing due to \(reason)")
            flush()
        } else {
            // Start or reset timer for time-based flushing
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        // Only start timer if we have content and haven't started one yet
        guard !accumulatedContent.isEmpty && accumulationTimer == nil else { return }

        logger.debug("[ACCUMULATOR] Starting flush timer for \(self.timeThreshold) seconds")

        // Cancel any existing timer
        accumulationTimer?.invalidate()

        // Create new timer
        accumulationTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
            self?.handleTimerFired()
        }
    }

    private func handleTimerFired() {
        guard !accumulatedContent.isEmpty else {
            logger.debug("[ACCUMULATOR] Timer fired but no content to flush")
            return
        }

        // Check if content changed since we last processed
        let actualChanges = countChanges(from: lastProcessedContent, to: accumulatedContent)
        if actualChanges > 0 {
            logger.info("[ACCUMULATOR] Timer expired, flushing \(actualChanges) chars of changes")
            flush()
        } else {
            logger.debug("[ACCUMULATOR] Timer expired but no actual changes to flush")
        }
    }

    private func flush() {
        guard !sessionTranscript.isEmpty else {
            logger.debug("[ACCUMULATOR] Nothing to flush - empty transcript")
            return
        }

        // Calculate actual changes from last processed content
        let changeCount = countChanges(from: lastProcessedContent, to: accumulatedContent)

        guard changeCount > 0 else {
            logger.debug("[ACCUMULATOR] No actual changes to flush")
            resetState()
            return
        }

        // Extract only the new content that hasn't been sent yet
        let transcriptLength = sessionTranscript.count
        guard lastSentIndex < transcriptLength else {
            logger.debug("[ACCUMULATOR] All content already sent")
            resetState()
            return
        }

        // Get the unsent portion of the transcript
        let startIndex = sessionTranscript.index(sessionTranscript.startIndex, offsetBy: lastSentIndex)
        let unsentContent = String(sessionTranscript[startIndex...])

        logger.info("[ACCUMULATOR] Sending incremental update: \(unsentContent.count) new chars (position \(self.lastSentIndex) to \(transcriptLength) of \(transcriptLength) total)")

        // Send only the new content that hasn't been sent before
        onThresholdReached(unsentContent, changeCount)

        // Update our position in the transcript
        lastSentIndex = transcriptLength

        // Update last processed content
        lastProcessedContent = accumulatedContent

        // Reset accumulation state (but preserve transcript and sent position)
        resetState()
    }

    private func resetState() {
        // Clear temporary accumulation state
        accumulatedContent = ""
        pendingSnapshots.removeAll()
        firstAccumulationTime = nil
        totalAccumulatedChanges = 0

        // Cancel timer
        accumulationTimer?.invalidate()
        accumulationTimer = nil

        // IMPORTANT: Do NOT clear sessionTranscript, lastTranscriptSnapshot, or lastSentIndex
        // These must be preserved to maintain the full session history and track what's been sent
    }

    /// Count the number of character changes between two strings
    private func countChanges(from old: String, to new: String) -> Int {
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

    /// Force flush any pending data
    func forceFlush() {
        if !accumulatedContent.isEmpty {
            logger.info("[ACCUMULATOR] Force flushing pending data")
            flush()
        }
    }

    /// Stop accumulation and cleanup
    func stop() {
        logger.info("[ACCUMULATOR] Stopping accumulator")

        // Flush any pending data
        forceFlush()

        // Clean up timer
        accumulationTimer?.invalidate()
        accumulationTimer = nil

        // Clear all state including session transcript
        pendingSnapshots.removeAll()
        accumulatedContent = ""
        lastProcessedContent = ""
        firstAccumulationTime = nil
        totalAccumulatedChanges = 0
        sessionTranscript = ""
        lastTranscriptSnapshot = ""
        lastSentIndex = 0
    }

    deinit {
        stop()
    }
}