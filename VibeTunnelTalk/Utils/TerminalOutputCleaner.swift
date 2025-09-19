import Foundation

/// Utility for cleaning terminal output by removing ANSI escape codes and control sequences
enum TerminalOutputCleaner {

    /// Remove ANSI escape codes and terminal control sequences from text
    static func cleanTerminalOutput(_ input: String) -> String {
        var cleaned = input

        // Remove ANSI escape sequences (CSI sequences)
        // Matches: ESC [ ... (letters/numbers/semicolons) letter
        cleaned = cleaned.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )

        // Remove OSC sequences (Operating System Commands)
        // Matches: ESC ] ... BEL or ESC ] ... ESC \
        cleaned = cleaned.replacingOccurrences(
            of: "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)",
            with: "",
            options: .regularExpression
        )

        // Remove other ESC sequences
        // Matches: ESC followed by any single character
        cleaned = cleaned.replacingOccurrences(
            of: "\\x1B[^\\[\\]]",
            with: "",
            options: .regularExpression
        )

        // Remove color codes (38;2 RGB and 39 reset)
        cleaned = cleaned.replacingOccurrences(
            of: "\\[38;2;[0-9]+;[0-9]+;[0-9]+m",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "\\[39m",
            with: "",
            options: .regularExpression
        )

        // Remove other common ANSI codes
        cleaned = cleaned.replacingOccurrences(
            of: "\\[[0-9]+(;[0-9]+)*m",
            with: "",
            options: .regularExpression
        )

        // Remove terminal mode sequences
        // ? sequences for cursor, screen modes etc.
        cleaned = cleaned.replacingOccurrences(
            of: "\\[\\?[0-9]+[hl]",
            with: "",
            options: .regularExpression
        )

        // Remove cursor positioning codes
        cleaned = cleaned.replacingOccurrences(
            of: "\\[[0-9]*[ABCDEFGHJKST]",
            with: "",
            options: .regularExpression
        )

        // Remove line clearing codes
        cleaned = cleaned.replacingOccurrences(
            of: "\\[2?K",
            with: "",
            options: .regularExpression
        )

        // Remove cursor save/restore
        cleaned = cleaned.replacingOccurrences(
            of: "\\[s|\\[u",
            with: "",
            options: .regularExpression
        )

        // Remove text attribute codes (bold, italic, etc.)
        cleaned = cleaned.replacingOccurrences(
            of: "\\[[0-9]*m",
            with: "",
            options: .regularExpression
        )

        // Clean up box drawing characters by replacing with ASCII equivalents
        let boxDrawingReplacements = [
            "╭": "+",
            "╮": "+",
            "╰": "+",
            "╯": "+",
            "│": "|",
            "─": "-",
            "⏵": ">",
            "✻": "*"
        ]

        for (unicode, ascii) in boxDrawingReplacements {
            cleaned = cleaned.replacingOccurrences(of: unicode, with: ascii)
        }

        // Clean up multiple consecutive newlines (keep max 2)
        cleaned = cleaned.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        // Trim leading/trailing whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    /// Clean and format terminal output for better readability
    static func formatCleanedOutput(_ input: String) -> String {
        // First clean the raw output
        let cleaned = cleanTerminalOutput(input)

        // Split into lines for better formatting
        let lines = cleaned.components(separatedBy: .newlines)

        // Filter out empty lines at the beginning and end
        let nonEmptyLines = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .reversed()
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .reversed()

        // Reconstruct with proper line breaks
        return Array(nonEmptyLines).joined(separator: "\n")
    }
}