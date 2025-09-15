import SwiftUI

struct ServerNotRunningView: View {
    var body: some View {
        VStack(spacing: 30) {
            // Error Icon
            Image(systemName: "exclamationmark.server")
                .font(.system(size: 80))
                .foregroundColor(.red)

            // Title
            Text("VibeTunnel Server Not Running")
                .font(.title)
                .fontWeight(.bold)

            // Description
            VStack(spacing: 10) {
                Text("The VibeTunnel server is not running or cannot be reached.")
                    .font(.body)
                    .foregroundColor(.secondary)

                Text("Please make sure:")
                    .font(.headline)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 8) {
                    Label("The VibeTunnel macOS app is running (check menu bar)", systemImage: "1.circle.fill")
                    Label("A VibeTunnel session is active (run 'vt claude' in Terminal)", systemImage: "2.circle.fill")
                    Label("The server is listening on port 4020", systemImage: "3.circle.fill")
                }
                .font(.subheadline)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            // Retry Button
            Button(action: retryConnection) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry Connection")
                }
            }
            .controlSize(.large)

            Spacer()

            // Help Text
            Text("If the problem persists, try restarting the VibeTunnel app")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 600, maxHeight: 500)
    }

    private func retryConnection() {
        // This will trigger a re-check when the view reappears
        if let window = NSApplication.shared.keyWindow {
            window.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.keyWindow?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// Preview
struct ServerNotRunningView_Previews: PreviewProvider {
    static var previews: some View {
        ServerNotRunningView()
    }
}