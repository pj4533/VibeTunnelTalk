import Foundation
import Security
import OSLog

class KeychainHelper {
    private static let service = "com.vibetunneltalk"
    private static let openAIAccount = "OpenAI-API-Key"
    private static let vibeTunnelService = "com.vibetunneltalk.vibetunnel"
    private static let usernameAccount = "VibeTunnel-Username"
    private static let passwordAccount = "VibeTunnel-Password"
    
    // MARK: - OpenAI API Key Management

    /// Save API key to Keychain
    static func saveAPIKey(_ key: String) -> Bool {
        // Clean the API key: remove newlines and trim whitespace
        let cleanedKey = key
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanedKey.data(using: .utf8) else { return false }

        // Delete any existing item
        deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Load API key from Keychain
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let key = String(data: data, encoding: .utf8) {
            // Clean the API key: remove newlines and trim whitespace
            // This handles any existing corrupted keys in the keychain
            let cleanedKey = key
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanedKey
        }

        return nil
    }
    
    /// Delete API key from Keychain
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Check if API key exists in Keychain
    static func hasAPIKey() -> Bool {
        return loadAPIKey() != nil
    }

    // MARK: - VibeTunnel Credentials Management (Matching iOS Pattern)

    /// Save VibeTunnel credentials (username and password)
    static func saveVibeTunnelCredentials(username: String, password: String) -> Bool {
        // Save username
        guard saveKeychainItem(service: vibeTunnelService, account: usernameAccount, value: username) else {
            AppLogger.auth.error("[KEYCHAIN] Failed to save VibeTunnel username")
            return false
        }

        // Save password
        guard saveKeychainItem(service: vibeTunnelService, account: passwordAccount, value: password) else {
            AppLogger.auth.error("[KEYCHAIN] Failed to save VibeTunnel password")
            // Clean up username if password save fails
            deleteKeychainItem(service: vibeTunnelService, account: usernameAccount)
            return false
        }

        AppLogger.auth.info("[KEYCHAIN] VibeTunnel credentials saved successfully")
        return true
    }

    /// Load VibeTunnel credentials
    static func loadVibeTunnelCredentials() -> (username: String, password: String)? {
        guard let username = loadKeychainItem(service: vibeTunnelService, account: usernameAccount),
              let password = loadKeychainItem(service: vibeTunnelService, account: passwordAccount) else {
            AppLogger.auth.debug("[KEYCHAIN] No VibeTunnel credentials found")
            return nil
        }

        AppLogger.auth.info("[KEYCHAIN] VibeTunnel credentials loaded successfully")
        return (username, password)
    }

    /// Delete VibeTunnel credentials
    static func deleteVibeTunnelCredentials() -> Bool {
        let usernameDeleted = deleteKeychainItem(service: vibeTunnelService, account: usernameAccount)
        let passwordDeleted = deleteKeychainItem(service: vibeTunnelService, account: passwordAccount)

        if usernameDeleted || passwordDeleted {
            AppLogger.auth.info("[KEYCHAIN] VibeTunnel credentials deleted")
        }

        return usernameDeleted || passwordDeleted
    }

    /// Check if VibeTunnel credentials exist
    static func hasVibeTunnelCredentials() -> Bool {
        return loadVibeTunnelCredentials() != nil
    }

    // MARK: - Generic Keychain Operations

    private static func saveKeychainItem(service: String, account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        deleteKeychainItem(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func loadKeychainItem(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        return nil
    }

    @discardableResult
    private static func deleteKeychainItem(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}