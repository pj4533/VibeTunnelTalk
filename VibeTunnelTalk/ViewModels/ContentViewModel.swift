//
//  ContentViewModel.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import SwiftUI
import Combine
import OSLog

class ContentViewModel: ObservableObject {
    private let logger = AppLogger.ui

    @Published var availableSessions: [String] = []
    @Published var selectedSession: String?
    @Published var isConnecting = false
    @Published var hasStoredAPIKey = false
    @Published var isAuthenticated = false
    @Published var showServerError = false
    @Published var isCheckingAuth = true

    let socketManager = VibeTunnelSocketManager()
    let openAIManager = OpenAIRealtimeManager()
    let authService = VibeTunnelAuthService()

    private var cancelBag = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    func checkAuthenticationAndServer() {
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

    func onAuthenticationSuccess() {
        isAuthenticated = true
        setupAfterAuth()
    }

    func onAPIKeySaved() {
        if let key = KeychainHelper.loadAPIKey() {
            hasStoredAPIKey = true
            openAIManager.updateAPIKey(key)
        }
    }

    func refreshSessions() {
        availableSessions = socketManager.findAvailableSessions()

        if availableSessions.count == 1 {
            selectedSession = availableSessions.first
        }
    }

    func connectToSession() {
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

    func onSettingsSaved() {
        // Settings saved, reload the API key
        if let key = KeychainHelper.loadAPIKey() {
            openAIManager.updateAPIKey(key)
            hasStoredAPIKey = true
        }
    }

    private func setupAfterAuth() {
        // Check for stored API key
        if let key = KeychainHelper.loadAPIKey(), !key.isEmpty {
            hasStoredAPIKey = true
            openAIManager.updateAPIKey(key)
        }

        setupServices()
        refreshSessions()
    }

    private func setupServices() {
        // Configure authentication
        socketManager.configureAuthentication(with: authService)

        // Configure smart terminal processing
        socketManager.configureSmartProcessing(with: openAIManager)
        logger.info("[CONTENT] ✅ Smart terminal processing configured")
    }

    private func setupBindings() {
        // Monitor authentication status
        authService.$isAuthenticated
            .sink { [weak self] authenticated in
                if !authenticated {
                    // Lost authentication, disconnect
                    self?.socketManager.disconnect()
                    self?.isAuthenticated = false
                }
            }
            .store(in: &cancelBag)
    }
}