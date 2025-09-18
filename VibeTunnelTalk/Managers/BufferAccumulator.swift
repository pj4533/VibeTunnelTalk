import Foundation
import OSLog

/// Accumulates terminal buffer updates from real-time WebSocket streaming
/// Simple approach: capture all unique content and send it to OpenAI without duplicates
class BufferAccumulator {
    private let logger = AppLogger.accumulator
    private var totalSnapshotsProcessed = 0

    // Configuration
    let sizeThreshold: Int         // Characters to accumulate before sending
    let timeThreshold: TimeInterval // Seconds to wait before sending accumulated data

    // Content tracking - SIMPLIFIED APPROACH
    // We maintain the complete session transcript and track what we've sent
    private var sessionTranscript = ""      // Everything we've seen in order
    private var lastSentIndex = 0           // Position in transcript we've sent up to
    private var lastSeenBuffer = ""         // The last buffer content we saw

    // Pending content for threshold checking
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
    /// SIMPLIFIED: Just capture what's new and add it to our transcript
    func accumulate(_ snapshot: BufferSnapshot, extractedContent: String, changeCount: Int) {
        totalSnapshotsProcessed += 1

        // If this is our first buffer, everything is new
        if lastSeenBuffer.isEmpty {
            if !extractedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.info("📝 First buffer: \(extractedContent.count) chars")
                sessionTranscript = extractedContent + "\n"
                pendingContentSize = extractedContent.count
                firstAccumulationTime = Date()
                lastSeenBuffer = extractedContent
                checkThresholds()
            }
            return
        }

        // Compare with last buffer to find what's truly new
        // Real-time streaming means we see everything as it scrolls through
        let newContent = findNewContent(from: lastSeenBuffer, to: extractedContent)

        if !newContent.isEmpty {
            logger.info("📝 Found \(newContent.count) chars of new content")

            // Add to transcript
            sessionTranscript += newContent

            // Track pending size
            let unsentSize = sessionTranscript.count - lastSentIndex
            pendingContentSize = unsentSize

            // Start timer if needed
            if firstAccumulationTime == nil {
                firstAccumulationTime = Date()
            }
        }

        // Update our last seen buffer
        lastSeenBuffer = extractedContent

        // Check thresholds
        checkThresholds()
    }

    /// Find truly new content by comparing buffers
    /// SIMPLE APPROACH: Look for lines that weren't in the previous buffer
    private func findNewContent(from oldBuffer: String, to newBuffer: String) -> String {
        let oldLines = Set(oldBuffer.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let newLines = newBuffer.components(separatedBy: .newlines)

        var newContent: [String] = []

        for line in newLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !oldLines.contains(line) {
                // This line wasn't in the old buffer - it's new content
                newContent.append(line)
            }
        }

        // If we found new content, return it
        if !newContent.isEmpty {
            return newContent.joined(separator: "\n") + "\n"
        }

        // Check for significant buffer changes that might indicate scrolling
        // If the buffers are very different, capture the current state
        let similarity = calculateSimilarity(oldBuffer, newBuffer)
        if similarity < 0.3 && !newBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("📋 Low similarity (\(Int(similarity * 100))%) - capturing current buffer")
            return "[Buffer Update]\n" + newBuffer + "\n"
        }

        return ""
    }

    /// Calculate similarity between two buffers (0.0 to 1.0)
    private func calculateSimilarity(_ buffer1: String, _ buffer2: String) -> Double {
        let lines1 = Set(buffer1.components(separatedBy: .newlines).filter { !$0.isEmpty })
        let lines2 = Set(buffer2.components(separatedBy: .newlines).filter { !$0.isEmpty })

        guard !lines1.isEmpty || !lines2.isEmpty else { return 1.0 }

        let intersection = lines1.intersection(lines2).count
        let union = lines1.union(lines2).count

        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    private func checkThresholds() {
        let unsentSize = sessionTranscript.count - lastSentIndex
        guard unsentSize > 0 else { return }

        var shouldFlush = false
        var reason = ""

        // Check size threshold
        if unsentSize >= sizeThreshold {
            shouldFlush = true
            reason = "size threshold (\(unsentSize) >= \(sizeThreshold))"
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
            // Start timer if we have unsent content
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        let unsentSize = sessionTranscript.count - lastSentIndex
        guard unsentSize > 0 && accumulationTimer == nil else { return }

        accumulationTimer?.invalidate()
        accumulationTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func timerFired() {
        let unsentSize = sessionTranscript.count - lastSentIndex
        if unsentSize > 0 {
            logger.info("⏰ Timer expired, flushing \(unsentSize) chars")
            flush()
        }
    }

    private func flush() {
        guard !sessionTranscript.isEmpty else { return }

        // Get unsent portion of transcript
        let transcriptLength = sessionTranscript.count
        guard lastSentIndex < transcriptLength else {
            resetPendingState()
            return
        }

        // Extract only what hasn't been sent yet
        let startIndex = sessionTranscript.index(sessionTranscript.startIndex, offsetBy: lastSentIndex)
        let unsentContent = String(sessionTranscript[startIndex...])

        logger.info("📤 Sending \(unsentContent.count) chars to OpenAI (position \(self.lastSentIndex) to \(transcriptLength))")

        // Send the unsent content
        onThresholdReached(unsentContent, unsentContent.count)

        // Update our sent position
        lastSentIndex = transcriptLength

        // Reset pending state
        resetPendingState()
    }

    private func resetPendingState() {
        pendingContentSize = 0
        firstAccumulationTime = nil
        accumulationTimer?.invalidate()
        accumulationTimer = nil
    }

    /// Force flush any pending data
    func forceFlush() {
        let unsentSize = sessionTranscript.count - lastSentIndex
        if unsentSize > 0 {
            logger.info("🔄 Force flushing \(unsentSize) chars")
            flush()
        }
    }

    /// Stop accumulation and cleanup
    func stop() {
        logger.info("⏹️ Stopping accumulator")

        // Flush any pending data
        forceFlush()

        // Clean up timer
        accumulationTimer?.invalidate()
        accumulationTimer = nil

        // Reset all state
        sessionTranscript = ""
        lastSentIndex = 0
        lastSeenBuffer = ""
        pendingContentSize = 0
        firstAccumulationTime = nil
    }

    deinit {
        stop()
    }
}