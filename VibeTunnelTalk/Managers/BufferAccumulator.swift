import Foundation
import OSLog

/// Accumulates terminal buffer updates intelligently before sending to OpenAI
/// Handles both bursty data (lots of changes at once) and quiet periods (minimal changes over time)
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
        guard !accumulatedContent.isEmpty else {
            logger.debug("[ACCUMULATOR] Nothing to flush")
            return
        }

        // Calculate actual changes from last processed content
        let changeCount = countChanges(from: lastProcessedContent, to: accumulatedContent)

        guard changeCount > 0 else {
            logger.debug("[ACCUMULATOR] No actual changes to flush")
            resetState()
            return
        }

        logger.info("[ACCUMULATOR] Flushing \(self.accumulatedContent.count) total chars with \(changeCount) changed chars")

        // Send accumulated content
        onThresholdReached(accumulatedContent, changeCount)

        // Update last processed content
        lastProcessedContent = accumulatedContent

        // Reset accumulation state
        resetState()
    }

    private func resetState() {
        accumulatedContent = ""
        pendingSnapshots.removeAll()
        firstAccumulationTime = nil
        totalAccumulatedChanges = 0

        // Cancel timer
        accumulationTimer?.invalidate()
        accumulationTimer = nil
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

        // Clear state
        pendingSnapshots.removeAll()
        accumulatedContent = ""
        lastProcessedContent = ""
        firstAccumulationTime = nil
        totalAccumulatedChanges = 0
    }

    deinit {
        stop()
    }
}