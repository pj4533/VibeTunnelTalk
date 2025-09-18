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
    private var currentActivity: ActivityType = .idle
    private var activityStartTime = Date()
    private var recentActivities: [String] = []
    private var lastSignificantUpdate = Date()

    // Activity tracking
    private enum ActivityType {
        case idle
        case thinking
        case task(name: String)
        case readingFiles
        case writingCode
        case runningCommand
        case analyzing
        case searching
    }

    // Minimum time between chunks to avoid spamming
    private let minTimeBetweenChunks: TimeInterval = 2.0
    private let significantUpdateInterval: TimeInterval = 5.0

    /// Process new terminal output
    func processOutput(_ text: String) {
        outputBuffer += text

        // Update activity type based on patterns
        detectActivityChange(in: text)

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

    /// Detect activity changes from Claude's output patterns
    private func detectActivityChange(in text: String) {
        let lowercased = text.lowercased()
        let previousActivity = currentActivity

        // Detect Task starts (e.g., "Task(Analyze project structure)")
        if text.contains("Task(") {
            if let taskName = extractTaskName(from: text) {
                currentActivity = .task(name: taskName)
                activityStartTime = Date()
                logger.info("[ACTIVITY] 🎯 Task started: \(taskName)")
            }
        }
        // Detect thinking/planning statements
        else if lowercased.contains("i'll analyze") ||
                lowercased.contains("let me analyze") ||
                lowercased.contains("i'll examine") ||
                lowercased.contains("let me look") ||
                lowercased.contains("i'll check") ||
                lowercased.contains("let me check") {
            currentActivity = .analyzing
            activityStartTime = Date()
        }
        // Detect file operations
        else if text.contains("Read(") ||
                text.contains("Reading file") ||
                text.contains("cat -n") ||
                lowercased.contains("reading") {
            currentActivity = .readingFiles
            activityStartTime = Date()
        }
        // Detect code writing
        else if text.contains("Edit(") ||
                text.contains("Write(") ||
                text.contains("MultiEdit(") ||
                lowercased.contains("modifying") ||
                lowercased.contains("updating") ||
                lowercased.contains("creating") {
            currentActivity = .writingCode
            activityStartTime = Date()
        }
        // Detect command execution
        else if text.contains("Bash(") ||
                text.contains("Running:") ||
                text.contains("Executing:") ||
                text.contains("$") && text.count < 200 {
            currentActivity = .runningCommand
            activityStartTime = Date()
        }
        // Detect searching
        else if text.contains("Grep(") ||
                text.contains("Glob(") ||
                text.contains("WebSearch(") ||
                lowercased.contains("searching") ||
                lowercased.contains("looking for") {
            currentActivity = .searching
            activityStartTime = Date()
        }
        // Detect completion
        else if text.contains("Done (") ||
                text.contains("✓") ||
                text.contains("completed") ||
                text.contains("finished") {
            // Activity completed - trigger update
            if case .task(let name) = currentActivity {
                recentActivities.append("Completed: \(name)")
            }
            currentActivity = .idle
        }

        // If activity changed, mark as significant
        if !areActivitiesEqual(previousActivity, currentActivity) {
            lastSignificantUpdate = Date()
            hasSignificantContent = true
        }
    }

    /// Extract task name from Task(...) pattern
    private func extractTaskName(from text: String) -> String? {
        if let range = text.range(of: "Task\\(([^)]+)\\)", options: .regularExpression) {
            let taskText = String(text[range])
            let name = taskText
                .replacingOccurrences(of: "Task(", with: "")
                .replacingOccurrences(of: ")", with: "")
            return name
        }
        return nil
    }

    /// Compare activity types
    private func areActivitiesEqual(_ lhs: ActivityType, _ rhs: ActivityType) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.thinking, .thinking),
             (.readingFiles, .readingFiles), (.writingCode, .writingCode),
             (.runningCommand, .runningCommand), (.analyzing, .analyzing),
             (.searching, .searching):
            return true
        case (.task(let name1), .task(let name2)):
            return name1 == name2
        default:
            return false
        }
    }

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
        guard outputBuffer.count > 30 && hasSignificantContent else {
            return false
        }

        let timeSinceLastChunk = Date().timeIntervalSince(lastChunkSentTime)
        let timeSinceSignificantUpdate = Date().timeIntervalSince(lastSignificantUpdate)

        // PRIORITY 1: Activity changes should trigger immediate updates
        if timeSinceSignificantUpdate < 0.5 && timeSinceLastChunk >= 1.5 {
            // Activity just changed, send an update
            return true
        }

        // PRIORITY 2: Task starts always trigger narration
        if text.contains("Task(") && timeSinceLastChunk >= 1.0 {
            return true
        }

        // PRIORITY 3: Important Claude statements
        let lowercased = text.lowercased()
        if (lowercased.contains("i'll") ||
            lowercased.contains("let me") ||
            lowercased.contains("i'm going to") ||
            lowercased.contains("i found") ||
            lowercased.contains("i've")) &&
           timeSinceLastChunk >= minTimeBetweenChunks {
            return true
        }

        // Don't send too frequently for non-priority updates
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
        if text.contains("user:") || text.contains("Human:") || text.contains(">") {
            return true
        }

        // Tool operation results
        if text.contains("Done (") && text.contains("tokens") {
            return true  // Task completion
        }

        // File modifications
        if text.contains("has been updated") ||
           text.contains("has been created") ||
           text.contains("File saved") {
            return true
        }

        // Tool invocation boundaries
        if text.contains("<function_calls>") {
            toolDepth += 1
            isInToolOutput = true
            // Send update about starting a tool operation
            if timeSinceLastChunk >= 2.0 {
                return true
            }
            return false
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

        // Send periodic updates during long activities
        if !areActivitiesEqual(currentActivity, .idle) && timeSinceLastChunk >= significantUpdateInterval {
            return true
        }

        // Don't send while in tool output unless it gets too large or timeout
        if isInToolOutput {
            if outputBuffer.count > 2000 || timeSinceLastChunk > 8.0 {
                return true
            }
            return false
        }

        // Send if buffer is getting large
        if outputBuffer.count > 1500 {
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

        // Create activity context
        var activityContext = ""
        switch currentActivity {
        case .task(let name):
            activityContext = "Working on: \(name)"
        case .analyzing:
            activityContext = "Analyzing the codebase"
        case .readingFiles:
            activityContext = "Reading files"
        case .writingCode:
            activityContext = "Modifying code"
        case .runningCommand:
            activityContext = "Running a command"
        case .searching:
            activityContext = "Searching"
        case .thinking:
            activityContext = "Planning approach"
        case .idle:
            activityContext = ""
        }

        return """
        Terminal output:
        \(activityContext.isEmpty ? "" : "\(activityContext)\n")
        ```
        \(filteredContent)
        ```

        ALWAYS use "we". NEVER say "Claude", "the system", "the terminal", etc.

        CRITICAL: Determine if this is an INTERIM update or a FINAL result:

        INTERIM updates (activity in progress):
        - Be EXTREMELY brief: 3-5 words maximum
        - State ONLY the action: "Reading the file", "Running tests", "Searching for matches"
        - NO explanations, NO details, NO context
        - Examples: "Checking the code", "Building now", "Looking at files"

        FINAL results (command completed, errors found, results available):
        - Provide detailed summary of WHAT happened:
          * For errors: Describe the specific errors
          * For search results: Describe what was found
          * For test results: State pass/fail counts
          * For answers: State the actual answer
          * For command output: Describe key results

        If you see "Task(", "Reading", "Running:", "Searching" → INTERIM (be ultra-brief)
        If you see "Done", errors, results, answers, completion → FINAL (be detailed)
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
        currentActivity = .idle
        activityStartTime = Date()
        recentActivities = []
        lastSignificantUpdate = Date()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let terminalChunkReady = Notification.Name("terminalChunkReady")
}