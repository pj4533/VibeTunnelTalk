import SwiftUI
import Combine
import OSLog

struct ConnectedView: View {
    @ObservedObject var socketManager: VibeTunnelSocketManager
    @ObservedObject var openAIManager: OpenAIRealtimeManager
    @ObservedObject var activityMonitor: SessionActivityMonitor
    
    @State private var isExpanded = true
    @State private var terminalOutput = ""
    @State private var showTerminal = false
    
    private let logger = AppLogger.ui
    
    var body: some View {
        VStack(spacing: 0) {
            // Voice Activity Indicator
            VoiceActivityView(
                isListening: openAIManager.isListening,
                isSpeaking: openAIManager.isSpeaking,
                onToggleListening: {
                    if openAIManager.isListening {
                        openAIManager.stopListening()
                    } else {
                        openAIManager.startListening()
                    }
                }
            )
            
            Divider()
            
            // Activity Display
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    // Last Narration
                    if !activityMonitor.lastNarration.isEmpty {
                        NarrationCard(
                            title: "Latest Update",
                            narration: activityMonitor.lastNarration,
                            isProcessing: activityMonitor.isProcessing
                        )
                    }
                    
                    // Transcription
                    if !openAIManager.transcription.isEmpty {
                        TranscriptionCard(text: openAIManager.transcription)
                    }
                    
                    // Terminal Preview (Optional)
                    if showTerminal {
                        TerminalPreviewCard(output: terminalOutput)
                    }
                }
                .padding()
            }
            
            // Controls
            HStack {
                Button(action: { showTerminal.toggle() }) {
                    Label(
                        showTerminal ? "Hide Terminal" : "Show Terminal",
                        systemImage: "terminal"
                    )
                }
                
                Button(action: { socketManager.requestRefresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Request terminal to resend current buffer")
                
                Spacer()
                
                Button("Disconnect") {
                    disconnect()
                }
                .foregroundColor(.red)
            }
            .padding()
        }
        .onReceive(socketManager.terminalOutput) { output in
            terminalOutput += output
            // Keep last 1000 lines
            let lines = terminalOutput.components(separatedBy: .newlines)
            if lines.count > 1000 {
                terminalOutput = lines.suffix(1000).joined(separator: "\n")
            }
        }
        .onAppear {
            // View appeared
        }
    }
    
    private func disconnect() {
        socketManager.disconnect()
        openAIManager.disconnect()
    }
}

struct NarrationCard: View {
    let title: String
    let narration: String
    let isProcessing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            Text(narration)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(nil)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct TranscriptionCard: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcription", systemImage: "text.bubble")
                .font(.headline)
            
            Text(text)
                .font(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct TerminalPreviewCard: View {
    let output: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Terminal Output", systemImage: "terminal")
                .font(.headline)
            
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(10)
            .background(Color.black.opacity(0.9))
            .foregroundColor(.green)
            .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}