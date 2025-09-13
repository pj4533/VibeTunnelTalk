import Foundation
import Combine
import OSLog

/// Represents a single cell in the terminal buffer
struct TerminalCell: Equatable {
    var character: Character = " "
    var foregroundColor: UInt8? = nil
    var backgroundColor: UInt8? = nil
    var attributes: TerminalAttributes = []
}

/// Terminal text attributes
struct TerminalAttributes: OptionSet, Equatable {
    let rawValue: UInt8

    static let bold = TerminalAttributes(rawValue: 1 << 0)
    static let dim = TerminalAttributes(rawValue: 1 << 1)
    static let italic = TerminalAttributes(rawValue: 1 << 2)
    static let underline = TerminalAttributes(rawValue: 1 << 3)
    static let blink = TerminalAttributes(rawValue: 1 << 4)
    static let reverse = TerminalAttributes(rawValue: 1 << 5)
    static let hidden = TerminalAttributes(rawValue: 1 << 6)
    static let strikethrough = TerminalAttributes(rawValue: 1 << 7)
}

/// Represents a region of the terminal that changed
struct TerminalChange {
    let startRow: Int
    let endRow: Int
    let content: String
    let isSignificant: Bool
}

/// Manages a virtual terminal buffer that tracks the current state of the terminal display
class TerminalBufferManager: ObservableObject {
    private let logger = AppLogger.terminalBuffer

    // Terminal dimensions
    private var cols: Int = 80
    private var rows: Int = 24

    // The actual buffer - 2D array of cells
    private var buffer: [[TerminalCell]] = []
    private var previousBuffer: [[TerminalCell]] = []

    // Cursor position
    private var cursorRow: Int = 0
    private var cursorCol: Int = 0

    // ANSI parser state
    private var ansiParser = ANSIParser()

    // Statistics
    @Published var totalBytesProcessed: Int = 0
    @Published var lastChangeDetected = Date()
    @Published var dataReductionRatio: Double = 0.0

    // Configuration
    var debugMode = false
    var ignoreUIChrome = true // Filter out headers, footers, borders

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        initializeBuffer()
    }

    /// Initialize or reinitialize the buffer with the given dimensions
    private func initializeBuffer() {
        buffer = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
        previousBuffer = buffer
    }

    /// Resize the terminal buffer
    func resize(cols: Int, rows: Int) {
        logger.info("[BUFFER] Resizing terminal to \(cols)x\(rows)")

        self.cols = cols
        self.rows = rows

        // Create new buffer with new dimensions
        var newBuffer = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)

        // Copy existing content that fits
        for row in 0..<min(self.rows, rows) {
            for col in 0..<min(self.cols, cols) {
                if row < buffer.count && col < buffer[row].count {
                    newBuffer[row][col] = buffer[row][col]
                }
            }
        }

        buffer = newBuffer
        previousBuffer = buffer

        // Adjust cursor position if needed
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    /// Process terminal output data and update the buffer
    func processOutput(_ data: String) {
        totalBytesProcessed += data.utf8.count

        // Parse ANSI sequences and update buffer
        let operations = ansiParser.parse(data)

        for operation in operations {
            applyOperation(operation)
        }
    }

    /// Apply a parsed terminal operation to the buffer
    private func applyOperation(_ operation: TerminalOperation) {
        switch operation {
        case .text(let text):
            writeText(text)

        case .moveCursor(let row, let col):
            cursorRow = max(0, min(row, rows - 1))
            cursorCol = max(0, min(col, cols - 1))

        case .clearScreen:
            initializeBuffer()
            cursorRow = 0
            cursorCol = 0

        case .clearLine:
            if cursorRow < buffer.count {
                buffer[cursorRow] = Array(repeating: TerminalCell(), count: cols)
            }

        case .setColor(let fg, let bg):
            // Color changes affect subsequent text
            // Store in parser state
            ansiParser.currentForeground = fg
            ansiParser.currentBackground = bg

        case .setAttribute(let attr):
            ansiParser.currentAttributes = attr

        case .carriageReturn:
            cursorCol = 0

        case .lineFeed:
            cursorRow += 1
            if cursorRow >= rows {
                // Scroll up
                scrollUp()
                cursorRow = rows - 1
            }

        case .backspace:
            if cursorCol > 0 {
                cursorCol -= 1
            }
        }
    }

    /// Write text at the current cursor position
    private func writeText(_ text: String) {
        for char in text {
            if cursorRow < buffer.count && cursorCol < buffer[cursorRow].count {
                buffer[cursorRow][cursorCol] = TerminalCell(
                    character: char,
                    foregroundColor: ansiParser.currentForeground,
                    backgroundColor: ansiParser.currentBackground,
                    attributes: ansiParser.currentAttributes
                )

                cursorCol += 1
                if cursorCol >= cols {
                    cursorCol = 0
                    cursorRow += 1
                    if cursorRow >= rows {
                        scrollUp()
                        cursorRow = rows - 1
                    }
                }
            }
        }
    }

    /// Scroll the buffer up by one line
    private func scrollUp() {
        buffer.removeFirst()
        buffer.append(Array(repeating: TerminalCell(), count: cols))
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
    private func isSignificantChange(_ content: String) -> Bool {
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

/// Terminal operations that can be applied to the buffer
enum TerminalOperation {
    case text(String)
    case moveCursor(row: Int, col: Int)
    case clearScreen
    case clearLine
    case setColor(fg: UInt8?, bg: UInt8?)
    case setAttribute(TerminalAttributes)
    case carriageReturn
    case lineFeed
    case backspace
}

/// ANSI escape sequence parser
class ANSIParser {
    var currentForeground: UInt8? = nil
    var currentBackground: UInt8? = nil
    var currentAttributes: TerminalAttributes = []

    private var escapeBuffer = ""
    private var inEscapeSequence = false

    /// Parse ANSI data and return terminal operations
    func parse(_ data: String) -> [TerminalOperation] {
        var operations: [TerminalOperation] = []
        var textBuffer = ""

        for char in data {
            if inEscapeSequence {
                escapeBuffer.append(char)

                // Check if escape sequence is complete
                if isEscapeSequenceComplete(escapeBuffer) {
                    // Flush any pending text
                    if !textBuffer.isEmpty {
                        operations.append(.text(textBuffer))
                        textBuffer = ""
                    }

                    // Parse the escape sequence
                    if let operation = parseEscapeSequence(escapeBuffer) {
                        operations.append(operation)
                    }

                    escapeBuffer = ""
                    inEscapeSequence = false
                }
            } else if char == "\u{1B}" { // ESC character
                // Start of escape sequence
                if !textBuffer.isEmpty {
                    operations.append(.text(textBuffer))
                    textBuffer = ""
                }
                inEscapeSequence = true
                escapeBuffer = String(char)
            } else if char == "\r" {
                if !textBuffer.isEmpty {
                    operations.append(.text(textBuffer))
                    textBuffer = ""
                }
                operations.append(.carriageReturn)
            } else if char == "\n" {
                if !textBuffer.isEmpty {
                    operations.append(.text(textBuffer))
                    textBuffer = ""
                }
                operations.append(.lineFeed)
            } else if char == "\u{08}" { // Backspace
                if !textBuffer.isEmpty {
                    operations.append(.text(textBuffer))
                    textBuffer = ""
                }
                operations.append(.backspace)
            } else {
                textBuffer.append(char)
            }
        }

        // Flush remaining text
        if !textBuffer.isEmpty {
            operations.append(.text(textBuffer))
        }

        return operations
    }

    /// Check if an escape sequence is complete
    private func isEscapeSequenceComplete(_ sequence: String) -> Bool {
        guard sequence.count >= 2 else { return false }

        let chars = Array(sequence)

        // CSI sequences end with a letter
        if chars[1] == "[" {
            if let last = chars.last, last.isLetter || last == "m" || last == "H" || last == "J" || last == "K" {
                return true
            }
        }

        // OSC sequences end with BEL or ST
        if chars[1] == "]" {
            return sequence.contains("\u{07}") || sequence.contains("\u{1B}\\")
        }

        // Simple two-character sequences
        if sequence.count == 2 && chars[1].isLetter {
            return true
        }

        return false
    }

    /// Parse a complete escape sequence into an operation
    private func parseEscapeSequence(_ sequence: String) -> TerminalOperation? {
        guard sequence.count >= 2 else { return nil }

        let chars = Array(sequence)

        // CSI sequences
        if chars[1] == "[" {
            let params = String(sequence.dropFirst(2).dropLast())
            let command = chars.last ?? " "

            switch command {
            case "H": // Cursor position
                let parts = params.split(separator: ";").compactMap { Int($0) }
                let row = (parts.first ?? 1) - 1
                let col = (parts.count > 1 ? parts[1] : 1) - 1
                return .moveCursor(row: row, col: col)

            case "J": // Clear screen
                let param = Int(params) ?? 0
                if param == 2 {
                    return .clearScreen
                }

            case "K": // Clear line
                return .clearLine

            case "m": // SGR (Select Graphic Rendition)
                return parseSGR(params)

            default:
                break
            }
        }

        return nil
    }

    /// Parse SGR (Select Graphic Rendition) parameters
    private func parseSGR(_ params: String) -> TerminalOperation? {
        let codes = params.split(separator: ";").compactMap { Int($0) }

        for code in codes {
            switch code {
            case 0: // Reset
                currentAttributes = []
                currentForeground = nil
                currentBackground = nil

            case 1: // Bold
                currentAttributes.insert(.bold)

            case 2: // Dim
                currentAttributes.insert(.dim)

            case 3: // Italic
                currentAttributes.insert(.italic)

            case 4: // Underline
                currentAttributes.insert(.underline)

            case 30...37: // Foreground color
                currentForeground = UInt8(code - 30)

            case 40...47: // Background color
                currentBackground = UInt8(code - 40)

            default:
                break
            }
        }

        return .setAttribute(currentAttributes)
    }
}