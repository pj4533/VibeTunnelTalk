import Foundation
import SwiftUI
import Combine

/// Settings for debugging and development features
class DebugSettings: ObservableObject {
    static let shared = DebugSettings()

    /// Whether to log raw terminal output (with ANSI codes) instead of cleaned output to OpenAI logs
    @AppStorage("debug.logRawTerminalOutput") var logRawTerminalOutput: Bool = false

    /// Whether to show verbose logging in console
    @AppStorage("debug.verboseLogging") var verboseLogging: Bool = false

    /// Whether to save debug files
    @AppStorage("debug.saveDebugFiles") var saveDebugFiles: Bool = true

    private init() {
        // Private initializer for singleton
    }

    /// Reset all debug settings to defaults
    func resetToDefaults() {
        logRawTerminalOutput = false
        verboseLogging = false
        saveDebugFiles = true
    }
}