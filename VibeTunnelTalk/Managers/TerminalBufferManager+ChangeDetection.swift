import Foundation

// MARK: - Change Detection
extension TerminalBufferManager {

    /// Detect changes between the current and previous buffer state
    func detectChanges() -> [TerminalChange] {
        var changes: [TerminalChange] = []
        var changeStartRow: Int? = nil
        var changeContent = ""

        for row in 0..<rows {
            let rowChanged = !areRowsEqual(buffer[row], previousBuffer[row])

            if rowChanged {
                if changeStartRow == nil {
                    changeStartRow = row
                }

                // Extract row text
                let rowText = buffer[row].map { String($0.character) }.joined()
                changeContent += rowText.trimmingCharacters(in: .whitespaces) + "\n"
            } else if let startRow = changeStartRow {
                // End of change region
                let change = TerminalChange(
                    startRow: startRow,
                    endRow: row - 1,
                    content: changeContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    isSignificant: isSignificantChange(changeContent)
                )
                changes.append(change)

                changeStartRow = nil
                changeContent = ""
            }
        }

        // Handle change that extends to the last row
        if let startRow = changeStartRow {
            let change = TerminalChange(
                startRow: startRow,
                endRow: rows - 1,
                content: changeContent.trimmingCharacters(in: .whitespacesAndNewlines),
                isSignificant: isSignificantChange(changeContent)
            )
            changes.append(change)
        }

        // Update previous buffer for next comparison
        previousBuffer = buffer.map { $0 }

        if !changes.isEmpty {
            lastChangeDetected = Date()
        }

        return changes
    }

    /// Check if two rows are equal
    private func areRowsEqual(_ row1: [TerminalCell], _ row2: [TerminalCell]) -> Bool {
        guard row1.count == row2.count else { return false }
        return row1 == row2
    }

    /// Determine if a change is significant enough to report
    func isSignificantChange(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty changes are not significant
        if trimmed.isEmpty {
            return false
        }

        // UI chrome patterns to ignore if configured
        if ignoreUIChrome {
            let chromePatterns = [
                "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", // Box drawing
                "═", "║", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬", // Double box
                "▀", "▄", "█", "▌", "▐", "░", "▒", "▓", // Block elements
            ]

            // Check if content is mostly UI chrome
            var chromeCharCount = 0
            for char in trimmed {
                if chromePatterns.contains(String(char)) {
                    chromeCharCount += 1
                }
            }

            let chromeRatio = Double(chromeCharCount) / Double(trimmed.count)
            if chromeRatio > 0.5 {
                return false // Mostly UI chrome
            }
        }

        // Check for repetitive patterns (status bars, headers)
        let lines = trimmed.components(separatedBy: .newlines)
        if lines.count == 1 {
            let line = lines[0]
            // Single line updates that look like status/headers
            if line.hasPrefix("[") && line.hasSuffix("]") {
                return false // Likely a status bar
            }
            if line.allSatisfy({ $0 == "─" || $0 == "═" || $0 == " " }) {
                return false // Horizontal separator
            }
        }

        return true
    }

    /// Get a summary of changes suitable for sending to OpenAI
    func getChangeSummary(changes: [TerminalChange]) -> String? {
        let significantChanges = changes.filter { $0.isSignificant }

        guard !significantChanges.isEmpty else {
            return nil
        }

        var summary = "Terminal Update:\n"

        for change in significantChanges {
            summary += change.content + "\n"
        }

        // Calculate data reduction
        let originalSize = totalBytesProcessed
        let summarySize = summary.utf8.count
        if originalSize > 0 {
            dataReductionRatio = 1.0 - (Double(summarySize) / Double(originalSize))
        }

        return summary
    }
}