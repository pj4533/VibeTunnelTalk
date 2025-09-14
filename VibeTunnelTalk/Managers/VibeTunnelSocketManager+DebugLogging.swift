import Foundation
import OSLog

// MARK: - Debug Logging
extension VibeTunnelSocketManager {

    func createDebugFile(sessionId: String) {
        debugQueue.async { [weak self] in
            // Close any existing debug file
            self?.debugFileHandle?.closeFile()
            self?.debugFileHandle = nil

            // Create filename with session name and timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())
            let filename = "\(sessionId)_\(timestamp).txt"

            // Create logs directory in Library/Logs/VibeTunnelTalk
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/VibeTunnelTalk")

            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

            let filePath = logsDir.appendingPathComponent(filename)

            // Create the file
            FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)

            // Open file handle for writing
            self?.debugFileHandle = try? FileHandle(forWritingTo: filePath)

            // Write header
            let header = """
            ========================================
            VibeTunnel Debug Log
            Session: \(sessionId)
            Started: \(Date())
            ========================================

            """
            if let headerData = header.data(using: .utf8) {
                self?.debugFileHandle?.write(headerData)
            }

            self?.logger.info("[DEBUG] Created debug file: \(filePath.path)")
        }
    }

    func writeToDebugFile(_ content: String, source: String) {
        debugQueue.async { [weak self] in
            guard let fileHandle = self?.debugFileHandle else { return }

            // Clean the content before writing
            let cleanedContent = self?.cleanDebugContent(content) ?? content

            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timeString = formatter.string(from: timestamp)

            let entry = """

            [\(timeString)] [\(source)]
            ----------------------------------------
            \(cleanedContent)
            ========================================

            """

            if let data = entry.data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }

    private func cleanDebugContent(_ text: String) -> String {
        var cleaned = text

        // First, handle JSON-escaped sequences
        // Convert \u001b to actual escape character
        cleaned = cleaned.replacingOccurrences(of: "\\u001b", with: "\u{001B}")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\r")
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\t", with: "\t")

        // Now remove ANSI escape sequences (color codes, cursor movements, etc.)
        // This matches ESC followed by [ and then any combination of numbers and semicolons, ending with a letter
        let ansiPattern = "\u{001B}\\[[0-9;]*[a-zA-Z]"
        cleaned = cleaned.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )

        // Remove other ANSI sequences
        let additionalPatterns = [
            "\u{001B}\\[\\?[0-9]+[hl]",     // DEC private mode (like ?2026h, ?2026l)
            "\u{001B}\\[[0-9]+(;[0-9]+)*m", // SGR sequences (colors, bold, etc)
            "\u{001B}\\].*;.*\u{0007}",     // OSC sequences
            "\u{001B}[\\(\\)].",             // Character set selection
            "\u{001B}.",                     // Any other ESC + single character
            "\r",                             // Carriage returns
        ]

        for pattern in additionalPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        // Remove remaining control characters
        let controlCharsPattern = "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}]"
        cleaned = cleaned.replacingOccurrences(
            of: controlCharsPattern,
            with: "",
            options: .regularExpression
        )

        // Clean up the JSON array structure if present
        // Match patterns like [0,"o","..."] and extract just the content
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            // Try to parse as JSON array and extract the string content
            if let data = cleaned.data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any],
               jsonArray.count >= 3,
               let content = jsonArray[2] as? String {
                cleaned = content

                // Re-apply cleaning to the extracted content
                return cleanDebugContent(cleaned)
            }
        }

        // Clean up multiple consecutive newlines
        let multipleNewlines = "\n{3,}"
        cleaned = cleaned.replacingOccurrences(
            of: multipleNewlines,
            with: "\n\n",
            options: .regularExpression
        )

        // Trim whitespace from each line
        let lines = cleaned.components(separatedBy: .newlines)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        cleaned = trimmedLines.joined(separator: "\n")

        return cleaned
    }

    func closeDebugFile() {
        debugQueue.async { [weak self] in
            // Write closing message
            let footer = """

            ========================================
            Session ended: \(Date())
            ========================================
            """
            if let footerData = footer.data(using: .utf8) {
                self?.debugFileHandle?.write(footerData)
            }

            // Close file handle
            self?.debugFileHandle?.closeFile()
            self?.debugFileHandle = nil

            self?.logger.info("[DEBUG] Closed debug file")
        }
    }
}