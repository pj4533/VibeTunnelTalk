import Foundation
import OSLog

/// Centralized logging system for VibeTunnelTalk
struct AppLogger {
    /// Main bundle identifier for the app
    private static let subsystem = "com.vibetunneltalk"

    /// Log level configuration for filtering
    enum LogLevel: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case fault = 4

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            case .fault: return .fault
            }
        }
    }

    /// Logging categories for different app components
    enum Category: String, CaseIterable {
        case socketManager = "SocketManager"
        case openAIRealtime = "OpenAIRealtime"
        case activityMonitor = "ActivityMonitor"
        case voiceCommands = "VoiceCommands"
        case keychain = "Keychain"
        case ui = "UI"
        case sessionDiscovery = "SessionDiscovery"
        case ipc = "IPC"
        case audio = "Audio"
        case network = "Network"
        case terminalBuffer = "TerminalBuffer"
        case terminalProcessor = "TerminalProcessor"
        case auth = "Authentication"
        case webSocket = "WebSocket"
        case accumulator = "Accumulator"

        var logger: Logger {
            Logger(subsystem: AppLogger.subsystem, category: self.rawValue)
        }

        /// Minimum log level for this category
        /// Set to .debug for development, increase for production
        var minimumLevel: LogLevel {
            switch self {
            case .webSocket, .terminalProcessor, .accumulator:
                // These tend to be very verbose, so default to info level
                return .info
            case .auth:
                // Auth logs can be repetitive
                return .info
            default:
                return .debug
            }
        }
    }

    // MARK: - Static Logger Instances

    /// Logger for VibeTunnel socket management
    static let socketManager = Category.socketManager.logger

    /// Logger for OpenAI Realtime API
    static let openAIRealtime = Category.openAIRealtime.logger

    /// Logger for session activity monitoring
    static let activityMonitor = Category.activityMonitor.logger

    /// Logger for voice command processing
    static let voiceCommands = Category.voiceCommands.logger

    /// Logger for Keychain operations
    static let keychain = Category.keychain.logger

    /// Logger for UI events
    static let ui = Category.ui.logger

    /// Logger for VibeTunnel session discovery
    static let sessionDiscovery = Category.sessionDiscovery.logger

    /// Logger for IPC protocol operations
    static let ipc = Category.ipc.logger

    /// Logger for audio operations
    static let audio = Category.audio.logger

    /// Logger for network operations
    static let network = Category.network.logger

    /// Logger for terminal buffer management
    static let terminalBuffer = Category.terminalBuffer.logger

    /// Logger for terminal processing
    static let terminalProcessor = Category.terminalProcessor.logger

    /// Logger for authentication
    static let auth = Category.auth.logger

    /// Logger for WebSocket operations
    static let webSocket = Category.webSocket.logger

    /// Logger for buffer accumulation
    static let accumulator = Category.accumulator.logger
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log with context information and level filtering
    func logWithLevel(_ level: AppLogger.LogLevel,
                     _ message: String,
                     file: String = #file,
                     function: String = #function,
                     line: Int = #line) {
        // Only log if the message level meets the category's minimum
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        self.log(level: level.osLogType, "\(fileName):\(line) - \(message)")
    }

    /// Log debug message
    func verbose(_ message: String,
                file: String = #file,
                function: String = #function,
                line: Int = #line) {
        logWithLevel(.debug, message, file: file, function: function, line: line)
    }

    /// Log with context information (deprecated - use logWithLevel)
    func logWithContext(_ message: String,
                       file: String = #file,
                       function: String = #function,
                       line: Int = #line,
                       level: OSLogType = .default) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        self.log(level: level, "\(fileName):\(line) - \(function): \(message)")
    }

    /// Log error with context
    func errorWithContext(_ message: String,
                         error: Error? = nil,
                         file: String = #file,
                         function: String = #function,
                         line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        if let error = error {
            self.error("\(fileName):\(line) - \(function): \(message) - Error: \(error.localizedDescription)")
        } else {
            self.error("\(fileName):\(line) - \(function): \(message)")
        }
    }
}

// MARK: - Buffer Statistics Logger

/// Helper for logging buffer processing statistics
struct BufferStatisticsLogger {
    private let logger: Logger
    private var lastLogTime = Date()
    private let logInterval: TimeInterval = 10.0 // Log summary every 10 seconds

    private var stats = BufferStats()

    struct BufferStats {
        var snapshotsReceived = 0
        var duplicateSnapshots = 0
        var changedSnapshots = 0
        var totalCharsProcessed = 0
        var totalChangedChars = 0
        var updatesSentToOpenAI = 0
    }

    init(logger: Logger) {
        self.logger = logger
    }

    mutating func recordSnapshot(charsExtracted: Int, charsChanged: Int, sentToOpenAI: Bool) {
        stats.snapshotsReceived += 1
        stats.totalCharsProcessed += charsExtracted

        if charsChanged == 0 {
            stats.duplicateSnapshots += 1
        } else {
            stats.changedSnapshots += 1
            stats.totalChangedChars += charsChanged
        }

        if sentToOpenAI {
            stats.updatesSentToOpenAI += 1
        }

        // Check if we should log a summary
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= logInterval && stats.snapshotsReceived > 0 {
            logSummary()
            resetStats()
            lastLogTime = now
        }
    }

    private func logSummary() {
        let changeRatio = stats.snapshotsReceived > 0
            ? Double(stats.changedSnapshots) / Double(stats.snapshotsReceived)
            : 0
        let avgCharsPerSnapshot = stats.snapshotsReceived > 0
            ? stats.totalCharsProcessed / stats.snapshotsReceived
            : 0

        logger.info("""
            📊 Buffer Processing Summary (last \(Int(logInterval))s):
            • Snapshots: \(stats.snapshotsReceived) received (\(stats.changedSnapshots) changed, \(stats.duplicateSnapshots) duplicate)
            • Change ratio: \(String(format: "%.1f%%", changeRatio * 100))
            • Characters: \(stats.totalCharsProcessed) processed, \(stats.totalChangedChars) changed
            • Avg chars/snapshot: \(avgCharsPerSnapshot)
            • Updates sent to OpenAI: \(stats.updatesSentToOpenAI)
            """)
    }

    private mutating func resetStats() {
        stats = BufferStats()
    }

    mutating func forceLogSummary() {
        if stats.snapshotsReceived > 0 {
            logSummary()
            resetStats()
            lastLogTime = Date()
        }
    }
}