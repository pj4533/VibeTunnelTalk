import SwiftUI
import Combine
import OSLog

struct ConnectedView: View {
    @ObservedObject var socketManager: VibeTunnelSocketManager
    @ObservedObject var openAIManager: OpenAIRealtimeManager
    
    @State private var isExpanded = true
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
                    // Placeholder for activity display
                    Text("Claude activity will be narrated by OpenAI")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding()
                    
                    // Transcription
                    if !openAIManager.transcription.isEmpty {
                        TranscriptionCard(text: openAIManager.transcription)
                    }
                    
                    // Terminal Buffer Display
                    if showTerminal {
                        if let sessionId = socketManager.currentSessionId {
                            TerminalBufferCard(sessionId: sessionId, socketManager: socketManager)
                        } else {
                            Text("Terminal buffer not available")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    }
                }
                .padding()
            }
            
            // Controls
            HStack {
                Button(action: { showTerminal.toggle() }) {
                    Label(
                        showTerminal ? "Hide Terminal Buffer" : "Show Terminal Buffer",
                        systemImage: "terminal"
                    )
                }
                
                Button(action: { socketManager.refreshTerminal() }) {
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

struct TerminalBufferCard: View {
    let sessionId: String
    @ObservedObject var socketManager: VibeTunnelSocketManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Terminal Buffer", systemImage: "terminal")
                .font(.headline)

            TerminalBufferView(sessionId: sessionId, fontSize: 11)
                .frame(height: 300)
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}