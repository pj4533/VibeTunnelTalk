//
//  AuthNetworkClient.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import Foundation
import OSLog

/// Network client for VibeTunnel authentication API calls
class AuthNetworkClient {
    private let logger = AppLogger.auth
    private let baseURL = "http://localhost:4020/api"

    /// Check if VibeTunnel server is running
    func checkServerHealth() async throws -> Bool {
        let url = URL(string: "\(baseURL)/health")!

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response from health check")
            throw AuthError.serverNotRunning
        }

        if httpResponse.statusCode == 200 {
            logger.debug("VibeTunnel server is running")

            // Log health status for debugging
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                logger.verbose("Server health: \(json)")
            }

            return true
        } else {
            logger.error("Server health check failed with status: \(httpResponse.statusCode)")
            throw AuthError.serverNotRunning
        }
    }

    /// Get current system user
    func getCurrentUser() async throws -> String? {
        let url = URL(string: "\(baseURL)/auth/current-user")!

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            logger.warning("Could not get current user")
            return nil
        }

        let userResponse = try JSONDecoder().decode(CurrentUserResponse.self, from: data)
        logger.debug("Current system user: \(userResponse.userId)")
        return userResponse.userId
    }

    /// Check authentication configuration
    func checkAuthConfig() async throws -> AuthConfig {
        let url = URL(string: "\(baseURL)/auth/config")!

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            logger.warning("Could not check auth config, assuming auth required")
            throw AuthError.networkError("Failed to get auth config")
        }

        let config = try JSONDecoder().decode(AuthConfig.self, from: data)
        return config
    }

    /// Authenticate with username and password
    func authenticate(username: String, password: String) async throws -> LoginResponse {
        let url = URL(string: "\(baseURL)/auth/password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = LoginRequest(userId: username, password: password)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

            guard loginResponse.success else {
                logger.error("Authentication failed: Server returned success=false")
                throw AuthError.invalidCredentials
            }

            logger.info("✅ Successfully authenticated as \(loginResponse.userId) using method: \(loginResponse.authMethod ?? "unknown")")
            return loginResponse

        case 401:
            logger.error("Authentication failed: Invalid credentials")
            throw AuthError.invalidCredentials

        default:
            logger.error("Authentication failed with status: \(httpResponse.statusCode)")
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? String {
                throw AuthError.networkError(errorMessage)
            } else {
                throw AuthError.networkError("HTTP \(httpResponse.statusCode)")
            }
        }
    }

    /// Verify token validity
    func verifyToken(_ token: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/auth/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                logger.verbose("Token verification successful")
                return true
            case 401:
                logger.warning("Token verification failed - token invalid")
                return false
            default:
                logger.warning("Token verification failed with status: \(httpResponse.statusCode)")
                return false
            }
        }

        return false
    }
}