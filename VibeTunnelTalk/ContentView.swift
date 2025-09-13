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
    @StateObject private var openAIManager: OpenAIRealtimeManager
    @StateObject private var activityMonitor = SessionActivityMonitor()
    @StateObject private var commandProcessor = VoiceCommandProcessor()
    
    @State private var availableSessions: [String] = []
    @State private var selectedSession: String?
    @State private var isConnecting = false
    @State private var showSettings = false
    @State private var apiKey = ""
    
    @State private var cancelBag = Set<AnyCancellable>()
    
    init() {
        // Load API key from .env file
        let key = ConfigLoader.loadAPIKey() ?? ""
        _openAIManager = StateObject(wrappedValue: OpenAIRealtimeManager(apiKey: key))
        _apiKey = State(initialValue: key)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(
                isConnected: socketManager.isConnected && openAIManager.isConnected,
                showSettings: $showSettings
            )
            
            Divider()
            
            // Main Content
            if apiKey.isEmpty {
                APIKeySetupView(apiKey: $apiKey) {
                    saveAPIKey()
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
            setupBindings()
            refreshSessions()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey)
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
        if !apiKey.isEmpty {
            openAIManager.connect()
        }
        
        isConnecting = false
    }
    
    private func saveAPIKey() {
        // Recreate OpenAI manager with new key
        // Note: In production, you'd save this to Keychain
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
    @Binding var apiKey: String
    let onSave: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("OpenAI API Key Required")
                .font(.headline)
            
            Text("Please enter your OpenAI API key to continue")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)
            
            Button("Save") {
                onSave()
            }
            .disabled(apiKey.isEmpty)
        }
        .padding(30)
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenAI API Key")
                    .font(.headline)
                
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Save") {
                    // Save settings
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
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
