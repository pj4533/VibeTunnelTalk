import Foundation
import OSLog

/// Accumulates terminal output from complete asciinema stream
/// Simpler than BufferAccumulator since we have 100% complete data
class StreamingAccumulator {
    private let logger = AppLogger.accumulator

    // Configuration
    let sizeThreshold: Int         // Characters to accumulate before sending
    let timeThreshold: TimeInterval // Seconds to wait before sending accumulated data

    // Content tracking
    private var pendingContent = ""     // Content waiting to be sent
    private var firstAccumulationTime: Date?
    private var accumulationTimer: Timer?

    // Callback
    private let onThresholdReached: (String, Int) -> Void

    init(sizeThreshold: Int = 100,
         timeThreshold: TimeInterval = 1.0,  // Faster response time
         onThresholdReached: @escaping (String, Int) -> Void) {
        self.sizeThreshold = sizeThreshold
        self.timeThreshold = timeThreshold
        self.onThresholdReached = onThresholdReached
    }

    /// Accumulate new terminal output
    func accumulate(_ newContent: String) {
        guard !newContent.isEmpty else { return }

        // Add to pending content
        self.pendingContent += newContent

        // Start timer if this is first accumulation
        if firstAccumulationTime == nil {
            firstAccumulationTime = Date()
        }

        logger.debug("Accumulated \(newContent.count) chars, total pending: \(self.pendingContent.count)")

        // Check thresholds
        checkThresholds()
    }

    private func checkThresholds() {
        guard !pendingContent.isEmpty else { return }

        var shouldFlush = false
        var reason = ""

        // Check size threshold
        if pendingContent.count >= sizeThreshold {
            shouldFlush = true
            reason = "size threshold (\(pendingContent.count) >= \(sizeThreshold))"
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
            // Start timer if needed
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard !pendingContent.isEmpty && accumulationTimer == nil else { return }

        accumulationTimer?.invalidate()
        accumulationTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func timerFired() {
        if !self.pendingContent.isEmpty {
            logger.info("⏰ Timer expired, flushing \(self.pendingContent.count) chars")
            self.flush()
        }
    }

    private func flush() {
        guard !pendingContent.isEmpty else { return }

        let content = pendingContent
        let charCount = content.count

        logger.info("📤 Sending \(charCount) chars to OpenAI")

        // Send the content
        onThresholdReached(content, charCount)

        // Reset state
        pendingContent = ""
        firstAccumulationTime = nil
        accumulationTimer?.invalidate()
        accumulationTimer = nil
    }

    /// Force flush any pending data
    func forceFlush() {
        if !self.pendingContent.isEmpty {
            logger.info("🔄 Force flushing \(self.pendingContent.count) chars")
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

        // Reset state
        pendingContent = ""
        firstAccumulationTime = nil
    }

    deinit {
        stop()
    }
}