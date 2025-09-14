import Foundation
import Combine
import OSLog

/// Processes terminal output intelligently by maintaining a buffer and sending only changes to OpenAI
class SmartTerminalProcessor: ObservableObject {
    let logger = AppLogger.terminalProcessor
    private let debouncedLogger: DebouncedLogger

    // Dependencies
    let bufferManager: TerminalBufferManager  // Made public for UI access
    private let openAIManager: OpenAIRealtimeManager

    // Configuration
    @Published var sampleInterval: TimeInterval = 1.0 // Sample buffer every second for responsiveness
    @Published var minChangeThreshold: Int = 5 // Lower threshold to catch small changes

    // State tracking
    @Published var isProcessing = false
    @Published var lastUpdate = Date()
    @Published var totalEventsProcessed = 0
    @Published var totalUpdatesSent = 0
    @Published var dataReductionRatio: Double = 0.0

    // For diffing
    private var lastSentContent = ""
    private var lastBufferSnapshot = ""

    // Timers and subscriptions
    private var sampleTimer: Timer?
    private var sseSubscription: AnyCancellable?
    private var eventQueue = DispatchQueue(label: "terminal.processor", qos: .userInitiated)

    // Debug file for OpenAI updates
    var debugFileHandle: FileHandle?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.bufferManager = TerminalBufferManager(cols: 120, rows: 40) // Default size, will resize
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.terminalProcessor)
        createDebugFile()
    }

    /// Start processing terminal events from SSE client
    func startProcessing(sseClient: VibeTunnelSSEClient) {
        logger.info("[PROCESSOR] Starting smart terminal processing")

        // Subscribe to asciinema events
        sseSubscription = sseClient.asciinemaEvent
            .receive(on: eventQueue)
            .sink { [weak self] event in
                guard let self = self else { return }
                // Don't log every single event, it's too noisy
                self.processAsciinemaEvent(event)
            }

        // Start sampling timer
        startSamplingTimer()

        isProcessing = true
    }

    /// Stop processing
    func stopProcessing() {
        logger.info("[PROCESSOR] Stopping smart terminal processing")

        sampleTimer?.invalidate()
        sampleTimer = nil
        sseSubscription?.cancel()
        sseSubscription = nil
        debugFileHandle?.closeFile()
        debugFileHandle = nil

        isProcessing = false
    }

    /// Cleanup resources
    func cleanup() {
        stopProcessing()
    }

    /// Get the current terminal buffer for display
    func getTerminalBuffer() -> (buffer: [[TerminalCell]], cursorRow: Int, cursorCol: Int, cols: Int, rows: Int) {
        let snapshot = bufferManager.getBufferSnapshot()
        return (snapshot.buffer, snapshot.cursorRow, snapshot.cursorCol, bufferManager.cols, bufferManager.rows)
    }

    /// Process terminal event from VibeTunnelSocketManager
    func processTerminalEvent(_ data: String) {
        // Parse the JSON array format [timestamp, "o", content]
        guard let jsonData = data.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              array.count >= 3,
              let timestamp = array[0] as? Double,
              let type = array[1] as? String,
              let content = array[2] as? String else {
            return
        }

        // Create AsciinemaEvent
        let event = AsciinemaEvent(
            timestamp: timestamp,
            type: AsciinemaEvent.EventType(rawValue: type) ?? .output,
            data: content
        )

        processAsciinemaEvent(event)
    }

    // MARK: - Event Processing

    /// Process an asciinema event
    private func processAsciinemaEvent(_ event: AsciinemaEvent) {
        totalEventsProcessed += 1

        switch event.type {
        case .output:
            // Log every 10th event to track if events are still flowing
            if totalEventsProcessed % 10 == 0 {
                logger.debug("[PROCESSOR] Event #\(self.totalEventsProcessed): Processing \(event.data.count) bytes")
            }

            // Feed output to buffer manager
            bufferManager.processOutput(event.data)
            // Use debounced logging for continuous data flow
            debouncedLogger.logDataFlow(key: "PROCESSOR", bytes: event.data.count, action: "Processing terminal output")

        case .resize:
            // Parse resize dimensions (format: "120x40")
            let parts = event.data.split(separator: "x")
            if parts.count == 2,
               let cols = Int(parts[0]),
               let rows = Int(parts[1]) {
                logger.info("[PROCESSOR] Terminal resized to \(cols)x\(rows)")
                bufferManager.resize(cols: cols, rows: rows)
            }

        case .input:
            // User typed something - use debounced logging to avoid spam
            debouncedLogger.logDebounced(key: "USER_INPUT",
                                        initialMessage: "User typing...",
                                        continuationMessage: "User finished typing")

        case .exit:
            logger.info("[PROCESSOR] Session exited")
            stopProcessing()
        }
    }

    // MARK: - Sampling and Diff Detection

    /// Start the sampling timer
    private func startSamplingTimer() {
        logger.info("[PROCESSOR] Starting sampling timer with interval: \(self.sampleInterval)s")
        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleBuffer()
        }
    }

    /// Sample the buffer and detect changes
    private func sampleBuffer() {
        eventQueue.async { [weak self] in
            guard let self = self else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())

            // Check if OpenAI is connected before sampling
            guard self.openAIManager.isConnected else {
                self.logger.debug("[SAMPLE @ \(timestamp)] OpenAI not connected, skipping sample")
                return
            }

            // Get current buffer state
            let currentContent = self.bufferManager.getBufferText()

            // Check if there are meaningful changes
            if currentContent != self.lastBufferSnapshot {
                self.logger.debug("[SAMPLE @ \(timestamp)] Buffer changed, analyzing...")
                self.lastBufferSnapshot = currentContent

                // Create a diff-based update comparing with what we last SENT (not what we last saw)
                let diff = self.createDiff(old: self.lastSentContent, new: currentContent)

                // Only send if the diff is significant
                if diff.count > self.minChangeThreshold {
                    // Capture values before async dispatch
                    let capturedDiff = diff
                    let capturedContent = currentContent
                    let capturedTimestamp = timestamp

                    // Check if OpenAI is ready to receive
                    // Use async dispatch to avoid deadlock
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        if !self.openAIManager.isResponseInProgress {
                            self.logger.info("[SAMPLE @ \(capturedTimestamp)] Sending update: \(capturedDiff.count) chars changed")

                            // Update lastSentContent back on eventQueue to maintain consistency
                            self.eventQueue.async { [weak self] in
                                self?.lastSentContent = capturedContent
                            }

                            self.sendUpdateToOpenAI(diff: capturedDiff, fullContent: capturedContent)
                        } else {
                            self.logger.info("[SAMPLE @ \(capturedTimestamp)] OpenAI busy, accumulating \(capturedDiff.count) chars of changes")
                            // Don't update lastSentContent - we'll send accumulated changes when OpenAI is ready
                        }
                    }
                } else if diff.count > 0 {
                    self.logger.debug("[SAMPLE @ \(timestamp)] Changes too small (\(diff.count) chars), buffering...")
                }
            } else {
                self.logger.debug("[SAMPLE @ \(timestamp)] No buffer changes detected")
            }
        }
    }

    /// Create a diff between old and new content
    private func createDiff(old: String, new: String) -> String {
        // Simple approach: if content is completely different, send the new content
        // Otherwise, try to find what changed

        if old.isEmpty {
            return new
        }

        // Split into lines for line-by-line comparison
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        var changes: [String] = []
        var hasChanges = false

        // Find changed lines
        for (index, newLine) in newLines.enumerated() {
            if index < oldLines.count {
                if oldLines[index] != newLine && !newLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    changes.append(newLine)
                    hasChanges = true
                }
            } else {
                // New line added
                if !newLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    changes.append(newLine)
                    hasChanges = true
                }
            }
        }

        // If we have changes, return them
        if hasChanges {
            return changes.joined(separator: "\n")
        }

        // No meaningful changes
        return ""
    }

    // MARK: - OpenAI Communication

    /// Send update to OpenAI
    private func sendUpdateToOpenAI(diff: String, fullContent: String) {
        totalUpdatesSent += 1
        lastUpdate = Date()

        // Calculate data reduction ratio
        let originalSize = bufferManager.totalBytesProcessed
        let sentSize = diff.utf8.count
        if originalSize > 0 {
            dataReductionRatio = 1.0 - (Double(sentSize) / Double(originalSize))
        }

        // Create the message for OpenAI
        let message = """
        Terminal Update:

        \(diff)
        """

        // Create timestamp for logging
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Log what we're sending with timestamp
        logger.info("[UPDATE @ \(timestamp)] Sending to OpenAI - Size: \(diff.count) chars, Reduction: \(String(format: "%.1f%%", self.dataReductionRatio * 100))")

        // Write to debug file
        writeToDebugFile(message)

        // Send to OpenAI
        DispatchQueue.main.async {
            self.openAIManager.sendTerminalContext(message)
        }
    }

}