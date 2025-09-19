//
//  AuthError.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import Foundation

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