import SwiftUI

struct VoiceActivityView: View {
    let isListening: Bool
    let isSpeaking: Bool
    let onToggleListening: () -> Void
    
    @State private var animationAmount = 1.0
    
    var body: some View {
        VStack(spacing: 20) {
            // Waveform visualization
            HStack(spacing: 4) {
                ForEach(0..<20) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(waveformColor)
                        .frame(width: 4, height: waveformHeight(for: index))
                        .animation(
                            .easeInOut(duration: 0.3)
                                .delay(Double(index) * 0.02),
                            value: isListening || isSpeaking
                        )
                }
            }
            .frame(height: 60)
            
            // Control Button
            Button(action: onToggleListening) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 80, height: 80)
                    
                    if isListening {
                        // Animated listening indicator
                        Circle()
                            .stroke(Color.blue, lineWidth: 2)
                            .frame(width: 80, height: 80)
                            .scaleEffect(animationAmount)
                            .opacity(2 - animationAmount)
                            .animation(
                                .easeOut(duration: 1)
                                    .repeatForever(autoreverses: false),
                                value: animationAmount
                            )
                    }
                    
                    Image(systemName: iconName)
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            
            // Status Text
            Text(statusText)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 30)
        .onAppear {
            if isListening {
                animationAmount = 2.0
            }
        }
    }
    
    private var waveformColor: Color {
        if isSpeaking {
            return .green
        } else if isListening {
            return .blue
        } else {
            return .gray
        }
    }
    
    private func waveformHeight(for index: Int) -> CGFloat {
        if isSpeaking || isListening {
            let base: CGFloat = 20
            let variation = CGFloat.random(in: 0.3...1.0)
            return base * variation
        } else {
            return 10
        }
    }
    
    private var buttonColor: Color {
        if isSpeaking {
            return .green
        } else if isListening {
            return .blue
        } else {
            return .gray
        }
    }
    
    private var iconName: String {
        if isSpeaking {
            return "speaker.wave.3.fill"
        } else if isListening {
            return "mic.fill"
        } else {
            return "mic"
        }
    }
    
    private var statusText: String {
        if isSpeaking {
            return "Speaking..."
        } else if isListening {
            return "Listening..."
        } else {
            return "Press to speak"
        }
    }
}