//
//  ContentView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var socketManager = VibeTunnelSocketManager()
    @StateObject private var openAIManager = OpenAIRealtimeManager()
    @StateObject private var activityMonitor = SessionActivityMonitor()
    @StateObject private var commandProcessor = VoiceCommandProcessor()
    
    @State private var availableSessions: [String] = []
    @State private var selectedSession: String?
    @State private var isConnecting = false
    @State private var showSettings = false
    @State private var hasStoredAPIKey = false
    
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
            if !hasStoredAPIKey {
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
                    openAIManager: openAIManager,
                    activityMonitor: activityMonitor
                )
            }
            
            // Status Bar
            StatusBarView(
                socketConnected: socketManager.isConnected,
                openAIConnected: openAIManager.isConnected,
                activity: activityMonitor.currentActivity
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // Check for stored API key
            if let key = KeychainHelper.loadAPIKey(), !key.isEmpty {
                hasStoredAPIKey = true
                openAIManager.updateAPIKey(key)
            }
            setupBindings()
            refreshSessions()
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
    
    private func setupBindings() {
        // Connect terminal output to activity monitor
        socketManager.terminalOutput
            .sink { output in
                activityMonitor.processOutput(output)
            }
            .store(in: &cancelBag)
        
        // Connect activity narrations to OpenAI
        NotificationCenter.default.publisher(for: .activityNarrationReady)
            .compactMap { $0.userInfo?["narration"] as? String }
            .sink { narration in
                openAIManager.sendTerminalContext(narration)
            }
            .store(in: &cancelBag)
        
        // Connect OpenAI function calls to command processor
        openAIManager.functionCallRequested
            .sink { functionCall in
                commandProcessor.processFunctionCall(functionCall) { command in
                    socketManager.sendInput(command)
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
        guard let session = selectedSession else { return }
        
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

struct SettingsView: View {
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var apiKeyText = ""
    @State private var showingSaveError = false
    
    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        // Load current key from Keychain to show in field
        _apiKeyText = State(initialValue: KeychainHelper.loadAPIKey() ?? "")
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenAI API Key")
                    .font(.headline)
                
                SecureField("API Key", text: $apiKeyText)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if showingSaveError {
                Text("Failed to save API key to Keychain")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Save") {
                    // Save to Keychain
                    if KeychainHelper.saveAPIKey(apiKeyText) {
                        onSave()
                        dismiss()
                    } else {
                        showingSaveError = true
                    }
                }
                .keyboardShortcut(.return)
                .disabled(apiKeyText.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: showingSaveError ? 220 : 200)
    }
}

struct StatusBarView: View {
    let socketConnected: Bool
    let openAIConnected: Bool
    let activity: ActivityState
    
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
            
            // Activity Status
            Text(activity == .idle ? "Ready" : "Active")
                .font(.caption)
                .foregroundColor(.secondary)
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
