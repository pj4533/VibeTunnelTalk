import SwiftUI
import Combine

struct ConnectedView: View {
    @ObservedObject var socketManager: VibeTunnelSocketManager
    @ObservedObject var openAIManager: OpenAIRealtimeManager
    @ObservedObject var activityMonitor: SessionActivityMonitor
    
    @State private var isExpanded = true
    @State private var terminalOutput = ""
    @State private var showTerminal = false
    
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
                    // Current Activity
                    ActivityCard(
                        title: "Current Activity",
                        activity: activityMonitor.currentActivity,
                        narration: activityMonitor.lastNarration
                    )
                    
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
    }
    
    private func disconnect() {
        socketManager.disconnect()
        openAIManager.disconnect()
    }
}

struct ActivityCard: View {
    let title: String
    let activity: ActivityState
    let narration: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                
                Spacer()
                
                ActivityBadge(activity: activity)
            }
            
            Text(narration)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

struct ActivityBadge: View {
    let activity: ActivityState
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .cornerRadius(12)
    }
    
    private var color: Color {
        switch activity {
        case .thinking: return .purple
        case .writing: return .blue
        case .reading: return .green
        case .executing: return .orange
        case .debugging: return .red
        case .idle: return .gray
        }
    }
    
    private var text: String {
        switch activity {
        case .thinking: return "Thinking"
        case .writing: return "Writing"
        case .reading: return "Reading"
        case .executing: return "Executing"
        case .debugging: return "Debugging"
        case .idle: return "Idle"
        }
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