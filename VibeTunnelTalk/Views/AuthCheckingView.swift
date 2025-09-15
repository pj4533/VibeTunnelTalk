import SwiftUI

struct AuthCheckingView: View {
    @State private var animationAmount = 1.0

    var body: some View {
        VStack(spacing: 30) {
            // Animated Icon
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
                .scaleEffect(animationAmount)
                .animation(
                    Animation.easeInOut(duration: 1.0)
                        .repeatForever(autoreverses: true),
                    value: animationAmount
                )
                .onAppear {
                    animationAmount = 1.2
                }

            // Loading Text
            VStack(spacing: 10) {
                Text("Checking Authentication")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Connecting to VibeTunnel server...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Progress Indicator
            ProgressView()
                .scaleEffect(1.2)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Preview
struct AuthCheckingView_Previews: PreviewProvider {
    static var previews: some View {
        AuthCheckingView()
    }
}