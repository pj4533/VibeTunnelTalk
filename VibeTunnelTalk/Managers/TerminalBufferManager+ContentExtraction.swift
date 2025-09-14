import Foundation

// MARK: - Content Extraction
extension TerminalBufferManager {

    /// Get the current buffer snapshot for display
    func getBufferSnapshot() -> (buffer: [[TerminalCell]], cursorRow: Int, cursorCol: Int) {
        return (buffer, cursorRow, cursorCol)
    }

    /// Get the current buffer as plain text
    func getBufferText() -> String {
        var result = ""
        for row in buffer {
            for cell in row {
                result.append(cell.character)
            }
            result.append("\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get the main content area of the terminal (excluding headers/footers)
    func getMainContentArea() -> String {
        // Try to identify the main content area by looking for patterns
        var contentStartRow = 0
        var contentEndRow = rows - 1

        // Look for header patterns in first few rows
        for row in 0..<min(5, rows) {
            let rowText = buffer[row].map { String($0.character) }.joined()
            if rowText.contains("Claude") || rowText.contains("──") || rowText.contains("══") {
                contentStartRow = max(contentStartRow, row + 1)
            }
        }

        // Look for footer patterns in last few rows
        for row in max(0, rows - 5)..<rows {
            let rowText = buffer[row].map { String($0.character) }.joined()
            if rowText.contains("──") || rowText.contains("══") || rowText.contains("[") && rowText.contains("]") {
                contentEndRow = min(contentEndRow, row - 1)
            }
        }

        // Extract the content area
        var content = ""
        for row in contentStartRow...contentEndRow {
            if row < buffer.count {
                let rowText = buffer[row].map { String($0.character) }.joined()
                let trimmed = rowText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    content += trimmed + "\n"
                }
            }
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}