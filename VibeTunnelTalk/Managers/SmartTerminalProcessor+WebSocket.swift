import Foundation
import Combine
import OSLog

// MARK: - WebSocket Integration

extension SmartTerminalProcessor {

    /// Inner class to handle accumulation of buffer updates
    class BufferAccumulator {
        private let logger = AppLogger.terminalProcessor

        // Configuration
        let sizeThreshold: Int         // Characters to accumulate before sending
        let timeThreshold: TimeInterval // Seconds to wait before sending accumulated data

        // State
        private var accumulatedContent = ""
        private var lastSendTime = Date()
        private var accumulationTimer: Timer?
        private var pendingSnapshots: [BufferSnapshot] = []

        // Callback
        private let onThresholdReached: (String, Int) -> Void

        init(sizeThreshold: Int = 500,
             timeThreshold: TimeInterval = 2.0,
             onThresholdReached: @escaping (String, Int) -> Void) {
            self.sizeThreshold = sizeThreshold
            self.timeThreshold = timeThreshold
            self.onThresholdReached = onThresholdReached
        }

        /// Add a buffer snapshot to the accumulator
        func accumulate(_ snapshot: BufferSnapshot, extractedContent: String, changeCount: Int) {
            logger.debug("[ACCUMULATOR] Accumulating \(changeCount) chars of changes")

            // Add to pending snapshots
            pendingSnapshots.append(snapshot)

            // Track the accumulated content changes
            accumulatedContent = extractedContent

            // Check size threshold
            if changeCount >= sizeThreshold {
                logger.info("[ACCUMULATOR] Size threshold reached: \(changeCount) >= \(self.sizeThreshold)")
                flush()
                return
            }

            // Start or reset timer for time threshold
            resetTimer()
        }

        /// Flush accumulated data
        private func flush() {
            guard !accumulatedContent.isEmpty else {
                logger.debug("[ACCUMULATOR] Nothing to flush")
                return
            }

            logger.info("[ACCUMULATOR] Flushing \(self.accumulatedContent.count) chars")

            // Calculate total change count
            let totalChangeCount = accumulatedContent.count

            // Send accumulated content
            onThresholdReached(accumulatedContent, totalChangeCount)

            // Reset state
            accumulatedContent = ""
            pendingSnapshots.removeAll()
            lastSendTime = Date()

            // Cancel timer
            accumulationTimer?.invalidate()
            accumulationTimer = nil
        }

        /// Reset the accumulation timer
        private func resetTimer() {
            // Cancel existing timer
            accumulationTimer?.invalidate()

            // Create new timer
            accumulationTimer = Timer.scheduledTimer(withTimeInterval: timeThreshold, repeats: false) { [weak self] _ in
                self?.handleTimerFired()
            }
        }

        /// Handle timer expiration
        private func handleTimerFired() {
            logger.info("[ACCUMULATOR] Time threshold reached: \(self.timeThreshold) seconds")
            flush()
        }

        /// Stop accumulation and cleanup
        func stop() {
            accumulationTimer?.invalidate()
            accumulationTimer = nil
            pendingSnapshots.removeAll()
            accumulatedContent = ""
        }

        deinit {
            stop()
        }
    }

    // MARK: - WebSocket Methods

    /// Start processing with WebSocket client instead of polling
    func startProcessingWithWebSocket(webSocketClient: VibeTunnelWebSocketClient, sessionId: String) async {
        logger.info("[PROCESSOR] startProcessingWithWebSocket called for session: \(sessionId)")

        // Create debug file for this session
        createDebugFile()
        logger.info("[PROCESSOR] Debug file created")

        // Create accumulator with thresholds
        let accumulator = BufferAccumulator(
            sizeThreshold: 500,    // Send when 500+ chars accumulate
            timeThreshold: 2.0      // Send after 2 seconds of inactivity
        ) { [weak self] content, changeCount in
            self?.sendUpdateToOpenAI(content, changeCount: changeCount)
            self?.lastSentContent = content
        }

        logger.info("[PROCESSOR] Subscribing to WebSocket updates for session: \(sessionId)")

        // Subscribe to WebSocket buffer updates
        await webSocketClient.subscribe(to: sessionId) { [weak self] snapshot in
            guard let self = self else {
                AppLogger.terminalProcessor.warning("[PROCESSOR] Received snapshot but self is nil")
                return
            }

            AppLogger.terminalProcessor.info("[PROCESSOR] Received buffer snapshot from WebSocket")

            Task { @MainActor in
                self.processWebSocketSnapshot(snapshot, accumulator: accumulator)
            }
        }

        logger.info("[PROCESSOR] WebSocket subscription completed")
        isProcessing = true
        logger.info("[PROCESSOR] Processing started (isProcessing = true)")

        // Store accumulator reference
        self.currentAccumulator = accumulator
    }

    /// Process a snapshot received via WebSocket
    @MainActor
    private func processWebSocketSnapshot(_ snapshot: BufferSnapshot, accumulator: BufferAccumulator) {
        totalSnapshotsProcessed += 1

        logger.debug("[PROCESSOR] Processing WebSocket snapshot #\(self.totalSnapshotsProcessed)")

        // Extract text content from buffer
        let currentContent = extractTextFromBuffer(snapshot)
        logger.debug("[PROCESSOR] Extracted \(currentContent.count) characters from buffer")

        // Check if content has changed significantly
        let changeCount = countChanges(from: lastSentContent, to: currentContent)

        // Log periodically to track processing
        if totalSnapshotsProcessed % 10 == 0 {
            logger.debug("[PROCESSOR] WebSocket snapshot #\(self.totalSnapshotsProcessed): \(changeCount) chars changed")
        }

        // Use accumulator to handle the update intelligently
        if changeCount > 0 {
            accumulator.accumulate(snapshot, extractedContent: currentContent, changeCount: changeCount)
        }

        lastBufferSnapshot = snapshot
        lastUpdate = Date()
    }

    /// Stop WebSocket processing
    func stopWebSocketProcessing(webSocketClient: VibeTunnelWebSocketClient) async {
        logger.info("[PROCESSOR] stopWebSocketProcessing called")

        // Unsubscribe from WebSocket
        await webSocketClient.unsubscribe()

        // Stop accumulator
        currentAccumulator?.stop()
        currentAccumulator = nil

        // Cleanup debug file
        debugFileHandle?.closeFile()
        debugFileHandle = nil

        isProcessing = false
    }

    // Note: currentAccumulator is stored in the main class
}