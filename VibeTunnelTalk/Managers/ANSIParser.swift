import Foundation

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