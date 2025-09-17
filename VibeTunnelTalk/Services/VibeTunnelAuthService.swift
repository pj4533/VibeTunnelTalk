import Foundation
import OSLog
import Combine
import SwiftUI

/// Service for handling VibeTunnel authentication
class VibeTunnelAuthService: ObservableObject {
    private let logger = AppLogger.auth

    @Published var isAuthenticated = false
    @Published var isServerRunning = false
    @Published var authError: AuthError?
    @Published var currentUsername: String?

    // Keep JWT token and metadata in memory only (matching iOS pattern)
    private var jwtToken: String?
    private var tokenLoginTime: Date?
    private var storedUsername: String?
    private var storedPassword: String?

    enum AuthError: LocalizedError {
        case serverNotRunning
        case invalidCredentials
        case tokenExpired
        case networkError(String)
        case authNotRequired

        var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "VibeTunnel server is not running. Please start the VibeTunnel macOS app."
            case .invalidCredentials:
                return "Invalid username or password. Please use your macOS login credentials."
            case .tokenExpired:
                return "Authentication token has expired. Please log in again."
            case .networkError(let message):
                return "Network error: \(message)"
            case .authNotRequired:
                return "Authentication is not required (server running with --no-auth)"
            }
        }
    }

    struct AuthConfig: Codable {
        let noAuth: Bool
        let enableSSHKeys: Bool?
        let disallowUserPassword: Bool?
    }

    struct LoginRequest: Codable {
        let userId: String
        let password: String
    }

    struct LoginResponse: Codable {
        let success: Bool
        let token: String
        let userId: String
        let authMethod: String?
    }

    struct CurrentUserResponse: Codable {
        let userId: String
    }

    /// Check if VibeTunnel server is running
    @MainActor
    func checkServerStatus() async -> Bool {
        logger.info("[AUTH] Checking VibeTunnel server status...")

        let url = URL(string: "http://localhost:4020/api/health")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("[AUTH] Invalid response from health check")
                isServerRunning = false
                authError = .serverNotRunning
                return false
            }

            if httpResponse.statusCode == 200 {
                logger.info("[AUTH] VibeTunnel server is running")
                isServerRunning = true
                authError = nil

                // Log health status for debugging
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    logger.debug("[AUTH] Server health: \(json)")
                }

                return true
            } else {
                logger.error("[AUTH] Server health check failed with status: \(httpResponse.statusCode)")
                isServerRunning = false
                authError = .serverNotRunning
                return false
            }
        } catch {
            logger.error("[AUTH] Failed to connect to VibeTunnel server: \(error.localizedDescription)")
            isServerRunning = false
            authError = .serverNotRunning
            return false
        }
    }

    /// Get current system user
    @MainActor
    func getCurrentUser() async -> String? {
        logger.info("[AUTH] Getting current system user...")

        let url = URL(string: "http://localhost:4020/api/auth/current-user")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.warning("[AUTH] Could not get current user")
                return nil
            }

            let userResponse = try JSONDecoder().decode(CurrentUserResponse.self, from: data)
            logger.info("[AUTH] Current system user: \(userResponse.userId)")
            return userResponse.userId
        } catch {
            logger.error("[AUTH] Failed to get current user: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if authentication is required
    @MainActor
    func checkAuthRequired() async -> Bool {
        logger.info("[AUTH] Checking if authentication is required...")

        let url = URL(string: "http://localhost:4020/api/auth/config")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // If we can't check, assume auth is required
                logger.warning("[AUTH] Could not check auth config, assuming auth required")
                return true
            }

            let config = try JSONDecoder().decode(AuthConfig.self, from: data)

            if config.noAuth {
                logger.info("[AUTH] Server running with --no-auth, authentication not required")
                isAuthenticated = true
                authError = .authNotRequired
                return false
            }

            logger.info("[AUTH] Authentication is required")
            return true
        } catch {
            logger.error("[AUTH] Failed to check auth config: \(error.localizedDescription)")
            // Assume auth is required if we can't check
            return true
        }
    }

    /// Authenticate with username and password
    @MainActor
    func authenticate(username: String, password: String) async throws {
        logger.info("[AUTH] Attempting to authenticate user: \(username)")

        // First check if server is running
        guard await checkServerStatus() else {
            throw AuthError.serverNotRunning
        }

        // Check if authentication is required
        if !(await checkAuthRequired()) {
            // No auth required, we're done
            return
        }

        let url = URL(string: "http://localhost:4020/api/auth/password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = LoginRequest(userId: username, password: password)
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.networkError("Invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

                guard loginResponse.success else {
                    logger.error("[AUTH] Authentication failed: Server returned success=false")
                    throw AuthError.invalidCredentials
                }

                // Store token in memory only (matching iOS pattern)
                self.jwtToken = loginResponse.token
                self.currentUsername = loginResponse.userId
                self.tokenLoginTime = Date()

                logger.info("[AUTH] Received JWT token: \(loginResponse.token.prefix(20))...")

                // Store credentials in Keychain (matching iOS pattern)
                // This allows auto-reauthentication when token expires
                if KeychainHelper.saveVibeTunnelCredentials(username: username, password: password) {
                    logger.info("[AUTH] Credentials saved to Keychain successfully")
                    self.storedUsername = username
                    self.storedPassword = password
                } else {
                    logger.error("[AUTH] Failed to save credentials to Keychain")
                }

                isAuthenticated = true
                authError = nil

                logger.info("[AUTH] Successfully authenticated as \(loginResponse.userId) using method: \(loginResponse.authMethod ?? "unknown")")

            case 401:
                logger.error("[AUTH] Authentication failed: Invalid credentials")
                throw AuthError.invalidCredentials

            default:
                logger.error("[AUTH] Authentication failed with status: \(httpResponse.statusCode)")
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = errorData["error"] as? String {
                    throw AuthError.networkError(errorMessage)
                } else {
                    throw AuthError.networkError("HTTP \(httpResponse.statusCode)")
                }
            }
        } catch let error as AuthError {
            authError = error
            throw error
        } catch {
            logger.error("[AUTH] Authentication failed: \(error.localizedDescription)")
            let authErr = AuthError.networkError(error.localizedDescription)
            authError = authErr
            throw authErr
        }
    }

    /// Get current JWT token, refreshing if needed
    func getToken() async throws -> String? {
        // Check if authentication is required
        if !(await checkAuthRequired()) {
            logger.debug("[AUTH] No authentication required, returning nil token")
            return nil // No token needed
        }

        // Check if we have a valid token in memory (matching iOS: 24 hour expiry)
        if let token = jwtToken,
           let loginTime = tokenLoginTime {
            let tokenAge = Date().timeIntervalSince(loginTime)
            if tokenAge < 24 * 60 * 60 { // 24 hours
                logger.debug("[AUTH] Using valid token from memory (age: \(tokenAge) seconds)")
                return token
            } else {
                logger.info("[AUTH] Token expired (age: \(tokenAge) seconds), attempting re-authentication")
            }
        }

        // Try to re-authenticate with stored credentials (matching iOS pattern)
        if let credentials = KeychainHelper.loadVibeTunnelCredentials() {
            logger.info("[AUTH] Attempting auto-reauthentication with stored credentials")
            do {
                try await authenticate(username: credentials.username, password: credentials.password)
                return jwtToken
            } catch {
                logger.error("[AUTH] Auto-reauthentication failed: \(error.localizedDescription)")
                // Clear invalid credentials
                KeychainHelper.deleteVibeTunnelCredentials()
                self.storedUsername = nil
                self.storedPassword = nil
                throw AuthError.tokenExpired
            }
        }

        // No valid token or credentials available
        logger.warning("[AUTH] No valid token or credentials available")
        isAuthenticated = false
        throw AuthError.tokenExpired
    }

    /// Attempt to refresh the authentication token
    /// Returns true if refresh was successful
    @MainActor
    func refreshToken() async -> Bool {
        logger.info("[AUTH] Attempting to refresh token")

        // Try to re-authenticate with stored credentials (matching iOS pattern)
        if let credentials = KeychainHelper.loadVibeTunnelCredentials() {
            do {
                try await authenticate(username: credentials.username, password: credentials.password)
                logger.info("[AUTH] Token refresh successful")
                return true
            } catch {
                logger.error("[AUTH] Token refresh failed: \(error.localizedDescription)")
                return false
            }
        }

        logger.warning("[AUTH] No stored credentials for token refresh")
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
        KeychainHelper.deleteVibeTunnelCredentials()

        logger.info("[AUTH] User logged out and credentials cleared")
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
            logger.info("[AUTH] Found saved credentials for user: \(credentials.username)")

            // Store credentials in memory for potential re-auth
            self.storedUsername = credentials.username
            self.storedPassword = credentials.password

            do {
                // Attempt authentication with stored credentials
                try await authenticate(username: credentials.username, password: credentials.password)
                logger.info("[AUTH] Successfully authenticated with saved credentials")
            } catch {
                logger.error("[AUTH] Failed to authenticate with saved credentials: \(error.localizedDescription)")
                // Clear invalid credentials
                KeychainHelper.deleteVibeTunnelCredentials()
                self.storedUsername = nil
                self.storedPassword = nil
            }
        } else {
            logger.info("[AUTH] No saved credentials found")
        }
    }

    /// Verify if current token is still valid (matching iOS pattern)
    @MainActor
    func verifyToken() async -> Bool {
        guard let token = jwtToken else {
            logger.debug("[AUTH] No token to verify")
            return false
        }

        // First check token age (matching iOS: 24 hour expiry)
        if let loginTime = tokenLoginTime {
            let tokenAge = Date().timeIntervalSince(loginTime)
            if tokenAge >= 24 * 60 * 60 {
                logger.info("[AUTH] Token expired by age (\(tokenAge) seconds)")
                return false
            }
        }

        let url = URL(string: "http://localhost:4020/api/auth/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.debug("[AUTH] Token verification successful")
                    return true
                } else if httpResponse.statusCode == 401 {
                    logger.warning("[AUTH] Token verification failed - token invalid")
                    // Try to re-authenticate with stored credentials
                    if await refreshToken() {
                        logger.info("[AUTH] Successfully refreshed token after verification failure")
                        return true
                    }
                    return false
                } else {
                    logger.warning("[AUTH] Token verification failed with status: \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            logger.error("[AUTH] Token verification request failed: \(error.localizedDescription)")
        }

        return false
    }
}