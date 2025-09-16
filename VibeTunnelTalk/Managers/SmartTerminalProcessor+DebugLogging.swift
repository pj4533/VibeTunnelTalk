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
        do {
            debugFileHandle = try FileHandle(forWritingTo: filePath)

            // Write header
            let header = """
            ========================================
            VibeTunnelTalk - OpenAI Updates Log
            Started: \(Date())
            ========================================

            """

            if let data = header.data(using: .utf8) {
                debugFileHandle?.write(data)
                debugFileHandle?.synchronizeFile() // Force flush to disk
            }

            logger.info("[DEBUG] Created OpenAI updates log file at: \(filePath.path)")
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

        // Get buffer processing stats
        let bufferStats = getBufferProcessingStats()

        // Check if this is a combined update
        let isCombined = content.contains("---")
        let updateType = isCombined ? "COMBINED UPDATE" : "Update"

        let entry = """

        [\(timestamp)] - \(updateType) #\(totalUpdatesSent)
        ----------------------------------------
        Snapshots processed: \(totalSnapshotsProcessed)
        Data reduction: \(String(format: "%.1f%%", dataReductionRatio * 100))
        Characters sent: \(content.count)
        Buffer stats: \(bufferStats)
        Accumulated pending: \(accumulatedChangeCount) chars
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

    private func getBufferProcessingStats() -> String {
        // Calculate stats from the current buffer state
        var stats: [String] = []

        if let snapshot = lastBufferSnapshot {
            stats.append("rows=\(snapshot.rows)")
            stats.append("cols=\(snapshot.cols)")

            // Count non-empty cells
            var nonEmptyCells = 0
            for row in snapshot.cells {
                for cell in row {
                    if !cell.char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        nonEmptyCells += 1
                    }
                }
            }
            stats.append("non_empty_cells=\(nonEmptyCells)")

            // Add accumulation stats
            if !accumulatedChanges.isEmpty {
                stats.append("accumulated_updates=\(accumulatedChanges.count)")
            }
        } else {
            stats.append("buffer=none")
        }

        return stats.joined(separator: ", ")
    }

    func writeSkippedUpdateToDebugFile(_ content: String, changeCount: Int, reason: String) {
        guard let debugFileHandle = debugFileHandle else {
            logger.warning("[DEBUG] No debug file handle available for writing skipped update")
            return
        }

        // Create detailed timestamp with milliseconds
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        let entry = """

        [\(timestamp)] - SKIPPED UPDATE
        ----------------------------------------
        Reason: \(reason)
        Characters changed: \(changeCount)
        Threshold: \(minChangeThreshold)
        Content preview (first 200 chars):
        \(String(content.prefix(200)))...
        ========================================

        """

        if let data = entry.data(using: .utf8) {
            debugFileHandle.write(data)
            debugFileHandle.synchronizeFile() // Force flush to disk
        }
    }
}