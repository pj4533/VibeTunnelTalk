import Foundation
import Combine
import OSLog

/// Monitors terminal output and generates intelligent summaries for narration
class SessionActivityMonitor: ObservableObject {
    private let logger = AppLogger.activityMonitor
    
    @Published var currentActivity: ActivityState = .idle
    @Published var lastNarration: String = ""
    
    private var outputBuffer = ""
    private var lastActivityTime = Date()
    private var fileOperations: [FileOperation] = []
    private var currentCommand: String?
    private var errorCount = 0
    
    // Patterns for detecting Claude activities
    private let patterns = ActivityPatterns()
    
    // Debounce timer for narration
    private var narrationTimer: Timer?
    private let narrationDebounceInterval: TimeInterval = 2.0
    
    /// Process new terminal output
    func processOutput(_ text: String) {
        outputBuffer += text
        lastActivityTime = Date()

        // Log significant output (not every character)
        if text.count > 10 {
            logger.info("[ACTIVITY] 📥 Received \(text.count) chars from VibeTunnel")
        }

        // Detect activity type
        let detectedActivity = detectActivity(from: text)
        if detectedActivity != currentActivity {
            logger.info("[ACTIVITY] 🔄 Activity changed: \(String(describing: self.currentActivity)) → \(String(describing: detectedActivity))")
            currentActivity = detectedActivity
            scheduleNarration()
        }
        
        // Track file operations
        trackFileOperations(from: text)
        
        // Track errors
        trackErrors(from: text)
        
        // Limit buffer size
        if outputBuffer.count > 10000 {
            outputBuffer = String(outputBuffer.suffix(5000))
        }
    }
    
    /// Generate narration based on current activity
    func generateNarration() -> String {
        switch currentActivity {
        case .thinking:
            return generateThinkingNarration()
        case .writing:
            return generateWritingNarration()
        case .reading:
            return generateReadingNarration()
        case .executing:
            return generateExecutingNarration()
        case .debugging:
            return generateDebuggingNarration()
        case .idle:
            return "Claude is idle"
        }
    }
    
    // MARK: - Private Methods
    
    private func detectActivity(from text: String) -> ActivityState {
        let lowercased = text.lowercased()
        
        // Check for specific Claude states
        if patterns.thinkingPatterns.contains(where: { lowercased.contains($0) }) {
            return .thinking
        }
        
        if patterns.writingPatterns.contains(where: { lowercased.contains($0) }) {
            return .writing
        }
        
        if patterns.readingPatterns.contains(where: { lowercased.contains($0) }) {
            return .reading
        }
        
        if patterns.executingPatterns.contains(where: { lowercased.contains($0) }) {
            return .executing
        }
        
        if patterns.debuggingPatterns.contains(where: { lowercased.contains($0) }) {
            return .debugging
        }
        
        // Check for file operations
        if text.contains("Creating") || text.contains("Writing") || text.contains("Updating") {
            return .writing
        }
        
        if text.contains("Reading") || text.contains("Analyzing") || text.contains("Examining") {
            return .reading
        }
        
        if text.contains("Running") || text.contains("Executing") || text.contains("npm") || text.contains("pnpm") {
            return .executing
        }
        
        if text.contains("error") || text.contains("Error") || text.contains("failed") {
            return .debugging
        }
        
        return .idle
    }
    
    private func trackFileOperations(from text: String) {
        // Extract file paths being modified
        let filePathPattern = #"(?:\/[\w\-\.]+)+\.[\w]+"#
        if let regex = try? NSRegularExpression(pattern: filePathPattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let filePath = String(text[range])
                    
                    // Determine operation type
                    let operation: FileOperation.OperationType
                    if text.contains("Creating") || text.contains("Writing") {
                        operation = .write
                    } else if text.contains("Reading") {
                        operation = .read
                    } else if text.contains("Deleting") || text.contains("Removing") {
                        operation = .delete
                    } else {
                        operation = .modify
                    }
                    
                    fileOperations.append(FileOperation(
                        path: filePath,
                        operation: operation,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        // Keep only recent operations
        let cutoff = Date().addingTimeInterval(-30)
        fileOperations = fileOperations.filter { $0.timestamp > cutoff }
    }
    
    private func trackErrors(from text: String) {
        let errorKeywords = ["error", "Error", "ERROR", "failed", "Failed", "exception", "Exception"]
        
        for keyword in errorKeywords {
            if text.contains(keyword) {
                errorCount += 1
                break
            }
        }
    }
    
    private func scheduleNarration() {
        narrationTimer?.invalidate()
        narrationTimer = Timer.scheduledTimer(withTimeInterval: narrationDebounceInterval, repeats: false) { [weak self] _ in
            self?.performNarration()
        }
    }
    
    private func performNarration() {
        let narration = generateNarration()
        if narration != lastNarration {
            lastNarration = narration
            logger.info("[ACTIVITY] 🎯 Generated narration: \(narration)")

            // This will be sent to OpenAI for voice synthesis
            NotificationCenter.default.post(
                name: .activityNarrationReady,
                object: nil,
                userInfo: ["narration": narration]
            )
        }
    }
    
    private func generateThinkingNarration() -> String {
        let duration = Date().timeIntervalSince(lastActivityTime)
        if duration < 3 {
            return "Claude is thinking about your request"
        } else if duration < 10 {
            return "Claude is analyzing the codebase"
        } else {
            return "Claude is working on a complex solution"
        }
    }
    
    private func generateWritingNarration() -> String {
        guard !fileOperations.isEmpty else {
            return "Claude is writing code"
        }
        
        let recentWrites = fileOperations.filter { $0.operation == .write || $0.operation == .modify }
        
        if recentWrites.count == 1,
           let file = recentWrites.first {
            let filename = URL(fileURLWithPath: file.path).lastPathComponent
            return "Claude is modifying \(filename)"
        } else if recentWrites.count > 1 {
            return "Claude is updating \(recentWrites.count) files"
        }
        
        return "Claude is writing code"
    }
    
    private func generateReadingNarration() -> String {
        let recentReads = fileOperations.filter { $0.operation == .read }
        
        if recentReads.count == 1,
           let file = recentReads.first {
            let filename = URL(fileURLWithPath: file.path).lastPathComponent
            return "Claude is examining \(filename)"
        } else if recentReads.count > 1 {
            return "Claude is reviewing \(recentReads.count) files"
        }
        
        return "Claude is reading the codebase"
    }
    
    private func generateExecutingNarration() -> String {
        if let command = currentCommand {
            if command.contains("test") {
                return "Running tests"
            } else if command.contains("build") {
                return "Building the project"
            } else if command.contains("install") {
                return "Installing dependencies"
            } else {
                return "Executing \(command)"
            }
        }
        
        return "Running a command"
    }
    
    private func generateDebuggingNarration() -> String {
        if errorCount == 1 {
            return "Claude encountered an error and is fixing it"
        } else if errorCount > 1 {
            return "Claude is debugging \(errorCount) issues"
        }
        
        return "Claude is debugging"
    }
}

// MARK: - Supporting Types

enum ActivityState {
    case idle
    case thinking
    case writing
    case reading
    case executing
    case debugging
}

struct FileOperation {
    enum OperationType {
        case read, write, modify, delete
    }
    
    let path: String
    let operation: OperationType
    let timestamp: Date
}

struct ActivityPatterns {
    let thinkingPatterns = [
        "thinking",
        "analyzing",
        "considering",
        "evaluating",
        "planning"
    ]
    
    let writingPatterns = [
        "writing",
        "creating",
        "implementing",
        "adding",
        "modifying"
    ]
    
    let readingPatterns = [
        "reading",
        "examining",
        "reviewing",
        "searching",
        "looking"
    ]
    
    let executingPatterns = [
        "running",
        "executing",
        "starting",
        "launching",
        "building"
    ]
    
    let debuggingPatterns = [
        "debugging",
        "fixing",
        "resolving",
        "troubleshooting",
        "investigating"
    ]
}

// MARK: - Notifications

extension Notification.Name {
    static let activityNarrationReady = Notification.Name("activityNarrationReady")
}