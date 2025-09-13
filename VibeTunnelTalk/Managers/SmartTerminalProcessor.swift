import Foundation
import Combine
import OSLog

/// Processes terminal output intelligently by maintaining a buffer and sending only changes to OpenAI
class SmartTerminalProcessor: ObservableObject {
    private let logger = AppLogger.terminalProcessor

    // Dependencies
    private let bufferManager: TerminalBufferManager
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
    private var debugFileHandle: FileHandle?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.bufferManager = TerminalBufferManager(cols: 120, rows: 40) // Default size, will resize
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
                self.logger.debug("[PROCESSOR] Received event from SSE")
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

    // MARK: - Event Processing

    /// Process an asciinema event
    private func processAsciinemaEvent(_ event: AsciinemaEvent) {
        totalEventsProcessed += 1

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        logger.debug("[PROCESSOR @ \(timestamp)] Processing event type: \(event.type.rawValue), data length: \(event.data.count)")

        switch event.type {
        case .output:
            // Feed output to buffer manager
            bufferManager.processOutput(event.data)
            logger.debug("[PROCESSOR @ \(timestamp)] Fed \(event.data.count) chars to buffer")

        case .resize:
            // Parse resize dimensions (format: "120x40")
            let parts = event.data.split(separator: "x")
            if parts.count == 2,
               let cols = Int(parts[0]),
               let rows = Int(parts[1]) {
                logger.debug("[PROCESSOR] Terminal resized to \(cols)x\(rows)")
                bufferManager.resize(cols: cols, rows: rows)
            }

        case .input:
            // User typed something - might be useful context
            logger.debug("[PROCESSOR] User input detected")

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
                    // Check if OpenAI is ready to receive
                    // We need to check this synchronously to avoid race conditions
                    var isOpenAIBusy = false
                    DispatchQueue.main.sync {
                        isOpenAIBusy = self.openAIManager.isResponseInProgress
                    }

                    if !isOpenAIBusy {
                        self.logger.info("[SAMPLE @ \(timestamp)] Sending update: \(diff.count) chars changed")
                        self.sendUpdateToOpenAI(diff: diff, fullContent: currentContent)
                        self.lastSentContent = currentContent
                    } else {
                        self.logger.info("[SAMPLE @ \(timestamp)] OpenAI busy, accumulating \(diff.count) chars of changes")
                        // Don't update lastSentContent - we'll send accumulated changes when OpenAI is ready
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

    // MARK: - Debug Logging

    private func createDebugFile() {
        // Create filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "openai_updates_\(timestamp).txt"

        // Create logs directory in Library/Logs/VibeTunnelTalk
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibeTunnelTalk")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let filePath = logsDir.appendingPathComponent(filename)

        // Create the file
        FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)

        // Open file handle for writing
        debugFileHandle = try? FileHandle(forWritingTo: filePath)

        // Write header
        let header = """
        ========================================
        VibeTunnelTalk - OpenAI Updates Log
        Started: \(Date())
        ========================================

        """

        if let data = header.data(using: .utf8) {
            debugFileHandle?.write(data)
        }

        logger.info("[DEBUG] Created OpenAI updates log file at: \(filePath.path)")
    }

    private func writeToDebugFile(_ content: String) {
        guard let debugFileHandle = debugFileHandle else { return }

        // Create detailed timestamp with milliseconds
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        let entry = """

        [\(timestamp)] - Update #\(totalUpdatesSent)
        ----------------------------------------
        Data reduction: \(String(format: "%.1f%%", dataReductionRatio * 100))
        Characters sent: \(content.count)
        ----------------------------------------
        \(content)
        ========================================

        """

        if let data = entry.data(using: .utf8) {
            debugFileHandle.write(data)
        }
    }
}