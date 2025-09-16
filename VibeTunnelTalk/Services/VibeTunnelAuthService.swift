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

    private var jwtToken: String?
    private var tokenExpirationDate: Date?

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

                // Store token in memory
                self.jwtToken = loginResponse.token
                self.currentUsername = loginResponse.userId

                // Calculate expiration date (24 hours from now)
                self.tokenExpirationDate = Date().addingTimeInterval(86400) // 24 hours

                // Store token in Keychain
                if !KeychainHelper.saveJWTToken(loginResponse.token) {
                    logger.warning("[AUTH] Failed to save JWT token to Keychain")
                }

                // Store password in Keychain for token refresh
                if !KeychainHelper.savePassword(password, for: username) {
                    logger.warning("[AUTH] Failed to save password to Keychain for token refresh")
                }

                // Store username for future sessions
                UserDefaults.standard.set(username, forKey: "lastUsername")

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
            return nil // No token needed
        }

        // Check if we have a valid token
        if let token = jwtToken,
           let expiration = tokenExpirationDate,
           expiration > Date() {
            return token
        }

        // Try to load from Keychain
        if let token = KeychainHelper.loadJWTToken() {
            // We can't verify expiration without decoding the JWT
            // For now, just use it and handle 401 errors
            self.jwtToken = token
            return token
        }

        // No valid token available
        isAuthenticated = false
        throw AuthError.tokenExpired
    }

    /// Attempt to refresh the authentication token
    /// Returns true if refresh was successful
    @MainActor
    func refreshToken() async -> Bool {
        logger.info("[AUTH] Attempting to refresh authentication token...")

        // Try to load saved credentials and re-authenticate
        guard let savedToken = KeychainHelper.loadJWTToken(),
              let savedUsername = UserDefaults.standard.string(forKey: "lastUsername") else {
            logger.warning("[AUTH] No saved credentials available for token refresh")
            return false
        }

        // Try to load saved password from Keychain if available
        if let password = KeychainHelper.loadPassword(for: savedUsername) {
            do {
                try await authenticate(username: savedUsername, password: password)
                logger.info("[AUTH] Successfully refreshed authentication token")
                return true
            } catch {
                logger.error("[AUTH] Failed to refresh token: \(error.localizedDescription)")
            }
        }

        // If we can't refresh automatically, mark as not authenticated
        // The user will need to log in manually
        return false
    }

    /// Check if token is expired
    func isTokenExpired() -> Bool {
        guard let expiration = tokenExpirationDate else {
            return true
        }
        return expiration <= Date()
    }

    /// Clear authentication
    func logout() {
        jwtToken = nil
        tokenExpirationDate = nil
        currentUsername = nil
        isAuthenticated = false

        // Clear from Keychain
        KeychainHelper.deleteJWTToken()

        logger.info("[AUTH] User logged out")
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

        // Try to load saved token
        if let token = KeychainHelper.loadJWTToken() {
            self.jwtToken = token
            self.currentUsername = UserDefaults.standard.string(forKey: "lastUsername")

            // We can't verify without decoding JWT, so assume it's valid
            // and handle 401 errors when they occur
            isAuthenticated = true

            logger.info("[AUTH] Loaded saved authentication for user: \(self.currentUsername ?? "unknown")")
        }
    }
}

// Extend KeychainHelper to handle JWT tokens and passwords
extension KeychainHelper {
    private static let jwtTokenKey = "VibeTunnelJWTToken"
    private static let passwordKeyPrefix = "VibeTunnelPassword_"

    static func saveJWTToken(_ token: String) -> Bool {
        let data = token.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: jwtTokenKey,
            kSecValueData as String: data
        ]

        // Delete any existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadJWTToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: jwtTokenKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    static func deleteJWTToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: jwtTokenKey
        ]

        SecItemDelete(query as CFDictionary)
    }

    // Password management methods
    static func savePassword(_ password: String, for username: String) -> Bool {
        let data = password.data(using: .utf8)!
        let account = "\(passwordKeyPrefix)\(username)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        // Delete any existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadPassword(for username: String) -> String? {
        let account = "\(passwordKeyPrefix)\(username)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        return password
    }

    static func deletePassword(for username: String) {
        let account = "\(passwordKeyPrefix)\(username)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}