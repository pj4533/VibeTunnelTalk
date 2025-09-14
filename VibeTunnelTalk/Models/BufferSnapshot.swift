import Foundation

/// Binary buffer snapshot data from VibeTunnel
struct BufferSnapshot: Codable {
    let cols: Int
    let rows: Int
    let viewportY: Int
    let cursorX: Int
    let cursorY: Int
    let cells: [[BufferCell]]
}

/// Individual cell data in the terminal buffer
struct BufferCell: Codable {
    let char: String
    let width: Int
    let fg: Int?
    let bg: Int?
    let attributes: Int?

    /// Returns the character to display (space if empty)
    var displayChar: String {
        return char.isEmpty ? " " : char
    }
}

/// ANSI color palette indices
enum ANSIColor {
    static let black = 0
    static let red = 1
    static let green = 2
    static let yellow = 3
    static let blue = 4
    static let magenta = 5
    static let cyan = 6
    static let white = 7
    static let brightBlack = 8
    static let brightRed = 9
    static let brightGreen = 10
    static let brightYellow = 11
    static let brightBlue = 12
    static let brightMagenta = 13
    static let brightCyan = 14
    static let brightWhite = 15
}