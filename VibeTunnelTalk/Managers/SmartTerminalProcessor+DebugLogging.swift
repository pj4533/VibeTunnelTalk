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
        let rawBufferFilename = "raw_buffers_\(timestamp).txt"

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

        // Create raw buffer log file
        let rawBufferFilePath = logsDir.appendingPathComponent(rawBufferFilename)
        FileManager.default.createFile(atPath: rawBufferFilePath.path, contents: nil, attributes: nil)

        // Open raw buffer file handle
        do {
            rawBufferFileHandle = try FileHandle(forWritingTo: rawBufferFilePath)

            // Write header
            let bufferHeader = """
            ========================================
            VibeTunnelTalk - Raw Buffer Log
            Started: \(Date())
            Every decoded BufferSnapshot is logged here
            ========================================

            """

            if let data = bufferHeader.data(using: .utf8) {
                rawBufferFileHandle?.write(data)
                rawBufferFileHandle?.synchronizeFile()
            }

            logger.info("[DEBUG] Created raw buffer log file at: \(rawBufferFilePath.path)")
        } catch {
            logger.error("[DEBUG] Failed to create raw buffer file: \(error.localizedDescription)")
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

        let entry = """

        [\(timestamp)] - Update #\(totalUpdatesSent)
        ----------------------------------------
        Snapshots processed: \(totalSnapshotsProcessed)
        Data reduction: \(String(format: "%.1f%%", dataReductionRatio * 100))
        Characters sent: \(content.count)
        Buffer stats: \(bufferStats)
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

    func writeRawBufferToDebugFile(_ snapshot: BufferSnapshot, bufferNumber: Int) {
        guard let rawBufferFileHandle = rawBufferFileHandle else {
            return
        }

        // Create detailed timestamp with milliseconds
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // Extract text content
        var lines: [String] = []
        for (rowIndex, row) in snapshot.cells.enumerated() {
            var line = ""
            for cell in row {
                line += cell.displayChar
            }
            // Show the row number for debugging
            lines.append("[\(String(format: "%03d", rowIndex))] \(line)")
        }
        let textContent = lines.joined(separator: "\n")

        // Create buffer entry with clear separation
        let entry = """

        ================================================================================
        BUFFER #\(bufferNumber) - [\(timestamp)]
        ================================================================================
        Dimensions: \(snapshot.cols) cols x \(snapshot.rows) rows
        Cursor: (\(snapshot.cursorX), \(snapshot.cursorY))
        ViewportY: \(snapshot.viewportY)
        --------------------------------------------------------------------------------
        BUFFER CONTENT:
        --------------------------------------------------------------------------------
        \(textContent)
        --------------------------------------------------------------------------------
        END OF BUFFER #\(bufferNumber)
        ================================================================================


        """

        if let data = entry.data(using: .utf8) {
            rawBufferFileHandle.write(data)
            rawBufferFileHandle.synchronizeFile() // Force flush to disk
        }
    }
}