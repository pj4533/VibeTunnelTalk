//
//  AuthModels.swift
//  VibeTunnelTalk
//
//  Created by PJ Gray on 9/12/25.
//

import Foundation

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