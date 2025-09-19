import Foundation
import OSLog
import Combine
import SwiftUI

/// Service for managing VibeTunnel authentication state
class VibeTunnelAuthService: ObservableObject {
    private let logger = AppLogger.auth
    private let networkClient = AuthNetworkClient()

    @Published var isAuthenticated = false
    @Published var isServerRunning = false
    @Published var authError: AuthError?
    @Published var currentUsername: String?

    // Keep JWT token and metadata in memory only (matching iOS pattern)
    private var jwtToken: String?
    private var tokenLoginTime: Date?
    private var storedUsername: String?
    private var storedPassword: String?

    /// Check if VibeTunnel server is running
    @MainActor
    func checkServerStatus() async -> Bool {
        logger.debug("Checking VibeTunnel server status...")

        do {
            let isRunning = try await networkClient.checkServerHealth()
            isServerRunning = isRunning
            if isRunning {
                authError = nil
            } else {
                authError = .serverNotRunning
            }
            return isRunning
        } catch {
            logger.error("Failed to connect to VibeTunnel server: \(error.localizedDescription)")
            isServerRunning = false
            authError = .serverNotRunning
            return false
        }
    }

    /// Get current system user
    @MainActor
    func getCurrentUser() async -> String? {
        logger.debug("Getting current system user...")

        do {
            return try await networkClient.getCurrentUser()
        } catch {
            logger.error("Failed to get current user: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if authentication is required
    @MainActor
    func checkAuthRequired() async -> Bool {
        logger.debug("Checking if authentication is required...")

        do {
            let config = try await networkClient.checkAuthConfig()

            if config.noAuth {
                logger.debug("Server running with --no-auth, authentication not required")
                isAuthenticated = true
                authError = .authNotRequired
                return false
            }

            logger.debug("Authentication is required")
            return true
        } catch {
            logger.error("Failed to check auth config: \(error.localizedDescription)")
            // Assume auth is required if we can't check
            return true
        }
    }

    /// Authenticate with username and password
    @MainActor
    func authenticate(username: String, password: String) async throws {
        logger.debug("Attempting to authenticate user: \(username)")

        // First check if server is running
        guard await checkServerStatus() else {
            throw AuthError.serverNotRunning
        }

        // Check if authentication is required
        if !(await checkAuthRequired()) {
            // No auth required, we're done
            return
        }

        do {
            let loginResponse = try await networkClient.authenticate(username: username, password: password)

            // Store token in memory only (matching iOS pattern)
            self.jwtToken = loginResponse.token
            self.currentUsername = loginResponse.userId
            self.tokenLoginTime = Date()

            logger.debug("Received JWT token: \(loginResponse.token.prefix(20))...")

            // Store credentials in Keychain (matching iOS pattern)
            // This allows auto-reauthentication when token expires
            if KeychainHelper.saveVibeTunnelCredentials(username: username, password: password) {
                logger.debug("Credentials saved to Keychain successfully")
                self.storedUsername = username
                self.storedPassword = password
            } else {
                logger.error("Failed to save credentials to Keychain")
            }

            isAuthenticated = true
            authError = nil

        } catch let error as AuthError {
            authError = error
            throw error
        } catch {
            logger.error("Authentication failed: \(error.localizedDescription)")
            let authErr = AuthError.networkError(error.localizedDescription)
            authError = authErr
            throw authErr
        }
    }

    /// Get current JWT token, refreshing if needed
    func getToken() async throws -> String? {
        // Check if authentication is required
        if !(await checkAuthRequired()) {
            logger.verbose("No authentication required, returning nil token")
            return nil // No token needed
        }

        // Check if we have a valid token in memory (matching iOS: 24 hour expiry)
        if let token = jwtToken,
           let loginTime = tokenLoginTime {
            let tokenAge = Date().timeIntervalSince(loginTime)
            if tokenAge < 24 * 60 * 60 { // 24 hours
                logger.verbose("Using valid token from memory (age: \(tokenAge) seconds)")
                return token
            } else {
                logger.debug("Token expired (age: \(tokenAge) seconds), attempting re-authentication")
            }
        }

        // Try to re-authenticate with stored credentials (matching iOS pattern)
        if let credentials = KeychainHelper.loadVibeTunnelCredentials() {
            logger.debug("Attempting auto-reauthentication with stored credentials")
            do {
                try await authenticate(username: credentials.username, password: credentials.password)
                return jwtToken
            } catch {
                logger.error("Auto-reauthentication failed: \(error.localizedDescription)")
                // Clear invalid credentials
                _ = KeychainHelper.deleteVibeTunnelCredentials()
                self.storedUsername = nil
                self.storedPassword = nil
                throw AuthError.tokenExpired
            }
        }

        // No valid token or credentials available
        logger.warning("No valid token or credentials available")
        isAuthenticated = false
        throw AuthError.tokenExpired
    }

    /// Attempt to refresh the authentication token
    /// Returns true if refresh was successful
    @MainActor
    func refreshToken() async -> Bool {
        logger.debug("Attempting to refresh token")

        // Try to re-authenticate with stored credentials (matching iOS pattern)
        if let credentials = KeychainHelper.loadVibeTunnelCredentials() {
            do {
                try await authenticate(username: credentials.username, password: credentials.password)
                logger.debug("Token refresh successful")
                return true
            } catch {
                logger.error("Token refresh failed: \(error.localizedDescription)")
                return false
            }
        }

        logger.warning("No stored credentials for token refresh")
        return false
    }

    /// Check if token is expired
    func isTokenExpired() -> Bool {
        guard let loginTime = tokenLoginTime else {
            return true
        }
        // Token expires after 24 hours (matching iOS pattern)
        let tokenAge = Date().timeIntervalSince(loginTime)
        return tokenAge >= 24 * 60 * 60
    }

    /// Clear authentication
    func logout() {
        // Clear in-memory tokens
        jwtToken = nil
        tokenLoginTime = nil
        currentUsername = nil
        storedUsername = nil
        storedPassword = nil
        isAuthenticated = false

        // Clear stored credentials from Keychain (matching iOS pattern)
        _ = KeychainHelper.deleteVibeTunnelCredentials()

        logger.info("🚪 User logged out and credentials cleared")
    }

    /// Load saved authentication if available
    @MainActor
    func loadSavedAuthentication() async {
        // Check server status first
        guard await checkServerStatus() else {
            return
        }

        // Check if authentication is required
        if !(await checkAuthRequired()) {
            // No auth required
            return
        }

        // Try to authenticate with saved credentials (matching iOS pattern)
        if let credentials = KeychainHelper.loadVibeTunnelCredentials() {
            logger.debug("Found saved credentials for user: \(credentials.username)")

            // Store credentials in memory for potential re-auth
            self.storedUsername = credentials.username
            self.storedPassword = credentials.password

            do {
                // Attempt authentication with stored credentials
                try await authenticate(username: credentials.username, password: credentials.password)
                logger.info("✅ Successfully authenticated with saved credentials")
            } catch {
                logger.error("Failed to authenticate with saved credentials: \(error.localizedDescription)")
                // Clear invalid credentials
                _ = KeychainHelper.deleteVibeTunnelCredentials()
                self.storedUsername = nil
                self.storedPassword = nil
            }
        } else {
            logger.debug("No saved credentials found")
        }
    }

    /// Verify if current token is still valid (matching iOS pattern)
    @MainActor
    func verifyToken() async -> Bool {
        guard let token = jwtToken else {
            logger.verbose("No token to verify")
            return false
        }

        // First check token age (matching iOS: 24 hour expiry)
        if let loginTime = tokenLoginTime {
            let tokenAge = Date().timeIntervalSince(loginTime)
            if tokenAge >= 24 * 60 * 60 {
                logger.debug("Token expired by age (\(tokenAge) seconds)")
                return false
            }
        }

        do {
            let isValid = try await networkClient.verifyToken(token)
            if !isValid {
                // Try to re-authenticate with stored credentials
                if await refreshToken() {
                    logger.debug("Successfully refreshed token after verification failure")
                    return true
                }
            }
            return isValid
        } catch {
            logger.error("Token verification request failed: \(error.localizedDescription)")
            return false
        }
    }
}