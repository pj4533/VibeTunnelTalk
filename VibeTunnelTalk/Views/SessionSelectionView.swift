import SwiftUI

struct SessionSelectionView: View {
    let sessions: [String]
    @Binding var selectedSession: String?
    let isConnecting: Bool
    let onRefresh: () -> Void
    let onConnect: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Select VibeTunnel Session")
                .font(.headline)
            
            if sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("No VibeTunnel sessions found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Start a session with: vt claude")
                        .font(.caption)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(4)
                }
            } else {
                List(sessions, id: \.self, selection: $selectedSession) { session in
                    HStack {
                        Image(systemName: "terminal")
                        Text(session)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .frame(maxHeight: 200)
            }
            
            HStack(spacing: 15) {
                Button("Refresh") {
                    onRefresh()
                }
                
                Button("Connect") {
                    onConnect()
                }
                .disabled(selectedSession == nil || isConnecting)
                .keyboardShortcut(.return)
            }
            
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}