import SwiftUI
import Combine
import OSLog

struct ConnectedView: View {
    @ObservedObject var socketManager: VibeTunnelSocketManager
    @ObservedObject var openAIManager: OpenAIRealtimeManager
    
    @State private var isExpanded = true
    
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
                    
                    // Terminal display removed - using file-based streaming now
                }
                .padding()
            }
            
            // Controls
            HStack {
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

