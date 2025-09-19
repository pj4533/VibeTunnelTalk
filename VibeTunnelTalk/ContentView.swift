//
//  ContentView.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var showSettings = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(
                isConnected: viewModel.socketManager.isConnected && viewModel.openAIManager.isConnected,
                showSettings: $showSettings
            )
            
            Divider()
            
            // Main Content
            if viewModel.isCheckingAuth {
                // Show loading while checking authentication
                AuthCheckingView()
            } else if !viewModel.authService.isServerRunning && viewModel.showServerError {
                // Server not running error
                ServerNotRunningView()
            } else if !viewModel.isAuthenticated {
                // Authentication required
                LoginView(authService: viewModel.authService) {
                    viewModel.onAuthenticationSuccess()
                }
            } else if !viewModel.hasStoredAPIKey {
                APIKeySetupView {
                    viewModel.onAPIKeySaved()
                }
            } else if !viewModel.socketManager.isConnected {
                SessionSelectionView(
                    sessions: viewModel.availableSessions,
                    selectedSession: $viewModel.selectedSession,
                    isConnecting: viewModel.isConnecting,
                    onRefresh: viewModel.refreshSessions,
                    onConnect: viewModel.connectToSession
                )
            } else {
                ConnectedView(
                    socketManager: viewModel.socketManager,
                    openAIManager: viewModel.openAIManager
                )
            }
            
            // Status Bar
            StatusBarView(
                socketConnected: viewModel.socketManager.isConnected,
                openAIConnected: viewModel.openAIManager.isConnected,
                isProcessing: false // We could track this from processor if needed
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            viewModel.checkAuthenticationAndServer()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                viewModel.onSettingsSaved()
            }
        }
    }
}


#Preview {
    ContentView()
}
