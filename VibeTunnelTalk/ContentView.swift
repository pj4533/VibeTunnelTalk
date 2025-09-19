//
//  ContentView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI
import Combine
import OSLog

struct ContentView: View {
    private let logger = AppLogger.ui
    @StateObject private var socketManager = VibeTunnelSocketManager()
    @StateObject private var openAIManager = OpenAIRealtimeManager()
    @StateObject private var authService = VibeTunnelAuthService()

    @State private var availableSessions: [String] = []
    @State private var selectedSession: String?
    @State private var isConnecting = false
    @State private var showSettings = false
    @State private var hasStoredAPIKey = false
    @State private var isAuthenticated = false
    @State private var showServerError = false
    @State private var isCheckingAuth = true  // New state for loading

    @State private var cancelBag = Set<AnyCancellable>()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(
                isConnected: socketManager.isConnected && openAIManager.isConnected,
                showSettings: $showSettings
            )
            
            Divider()
            
            // Main Content
            if isCheckingAuth {
                // Show loading while checking authentication
                AuthCheckingView()
            } else if !authService.isServerRunning && showServerError {
                // Server not running error
                ServerNotRunningView()
            } else if !isAuthenticated {
                // Authentication required
                LoginView(authService: authService) {
                    // Successfully authenticated
                    isAuthenticated = true
                    setupAfterAuth()
                }
            } else if !hasStoredAPIKey {
                APIKeySetupView {
                    // API key was saved successfully
                    if let key = KeychainHelper.loadAPIKey() {
                        hasStoredAPIKey = true
                        openAIManager.updateAPIKey(key)
                    }
                }
            } else if !socketManager.isConnected {
                SessionSelectionView(
                    sessions: availableSessions,
                    selectedSession: $selectedSession,
                    isConnecting: isConnecting,
                    onRefresh: refreshSessions,
                    onConnect: connectToSession
                )
            } else {
                ConnectedView(
                    socketManager: socketManager,
                    openAIManager: openAIManager
                )
            }
            
            // Status Bar
            StatusBarView(
                socketConnected: socketManager.isConnected,
                openAIConnected: openAIManager.isConnected,
                isProcessing: false // We could track this from processor if needed
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            checkAuthenticationAndServer()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                // Settings saved, reload the API key
                if let key = KeychainHelper.loadAPIKey() {
                    openAIManager.updateAPIKey(key)
                    hasStoredAPIKey = true
                }
            }
        }
    }
    
    private func checkAuthenticationAndServer() {
        Task {
            // Start checking
            await MainActor.run {
                isCheckingAuth = true
            }

            // Check server status
            let serverRunning = await authService.checkServerStatus()

            if !serverRunning {
                await MainActor.run {
                    showServerError = true
                    isCheckingAuth = false
                }
                return
            }

            // Check if authentication is required
            let authRequired = await authService.checkAuthRequired()

            if !authRequired {
                // No auth required
                await MainActor.run {
                    isAuthenticated = true
                    setupAfterAuth()
                    isCheckingAuth = false
                }
            } else {
                // Try to load saved authentication
                await authService.loadSavedAuthentication()

                await MainActor.run {
                    if authService.isAuthenticated {
                        isAuthenticated = true
                        setupAfterAuth()
                    }
                    isCheckingAuth = false
                }
            }
        }
    }

    private func setupAfterAuth() {
        // Check for stored API key
        if let key = KeychainHelper.loadAPIKey(), !key.isEmpty {
            hasStoredAPIKey = true
            openAIManager.updateAPIKey(key)
        }

        setupBindings()
        refreshSessions()
    }

    private func setupBindings() {
        // Configure authentication
        socketManager.configureAuthentication(with: authService)

        // Configure smart terminal processing
        socketManager.configureSmartProcessing(with: openAIManager)
        logger.info("[CONTENT] ✅ Smart terminal processing configured")


        // Monitor authentication status
        authService.$isAuthenticated
            .sink { authenticated in
                if !authenticated {
                    // Lost authentication, disconnect
                    socketManager.disconnect()
                    self.isAuthenticated = false
                }
            }
            .store(in: &cancelBag)
    }
    
    private func refreshSessions() {
        availableSessions = socketManager.findAvailableSessions()
        
        if availableSessions.count == 1 {
            selectedSession = availableSessions.first
        }
    }
    
    private func connectToSession() {
        guard let session = selectedSession else {
            return
        }

        isConnecting = true

        // Connect to VibeTunnel session
        socketManager.connect(to: session)

        // Connect to OpenAI
        if hasStoredAPIKey {
            openAIManager.connect()
        }

        isConnecting = false
    }
}

// MARK: - Subviews

struct HeaderView: View {
    let isConnected: Bool
    @Binding var showSettings: Bool
    
    var body: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundColor(isConnected ? .green : .gray)
            
            Text("VibeTunnelTalk")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

struct APIKeySetupView: View {
    let onSave: () -> Void
    @State private var apiKeyText = ""
    @State private var showingSaveError = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("OpenAI API Key Required")
                .font(.headline)
            
            Text("Please enter your OpenAI API key to continue")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            SecureField("API Key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)
            
            if showingSaveError {
                Text("Failed to save API key to Keychain")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button("Save") {
                if KeychainHelper.saveAPIKey(apiKeyText) {
                    onSave()
                } else {
                    showingSaveError = true
                }
            }
            .disabled(apiKeyText.isEmpty)
            .keyboardShortcut(.return)
        }
        .padding(30)
    }
}

// SettingsView moved to Views/SettingsView.swift

struct StatusBarView: View {
    let socketConnected: Bool
    let openAIConnected: Bool
    let isProcessing: Bool

    var body: some View {
        HStack {
            // Connection Status
            HStack(spacing: 15) {
                StatusIndicator(
                    label: "VibeTunnel",
                    isConnected: socketConnected
                )

                StatusIndicator(
                    label: "OpenAI",
                    isConnected: openAIConnected
                )
            }

            Spacer()

            // Processing Status
            if isProcessing {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Processing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
    }
}

struct StatusIndicator: View {
    let label: String
    let isConnected: Bool
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
