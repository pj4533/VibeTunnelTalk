import Foundation
import OSLog

/// Accumulates terminal buffer updates from real-time WebSocket streaming
/// Designed specifically for WebSocket's continuous buffer snapshots, not polling
class BufferAccumulator {
    private let logger = AppLogger.accumulator
    private var totalSnapshotsProcessed = 0

    // Configuration
    let sizeThreshold: Int         // Characters to accumulate before sending
    let timeThreshold: TimeInterval // Seconds to wait before sending accumulated data

    // Line tracking for WebSocket streaming
    private var previousBufferLines: [String] = []  // Lines from the last buffer we processed

    // Session transcript - accumulates ALL content we've seen
    private var sessionTranscript = ""
    private var lastSentIndex = 0  // Track what we've already sent to OpenAI

    // Pending content for threshold checking
    private var pendingContent = ""
    private var pendingContentSize = 0
    private var firstAccumulationTime: Date?
    private var accumulationTimer: Timer?

    // Callback
    private let onThresholdReached: (String, Int) -> Void

    init(sizeThreshold: Int = 100,
         timeThreshold: TimeInterval = 2.0,
         onThresholdReached: @escaping (String, Int) -> Void) {
        self.sizeThreshold = sizeThreshold
        self.timeThreshold = timeThreshold
        self.onThresholdReached = onThresholdReached
    }

    /// Process a buffer snapshot from WebSocket
    func accumulate(_ snapshot: BufferSnapshot, extractedContent: String, changeCount: Int) {
        // Convert the buffer content to lines for comparison
        let currentBufferLines = extractedContent.components(separatedBy: .newlines)

        // Check for both new content AND changed content
        let (newContent, hasInPlaceChanges) = findContentChanges(from: previousBufferLines, to: currentBufferLines)

        if !newContent.isEmpty {
            logger.info("📝 Found \(newContent.count) chars of NEW content (pending: \(self.pendingContentSize))")

            // Add to session transcript
            sessionTranscript += newContent

            // Add to pending content for threshold checking
            pendingContent += newContent
            pendingContentSize += newContent.count

            // Start accumulation timer if this is the first content
            if firstAccumulationTime == nil {
                firstAccumulationTime = Date()
                logger.info("⏱️ Starting accumulation period")
            }
        } else if hasInPlaceChanges && changeCount > minChangeThreshold {
            // Handle in-place updates (like progress indicators, status updates)
            logger.info("🔄 Detected \(changeCount) chars of in-place changes")

            // For in-place changes, send the entire current buffer content
            // This ensures OpenAI sees the updated state
            let fullContent = currentBufferLines.joined(separator: "\n")

            // Add a marker to indicate this is an update, not new content
            let updateContent = "\n[Buffer Update]\n" + fullContent + "\n"

            sessionTranscript += updateContent
            pendingContent += updateContent
            pendingContentSize += updateContent.count

            // Start accumulation timer if needed
            if firstAccumulationTime == nil {
                firstAccumulationTime = Date()
                logger.info("⏱️ Starting accumulation period for in-place update")
            }
        } else {
            // Log when we find no new content (this might be the issue)
            if totalSnapshotsProcessed % 10 == 0 {
                logger.debug("🔄 No significant changes in snapshot #\(self.totalSnapshotsProcessed)")
            }
        }

        // Update our previous buffer for next comparison
        previousBufferLines = currentBufferLines

        // Debug: Log accumulator state periodically
        totalSnapshotsProcessed += 1
        if totalSnapshotsProcessed % 10 == 0 {
            logger.info("📊 Accumulator state: pending=\(self.pendingContentSize) chars, transcript=\(self.sessionTranscript.count) chars, sent=\(self.lastSentIndex) chars")
        }

        // Check if we should flush based on thresholds
        checkThresholds()
    }

    // Add minimum change threshold
    private let minChangeThreshold = 5

    /// Find both new content and in-place changes by comparing consecutive buffer snapshots
    private func findContentChanges(from oldLines: [String], to newLines: [String]) -> (newContent: String, hasInPlaceChanges: Bool) {
        // First buffer - everything is new
        if oldLines.isEmpty {
            let content = newLines.joined(separator: "\n")
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (content + "\n", false)
            }
            return ("", false)
        }

        // Check for in-place changes first (same number of lines but different content)
        if oldLines.count == newLines.count {
            var hasChanges = false
            for (oldLine, newLine) in zip(oldLines, newLines) {
                if oldLine != newLine {
                    hasChanges = true
                    break
                }
            }

            if hasChanges {
                // Lines are in the same positions but content changed
                return ("", true)
            }
        }

        // Find the overlap between old and new buffers
        // This handles scrolling where lines shift up

        // Strategy: Find where the old buffer's content appears in the new buffer
        // Example: old=[A,B,C,D], new=[B,C,D,E] -> E is new
        //         old=[A,B,C,D], new=[C,D,E,F] -> E,F are new

        var newContent = ""
        var foundOverlap = false

        // Look for where the old buffer ends within the new buffer
        for i in 0..<newLines.count {
            // Check if the remaining old lines match the beginning of new[i...]
            let remainingNew = Array(newLines[i...])

            // Find the longest suffix of old that matches a prefix of remainingNew
            for j in (0..<oldLines.count).reversed() {
                let oldSuffix = Array(oldLines[j...])

                if remainingNew.starts(with: oldSuffix) {
                    // Found overlap! Everything after this overlap is new
                    foundOverlap = true
                    let newStartIndex = i + oldSuffix.count

                    if newStartIndex < newLines.count {
                        let newLineContent = Array(newLines[newStartIndex...])
                        newContent = newLineContent.joined(separator: "\n")
                        if !newContent.isEmpty {
                            newContent += "\n"
                        }
                    }
                    break
                }
            }
            if foundOverlap { break }
        }

        // If no overlap found, check if new extends old (content added at bottom)
        if !foundOverlap {
            // Check if new buffer starts with the end of old buffer
            for i in 0..<oldLines.count {
                let oldSuffix = Array(oldLines[i...])
                if newLines.starts(with: oldSuffix) {
                    // New content was added after old
                    let newStartIndex = oldSuffix.count
                    if newStartIndex < newLines.count {
                        let newLineContent = Array(newLines[newStartIndex...])
                        newContent = newLineContent.joined(separator: "\n")
                        if !newContent.isEmpty {
                            newContent += "\n"
                        }
                    }
                    foundOverlap = true
                    break
                }
            }
        }

        // If still no overlap, terminal was likely cleared or completely changed
        if !foundOverlap && !newLines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.debug("No overlap found - terminal likely cleared or completely changed")
            // This is considered new content, not in-place change
            newContent = "\n---\n" + newLines.joined(separator: "\n") + "\n"
        }

        return (newContent, false)
    }

    private func checkThresholds() {
        guard pendingContentSize > 0 else { return }

        var shouldFlush = false
        var reason = ""

        // Check size threshold
        if pendingContentSize >= sizeThreshold {
            shouldFlush = true
            reason = "size threshold (\(pendingContentSize) >= \(sizeThreshold))"
        }

        // Check time threshold
        if let startTime = firstAccumulationTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeThreshold {
                shouldFlush = true
                reason = "time threshold (\(String(format: "%.1f", elapsed))s >= \(timeThreshold)s)"
            }
        }

        if shouldFlush {
            logger.info("💧 Flushing due to \(reason)")
            flush()
        } else {
            // Start timer if we have content but haven't started one
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard pendingContentSize > 0 && accumulationTimer == nil else { return }

        logger.debug("⏲️ Starting \(self.timeThreshold)s flush timer for \(self.pendingContentSize) pending chars")
        accumulationTimer?.invalidate()
        accumulationTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func timerFired() {
        if pendingContentSize > 0 {
            logger.info("⏰ Timer expired, flushing \(self.pendingContentSize) chars")
            flush()
        }
    }

    private func flush() {
        guard !sessionTranscript.isEmpty else { return }

        // Get the unsent portion of the transcript
        let transcriptLength = sessionTranscript.count
        guard lastSentIndex < transcriptLength else {
            logger.verbose("All content already sent")
            resetPendingState()
            return
        }

        // Extract only what hasn't been sent yet
        let startIndex = sessionTranscript.index(sessionTranscript.startIndex, offsetBy: lastSentIndex)
        let unsentContent = String(sessionTranscript[startIndex...])

        logger.info("📤 Sending \(unsentContent.count) new chars to OpenAI (position \(self.lastSentIndex) to \(transcriptLength))")

        // Send the unsent content
        onThresholdReached(unsentContent, pendingContentSize)

        // Update our sent position
        lastSentIndex = transcriptLength

        // Reset pending state
        resetPendingState()
    }

    private func resetPendingState() {
        pendingContent = ""
        pendingContentSize = 0
        firstAccumulationTime = nil
        accumulationTimer?.invalidate()
        accumulationTimer = nil
    }

    /// Force flush any pending data
    func forceFlush() {
        if pendingContentSize > 0 {
            logger.debug("Force flushing \(self.pendingContentSize) chars")
            flush()
        }
    }

    /// Stop accumulation and cleanup
    func stop() {
        logger.debug("Stopping accumulator")

        // Flush any pending data
        forceFlush()

        // Clean up
        accumulationTimer?.invalidate()
        accumulationTimer = nil

        // Reset all state
        previousBufferLines.removeAll()
        sessionTranscript = ""
        lastSentIndex = 0
        pendingContent = ""
        pendingContentSize = 0
        firstAccumulationTime = nil
    }

    deinit {
        stop()
    }
}