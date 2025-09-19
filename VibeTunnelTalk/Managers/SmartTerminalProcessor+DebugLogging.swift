import Foundation
import OSLog

// MARK: - Debug Logging
extension SmartTerminalProcessor {

    func createDebugFile() {
        // Create filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let openAIFilename = "openai_updates_\(timestamp).txt"

        // Create logs directory in Library/Logs/VibeTunnelTalk
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibeTunnelTalk")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Create OpenAI updates file
        let openAIFilePath = logsDir.appendingPathComponent(openAIFilename)
        FileManager.default.createFile(atPath: openAIFilePath.path, contents: nil, attributes: nil)

        // Open file handle for writing
        do {
            debugFileHandle = try FileHandle(forWritingTo: openAIFilePath)

            // Write header
            let header = """
            ========================================
            VibeTunnelTalk - OpenAI Updates Log
            Started: \(Date())
            Source: Asciinema File Stream
            ========================================

            """

            if let data = header.data(using: .utf8) {
                debugFileHandle?.write(data)
                debugFileHandle?.synchronizeFile() // Force flush to disk
            }

            logger.info("[DEBUG] Created OpenAI updates log file at: \(openAIFilePath.path)")
        } catch {
            logger.error("[DEBUG] Failed to create debug file: \(error.localizedDescription)")
        }
    }

    func writeToDebugFile(_ content: String) {
        guard let debugFileHandle = debugFileHandle else {
            logger.warning("[DEBUG] No debug file handle available for writing")
            return
        }

        // Create detailed timestamp with milliseconds
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        let entry = """

        [\(timestamp)] - Update #\(totalUpdatesSent)
        ----------------------------------------
        Events processed: \(totalEventsProcessed)
        Characters sent: \(content.count)
        ----------------------------------------
        CONTENT SENT TO OPENAI:
        \(content)
        ========================================

        """

        if let data = entry.data(using: .utf8) {
            debugFileHandle.write(data)
            debugFileHandle.synchronizeFile() // Force flush to disk
        }
    }

}