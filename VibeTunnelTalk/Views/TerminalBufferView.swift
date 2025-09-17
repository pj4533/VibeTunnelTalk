import SwiftUI

/// Displays an accurate terminal buffer snapshot using real-time WebSocket updates
struct TerminalBufferView: View {
    @StateObject private var viewModel = TerminalBufferViewModel()
    let sessionId: String
    let fontSize: CGFloat

    init(sessionId: String, fontSize: CGFloat = 12) {
        self.sessionId = sessionId
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = viewModel.currentBuffer {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<snapshot.rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<snapshot.cols, id: \.self) { col in
                                    cellView(for: snapshot, row: row, col: col)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .background(Color.black)
                .foregroundColor(Color.green)
            } else if viewModel.isLoading {
                ProgressView("Loading terminal buffer...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else if viewModel.error != nil {
                Text("Unable to load terminal buffer")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                Text("Connecting to terminal...")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .onAppear {
            viewModel.startReceivingUpdates(for: sessionId)
        }
        .onDisappear {
            viewModel.stopReceivingUpdates()
        }
    }

    @ViewBuilder
    private func cellView(for snapshot: BufferSnapshot, row: Int, col: Int) -> some View {
        if row < snapshot.cells.count && col < snapshot.cells[row].count {
            let cell = snapshot.cells[row][col]
            let isCursor = (row == snapshot.cursorY && col == snapshot.cursorX)

            Text(cell.displayChar)
                .foregroundColor(foregroundColor(for: cell))
                .background(isCursor ? Color.white.opacity(0.3) : backgroundColor(for: cell))
                .frame(width: fontSize * 0.6 * CGFloat(max(1, cell.width)))
        } else {
            Text(" ")
                .frame(width: fontSize * 0.6)
        }
    }

    private func foregroundColor(for cell: BufferCell) -> Color {
        guard let fg = cell.fg else {
            return .green // Default terminal green
        }

        return colorFromIndex(fg)
    }

    private func backgroundColor(for cell: BufferCell) -> Color {
        guard let bg = cell.bg else {
            return .clear
        }

        return colorFromIndex(bg)
    }

    private func colorFromIndex(_ index: Int) -> Color {
        // Check if it's an RGB color (high bit set)
        if (index & 0xFF000000) != 0 {
            let r = Double((index >> 16) & 0xFF) / 255.0
            let g = Double((index >> 8) & 0xFF) / 255.0
            let b = Double(index & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }

        // ANSI 16-color palette
        switch index {
        case 0: return Color(white: 0.0) // Black
        case 1: return Color(red: 0.7, green: 0.0, blue: 0.0) // Red
        case 2: return Color(red: 0.0, green: 0.7, blue: 0.0) // Green
        case 3: return Color(red: 0.7, green: 0.7, blue: 0.0) // Yellow
        case 4: return Color(red: 0.0, green: 0.0, blue: 0.7) // Blue
        case 5: return Color(red: 0.7, green: 0.0, blue: 0.7) // Magenta
        case 6: return Color(red: 0.0, green: 0.7, blue: 0.7) // Cyan
        case 7: return Color(white: 0.7) // White
        case 8: return Color(white: 0.4) // Bright Black
        case 9: return Color(red: 1.0, green: 0.0, blue: 0.0) // Bright Red
        case 10: return Color(red: 0.0, green: 1.0, blue: 0.0) // Bright Green
        case 11: return Color(red: 1.0, green: 1.0, blue: 0.0) // Bright Yellow
        case 12: return Color(red: 0.0, green: 0.0, blue: 1.0) // Bright Blue
        case 13: return Color(red: 1.0, green: 0.0, blue: 1.0) // Bright Magenta
        case 14: return Color(red: 0.0, green: 1.0, blue: 1.0) // Bright Cyan
        case 15: return Color(white: 1.0) // Bright White

        // 256-color palette
        case 16...231:
            // 216 color cube: 16 + 36*r + 6*g + b
            let idx = index - 16
            let r = (idx / 36) % 6
            let g = (idx / 6) % 6
            let b = idx % 6
            return Color(
                red: Double(r) / 5.0,
                green: Double(g) / 5.0,
                blue: Double(b) / 5.0
            )

        case 232...255:
            // Grayscale
            let gray = Double(index - 232) / 23.0
            return Color(white: gray)

        default:
            return .green
        }
    }
}