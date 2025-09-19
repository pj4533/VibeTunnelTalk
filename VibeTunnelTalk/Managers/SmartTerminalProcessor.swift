import Foundation
import Combine
import OSLog

/// Processes terminal output from asciinema files and sends intelligent summaries to OpenAI
class SmartTerminalProcessor: ObservableObject {
    let logger = AppLogger.terminalProcessor
    private let debouncedLogger: DebouncedLogger
    private var statsLogger: BufferStatisticsLogger

    // Dependencies
    private let openAIManager: OpenAIRealtimeManager

    // State tracking
    @Published var isProcessing = false
    @Published var lastUpdate = Date()
    @Published var totalEventsProcessed = 0
    @Published var totalUpdatesSent = 0

    // For tracking what we've sent
    internal var lastSentContent = ""

    // Debug files for logging
    var debugFileHandle: FileHandle?

    // File reader and accumulator
    private var fileReader: AsciinemaFileReader?
    private var currentAccumulator: StreamingAccumulator?

    init(openAIManager: OpenAIRealtimeManager) {
        self.openAIManager = openAIManager
        self.debouncedLogger = DebouncedLogger(logger: AppLogger.terminalProcessor)
        self.statsLogger = BufferStatisticsLogger(logger: AppLogger.terminalProcessor)
    }

    /// Start processing terminal output from asciinema file
    func startProcessingWithFileReader(sessionId: String) async {
        logger.info("Starting smart terminal processor for session: \(sessionId)")

        // Create debug file for this session
        createDebugFile()
        logger.debug("Debug file created")

        // Create file reader
        let reader = AsciinemaFileReader()
        self.fileReader = reader

        // Create accumulator with intelligent thresholds
        let accumulator = StreamingAccumulator(
            sizeThreshold: 100,    // Send when 100+ chars accumulate
            timeThreshold: 1.0     // Send after 1 second of inactivity (faster)
        ) { [weak self] content, changeCount in
            guard let self = self else { return }

            // Update lastSentContent to track what we've sent
            self.lastSentContent = content

            // Send to OpenAI
            self.sendUpdateToOpenAI(content, changeCount: changeCount)
        }

        self.currentAccumulator = accumulator
        logger.debug("Created streaming accumulator (100 chars / 1.0s thresholds)")

        // Start reading asciinema file
        reader.startReading(sessionId: sessionId) { [weak self] newContent in
            guard let self = self else { return }

            // Process new terminal output
            self.processStreamingOutput(newContent)
        }

        logger.debug("File reader started")
        isProcessing = true
        logger.info("✅ Processing started with complete terminal stream")
    }

    /// Start processing buffer snapshots from WebSocket client (deprecated - kept for backwards compatibility)
    func startProcessingWithBufferClient(bufferClient: BufferWebSocketClient?, sessionId: String) async {
        // Redirect to file reader implementation
        await startProcessingWithFileReader(sessionId: sessionId)
    }

    /// Process new terminal output from asciinema stream
    private func processStreamingOutput(_ newContent: String) {
        totalEventsProcessed += 1

        // Write to debug file
        if let handle = debugFileHandle {
            let debugContent = "[Stream Event #\(totalEventsProcessed)]\n\(newContent)\n---\n"
            if let data = debugContent.data(using: .utf8) {
                handle.write(data)
            }
        }

        // Record statistics
        statsLogger.recordSnapshot(charsExtracted: newContent.count, charsChanged: newContent.count, sentToOpenAI: false)

        // Pass to accumulator - it will batch intelligently
        currentAccumulator?.accumulate(newContent)

        lastUpdate = Date()
    }

    /// Stop processing
    func stopProcessing() {
        logger.info("⏹️ Stopping smart terminal processing")
        statsLogger.forceLogSummary()

        // Stop file reader
        fileReader?.stopReading()
        fileReader = nil

        // Stop accumulator and flush any pending data
        currentAccumulator?.stop()
        currentAccumulator = nil

        debugFileHandle?.closeFile()
        debugFileHandle = nil

        isProcessing = false
    }

    /// Cleanup resources
    func cleanup() {
        stopProcessing()
    }

    // MARK: - Terminal Processing

    // MARK: - OpenAI Integration

    /// Send update to OpenAI
    internal func sendUpdateToOpenAI(_ content: String, changeCount: Int) {
        logger.debug("Sending \(changeCount) chars to OpenAI")

        guard !content.isEmpty else {
            logger.debug("Skipping empty content")
            return
        }

        // Log if OpenAI is speaking but still send the update
        // OpenAI can handle concurrent updates
        if openAIManager.isSpeaking {
            logger.verbose("OpenAI is speaking, sending update anyway")
        }

        totalUpdatesSent += 1

        // Update statistics
        statsLogger.recordSnapshot(charsExtracted: content.count, charsChanged: changeCount, sentToOpenAI: true)

        logger.info("📤 Update #\(self.totalUpdatesSent): \(changeCount) chars")

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