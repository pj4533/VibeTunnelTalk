import SwiftUI
import OSLog

struct LoginView: View {
    @ObservedObject var authService: VibeTunnelAuthService
    let onAuthenticated: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var isAuthenticating = false
    @State private var showError = false
    @State private var errorMessage = ""

    private let logger = AppLogger.ui

    var body: some View {
        VStack(spacing: 30) {
            // Logo and Title
            VStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Text("VibeTunnel Authentication")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Please log in with your macOS credentials")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Login Form
            VStack(spacing: 15) {
                // Username Field
                HStack {
                    Image(systemName: "person.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isAuthenticating)
                }
                .frame(maxWidth: 300)

                // Password Field
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isAuthenticating)
                        .onSubmit {
                            authenticate()
                        }
                }
                .frame(maxWidth: 300)

                // Login Button
                Button(action: authenticate) {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text("Log In")
                    }
                    .frame(width: 120)
                }
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(username.isEmpty || password.isEmpty || isAuthenticating)
            }

            // Error Message
            if showError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: 350)
            }

            // Server Status
            if !authService.isServerRunning {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("VibeTunnel Server Not Running")
                            .font(.headline)
                            .foregroundColor(.orange)
                    }

                    Text("Please start the VibeTunnel macOS app before continuing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()

            // Help Text
            VStack(spacing: 5) {
                Text("Need help?")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Use the same credentials you use to log into your Mac")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 550)
        .onAppear {
            checkServerAndAuth()
            fetchCurrentUser()
        }
    }

    private func authenticate() {
        guard !username.isEmpty && !password.isEmpty else { return }

        isAuthenticating = true
        showError = false

        Task {
            do {
                try await authService.authenticate(username: username, password: password)

                await MainActor.run {
                    isAuthenticating = false
                    // Clear password for security
                    password = ""
                    onAuthenticated()
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    showError = true
                    errorMessage = error.localizedDescription

                    // Log the error
                    logger.error("[LOGIN] Authentication failed: \(error.localizedDescription)")

                    // Clear password on error
                    password = ""
                }
            }
        }
    }

    private func fetchCurrentUser() {
        Task {
            if let currentUser = await authService.getCurrentUser() {
                await MainActor.run {
                    if username.isEmpty {
                        username = currentUser
                    }
                }
            } else {
                // Fallback to current macOS username
                await MainActor.run {
                    if username.isEmpty {
                        username = NSUserName()
                    }
                }
            }
        }
    }

    private func checkServerAndAuth() {
        Task {
            // Check server status
            let serverRunning = await authService.checkServerStatus()

            if serverRunning {
                // Check if authentication is required
                let authRequired = await authService.checkAuthRequired()

                if !authRequired {
                    // No auth required, proceed
                    await MainActor.run {
                        onAuthenticated()
                    }
                } else {
                    // Try to load saved authentication
                    await authService.loadSavedAuthentication()

                    if authService.isAuthenticated {
                        await MainActor.run {
                            onAuthenticated()
                        }
                    }
                }
            }
        }
    }
}

// Preview
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView(authService: VibeTunnelAuthService()) {
            print("Authenticated!")
        }
    }
}