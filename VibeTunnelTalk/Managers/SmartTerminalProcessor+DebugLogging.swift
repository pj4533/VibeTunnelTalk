import Foundation
import OSLog

// MARK: - Debug Logging
extension SmartTerminalProcessor {

    func createDebugFile() {
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

    func writeToDebugFile(_ content: String) {
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