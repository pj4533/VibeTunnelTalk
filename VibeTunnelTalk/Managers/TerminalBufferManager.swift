import Foundation
import Combine
import OSLog

/// Manages a virtual terminal buffer that tracks the current state of the terminal display
class TerminalBufferManager: ObservableObject {
    private let logger = AppLogger.terminalBuffer

    // Terminal dimensions
    var cols: Int = 80
    var rows: Int = 24

    // The actual buffer - 2D array of cells
    var buffer: [[TerminalCell]] = []
    var previousBuffer: [[TerminalCell]] = []

    // Cursor position
    var cursorRow: Int = 0
    var cursorCol: Int = 0

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
}