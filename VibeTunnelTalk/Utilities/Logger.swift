import Foundation
import OSLog

/// Centralized logging system for VibeTunnelTalk
struct AppLogger {
    /// Main bundle identifier for the app
    private static let subsystem = "com.vibetunneltalk"
    
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
        
        var logger: Logger {
            Logger(subsystem: AppLogger.subsystem, category: self.rawValue)
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
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log with context information
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