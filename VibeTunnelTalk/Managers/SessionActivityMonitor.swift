import Foundation
import Combine
import OSLog

/// Monitors terminal output and sends meaningful chunks to OpenAI for intelligent narration
class SessionActivityMonitor: ObservableObject {
    private let logger = AppLogger.activityMonitor

    @Published var lastNarration: String = ""
    @Published var isProcessing: Bool = false

    // Buffer management
    private var outputBuffer = ""
    private var lastChunkSentTime = Date()

    // State tracking for smart chunking
    private var isInToolOutput = false
    private var toolDepth = 0
    private var consecutiveEmptyLines = 0
    private var lastWasPrompt = false
    private var hasSignificantContent = false

    // Minimum time between chunks to avoid spamming
    private let minTimeBetweenChunks: TimeInterval = 3.0

    /// Process new terminal output
    func processOutput(_ text: String) {
        outputBuffer += text

        // Track if we have meaningful content (not just system messages)
        if containsSignificantContent(text) {
            hasSignificantContent = true
        }

        // Detect if this is a good breakpoint
        if shouldSendChunk(for: text) {
            sendChunk()
        }
    }

    // MARK: - Private Methods

    /// Determine if text contains significant user/Claude content
    private func containsSignificantContent(_ text: String) -> Bool {
        let lowercased = text.lowercased()

        // Skip system/permission messages
        if lowercased.contains("permission") ||
           lowercased.contains("sandbox") ||
           lowercased.contains("system-reminder") ||
           lowercased.contains("environment variable") ||
           lowercased.contains("working directory:") {
            return false
        }

        // Look for actual content indicators
        if text.contains("user:") ||
           text.contains("assistant:") ||
           text.contains("Human:") ||
           text.contains("Claude:") ||
           lowercased.contains("i'll") ||
           lowercased.contains("let me") ||
           lowercased.contains("i found") ||
           lowercased.contains("here's") ||
           lowercased.contains("this is") {
            return true
        }

        // Tool usage is significant
        if text.contains("<function_calls>") ||
           text.contains("Tool:") ||
           text.contains("```") {
            return true
        }

        return false
    }

    /// Detect natural breakpoints for intelligent chunking
    private func shouldSendChunk(for text: String) -> Bool {
        // Don't send if buffer is too small or no significant content
        guard outputBuffer.count > 50 && hasSignificantContent else {
            return false
        }

        // Don't send too frequently
        let timeSinceLastChunk = Date().timeIntervalSince(lastChunkSentTime)
        guard timeSinceLastChunk >= minTimeBetweenChunks else {
            return false
        }

        // Track empty lines for section breaks
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consecutiveEmptyLines += 1
            if consecutiveEmptyLines >= 2 {
                return true  // Multiple empty lines indicate section break
            }
        } else {
            consecutiveEmptyLines = 0
        }

        // User input is a natural breakpoint
        if text.contains("user:") || text.contains("Human:") {
            return true
        }

        // Assistant starting response
        if text.contains("assistant:") || text.contains("Claude:") {
            return false  // Wait for the full response
        }

        // Tool invocation boundaries
        if text.contains("<function_calls>") {
            toolDepth += 1
            isInToolOutput = true
            return false  // Wait for completion
        }

        if text.contains("</function_calls>") || text.contains("</function_results>") {
            toolDepth = max(0, toolDepth - 1)
            if toolDepth == 0 {
                isInToolOutput = false
                return true  // End of tool usage is a good breakpoint
            }
        }

        // Command completion indicators
        if text.contains("✓") || text.contains("✔") ||
           text.contains("BUILD SUCCEEDED") || text.contains("BUILD FAILED") ||
           text.contains("Test Passed") || text.contains("Test Failed") {
            return true
        }

        // Error blocks are important breakpoints
        if text.contains("Error:") || text.contains("error:") ||
           text.contains("Failed:") || text.contains("failed:") {
            return true
        }

        // File operation completions
        if text.contains("File saved") || text.contains("File created") ||
           text.contains("File deleted") || text.contains("Changes applied") {
            return true
        }

        // Command prompt (terminal ready for input)
        if text.contains("$") && text.count < 100 {
            lastWasPrompt = true
            return true
        }

        // Don't send while in tool output unless it gets too large
        if isInToolOutput && outputBuffer.count < 3000 {
            return false
        }

        // Send if buffer is getting large
        if outputBuffer.count > 2500 {
            return true
        }

        return false
    }

    /// Send accumulated output to OpenAI for narration
    private func sendChunk() {
        // Don't send empty or insignificant chunks
        let trimmedBuffer = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBuffer.isEmpty && hasSignificantContent else {
            outputBuffer = ""
            hasSignificantContent = false
            return
        }

        // Prepare and send the chunk
        let chunk = outputBuffer
        outputBuffer = ""
        hasSignificantContent = false
        lastChunkSentTime = Date()
        isProcessing = true

        logger.info("[ACTIVITY] 📤 Sending meaningful chunk for narration: \(chunk.count) chars")

        // Create focused prompt for OpenAI
        let contextualizedChunk = prepareChunkForNarration(chunk)

        // Post notification with the prepared chunk
        NotificationCenter.default.post(
            name: .terminalChunkReady,
            object: nil,
            userInfo: ["chunk": contextualizedChunk]
        )

        isProcessing = false
    }

    /// Prepare chunk with focused context for OpenAI
    private func prepareChunkForNarration(_ chunk: String) -> String {
        // Filter out system messages and focus on conversation
        let lines = chunk.components(separatedBy: .newlines)
        var filteredLines: [String] = []
        var inSystemMessage = false

        for line in lines {
            // Skip system reminders and environment info
            if line.contains("<system-reminder>") || line.contains("<env>") {
                inSystemMessage = true
                continue
            }
            if line.contains("</system-reminder>") || line.contains("</env>") {
                inSystemMessage = false
                continue
            }
            if inSystemMessage {
                continue
            }

            // Skip permission and sandbox messages
            let lowercased = line.lowercased()
            if lowercased.contains("permission") ||
               lowercased.contains("sandbox") ||
               lowercased.contains("environment variable") {
                continue
            }

            filteredLines.append(line)
        }

        let filteredContent = filteredLines.joined(separator: "\n")

        return """
        Terminal output from Claude Code session:

        ```
        \(filteredContent)
        ```

        Provide a brief, natural narration (1-2 sentences) focusing ONLY on:
        - What the user asked Claude to do
        - What Claude is currently working on or just completed
        - Any important results, errors, or milestones

        DO NOT mention:
        - System settings, permissions, or sandboxing
        - File paths unless they're central to what's being done
        - Technical implementation details unless they're the main focus
        - Tool names or function calls

        Speak conversationally, as if explaining to someone what's happening in the session.
        Focus on the WHAT and WHY, not the HOW.
        """
    }

    /// Reset the monitor state
    func reset() {
        outputBuffer = ""
        lastChunkSentTime = Date()
        isProcessing = false
        lastNarration = ""
        hasSignificantContent = false
        isInToolOutput = false
        toolDepth = 0
        consecutiveEmptyLines = 0
        lastWasPrompt = false
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let terminalChunkReady = Notification.Name("terminalChunkReady")
}