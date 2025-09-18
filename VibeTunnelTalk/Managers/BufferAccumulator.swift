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

        // Check for content changes with improved scrollback detection
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
            // FALLBACK: If our smart detection missed something, check if buffer content changed significantly
            // This is a safety net for cases where scrolling happens so fast we can't track it
            if changeCount > 50 { // Significant change threshold
                logger.info("🔄 Significant buffer change detected (\(changeCount) chars), including full buffer state")

                let fullContent = currentBufferLines.joined(separator: "\n")
                if !fullContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let safetyContent = "\n[Buffer State Update - \(changeCount) chars changed]\n" + fullContent + "\n"

                    sessionTranscript += safetyContent
                    pendingContent += safetyContent
                    pendingContentSize += safetyContent.count

                    if firstAccumulationTime == nil {
                        firstAccumulationTime = Date()
                        logger.info("⏱️ Starting accumulation period for safety buffer")
                    }
                }
            } else {
                // Log when we find no new content
                if totalSnapshotsProcessed % 10 == 0 {
                    logger.debug("🔄 No significant changes in snapshot #\(self.totalSnapshotsProcessed)")
                }
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

    // Scrollback tracking for better content capture
    private var fullBufferHistory: [String] = []  // Keep a longer history for analysis

    /// Find meaningful content changes with improved scrollback detection
    private func findContentChanges(from oldLines: [String], to newLines: [String]) -> (newContent: String, hasInPlaceChanges: Bool) {
        // First buffer - everything is new
        if oldLines.isEmpty {
            let content = newLines.joined(separator: "\n")
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (content + "\n", false)
            }
            return ("", false)
        }

        // IMPROVED APPROACH: Track all content that appears, handle scrolling better

        // Case 1: More lines (new content added)
        if newLines.count > oldLines.count {
            let linesDiff = newLines.count - oldLines.count

            // Check if old content appears at beginning (simple append case)
            let oldPrefix = Array(newLines.prefix(oldLines.count))
            if oldPrefix == oldLines {
                // Simple append - new lines added at bottom
                let newLinesAdded = Array(newLines.suffix(linesDiff))
                let newContent = newLinesAdded.joined(separator: "\n")
                if !newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (newContent + "\n", false)
                }
            } else {
                // Content scrolled - find overlap and extract all new lines
                let newContent = detectScrollingContent(oldLines: oldLines, newLines: newLines)
                if !newContent.isEmpty {
                    return (newContent, false)
                }
            }
        }

        // Case 2: Same number of lines (in-place changes)
        else if oldLines.count == newLines.count {
            let meaningfulChanges = detectMeaningfulInPlaceChanges(oldLines: oldLines, newLines: newLines)
            if !meaningfulChanges.isEmpty {
                return (meaningfulChanges, false)
            }

            // Check for noise/animation changes
            if hasOnlyNoiseChanges(oldLines: oldLines, newLines: newLines) {
                return ("", false)
            }
        }

        // Case 3: Fewer lines (cleared or major change)
        else if newLines.count < oldLines.count {
            // Likely a clear screen or major content change
            let content = newLines.joined(separator: "\n")
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("\n[Terminal Cleared]\n" + content + "\n", false)
            }
        }

        return ("", false)
    }

    /// Detect new content when old content has scrolled (improved algorithm)
    private func detectScrollingContent(oldLines: [String], newLines: [String]) -> String {
        // This is the key improvement: capture ALL content that appeared,
        // not just what's visible at the end

        // Strategy: Find the best overlap between old and new content,
        // then capture everything that's new

        var allNewContent: [String] = []

        // First, try to find where old content appears in new buffer
        let overlapFound = findContentOverlap(oldLines: oldLines, newLines: newLines)

        if let (overlapStart, overlapLength) = overlapFound {
            // We found where old content appears in new buffer

            // Content before the overlap is new (scrolled content)
            if overlapStart > 0 {
                let scrolledContent = Array(newLines[0..<overlapStart])
                allNewContent.append(contentsOf: scrolledContent)
            }

            // Content after the overlap is new (appended content)
            let afterOverlapStart = overlapStart + overlapLength
            if afterOverlapStart < newLines.count {
                let appendedContent = Array(newLines[afterOverlapStart...])
                allNewContent.append(contentsOf: appendedContent)
            }
        } else {
            // No clear overlap found - treat all new lines as potentially new content
            // This handles cases where there's significant scrolling

            // Find any lines that weren't in the old buffer
            for newLine in newLines {
                if !oldLines.contains(newLine) {
                    allNewContent.append(newLine)
                }
            }
        }

        // Filter and return new content
        let newContentText = allNewContent.joined(separator: "\n")
        if !newContentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return newContentText + "\n"
        }

        return ""
    }

    /// Find the best overlap between old and new content
    private func findContentOverlap(oldLines: [String], newLines: [String]) -> (start: Int, length: Int)? {
        let minOverlapLength = min(3, oldLines.count) // Minimum overlap to consider valid
        var bestOverlap: (start: Int, length: Int)? = nil

        // Try different overlap lengths, starting with longer ones
        for overlapLength in stride(from: min(oldLines.count, newLines.count), through: minOverlapLength, by: -1) {

            // Try different positions in old content
            for oldStart in 0...(oldLines.count - overlapLength) {
                let oldSlice = Array(oldLines[oldStart..<(oldStart + overlapLength)])

                // Try to find this slice in new content
                for newStart in 0...(newLines.count - overlapLength) {
                    let newSlice = Array(newLines[newStart..<(newStart + overlapLength)])

                    if oldSlice == newSlice {
                        // Found a match - prefer longer overlaps and earlier positions
                        if bestOverlap == nil || overlapLength > bestOverlap!.length {
                            bestOverlap = (start: newStart, length: overlapLength)
                        }
                    }
                }
            }

            // If we found a good overlap, use it
            if bestOverlap != nil && bestOverlap!.length >= overlapLength {
                break
            }
        }

        return bestOverlap
    }

    /// Detect meaningful in-place changes (avoiding noise)
    private func detectMeaningfulInPlaceChanges(oldLines: [String], newLines: [String]) -> String {
        var meaningfulChanges: [String] = []

        for (index, (oldLine, newLine)) in zip(oldLines, newLines).enumerated() {
            if oldLine != newLine {
                // Check if this change looks meaningful
                if isMeaningfulLineChange(from: oldLine, to: newLine) {
                    meaningfulChanges.append("Line \(index + 1): \(newLine)")
                }
            }
        }

        if !meaningfulChanges.isEmpty {
            return "\n[Content Updated]\n" + meaningfulChanges.joined(separator: "\n") + "\n"
        }

        return ""
    }

    /// Check if changes are just noise/animations that should be ignored
    private func hasOnlyNoiseChanges(oldLines: [String], newLines: [String]) -> Bool {
        for (oldLine, newLine) in zip(oldLines, newLines) {
            if oldLine != newLine {
                if isMeaningfulLineChange(from: oldLine, to: newLine) {
                    return false // Found at least one meaningful change
                }
            }
        }
        return true // All changes are noise
    }

    /// Determine if a line change is meaningful or just noise
    private func isMeaningfulLineChange(from oldLine: String, to newLine: String) -> Bool {
        let oldTrimmed = oldLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ignore empty line changes
        if oldTrimmed.isEmpty && newTrimmed.isEmpty {
            return false
        }

        // Check for common noise patterns
        if isLikelyNoise(oldTrimmed) && isLikelyNoise(newTrimmed) {
            return false
        }

        // If one line is significantly longer than the other, it's probably meaningful
        let lengthDiff = abs(newTrimmed.count - oldTrimmed.count)
        if lengthDiff > 10 {
            return true
        }

        // Check for cursor/progress indicator patterns
        if isProgressIndicator(oldTrimmed) || isProgressIndicator(newTrimmed) {
            return false
        }

        // Default to meaningful if we can't classify it as noise
        return true
    }

    /// Check if a line looks like noise (animations, cursors, etc.)
    private func isLikelyNoise(_ line: String) -> Bool {
        // Empty or very short lines
        if line.count < 3 {
            return true
        }

        // Lines with only special characters (cursors, borders, etc.)
        let specialChars = CharacterSet(charactersIn: "|-+*/\\═║╠╣╦╩╬█▄▀▐▌▋▊▉░▒▓◄►▲▼◆◇○●◦·‧…⋮⋯⁞")
        if line.rangeOfCharacter(from: specialChars.inverted) == nil {
            return true
        }

        return false
    }

    /// Check if a line looks like a progress indicator
    private func isProgressIndicator(_ line: String) -> Bool {
        // Look for patterns like progress bars, percentages, etc.
        let progressPatterns = [
            "\\d+%",  // Percentages
            "\\[#+[\\s-]*\\]",  // Progress bars [###   ]
            "\\d+/\\d+",  // Fraction progress
            "[▓▒░]+",  // Block progress bars
            "\\.\\.\\.*",  // Loading dots
            "Loading|loading",
            "Processing|processing",
            "\\|\\-\\\\\\/"  // Spinner characters
        ]

        for pattern in progressPatterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
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