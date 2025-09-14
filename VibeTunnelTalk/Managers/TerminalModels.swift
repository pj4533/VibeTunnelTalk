import Foundation

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