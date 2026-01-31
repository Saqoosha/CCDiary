import Foundation
import Security

/// Helper for storing and retrieving API keys from Keychain
enum KeychainHelper {
    static let claudeAPIService = "sh.saqoo.CCDiary.claude-api-key"
    static let geminiAPIService = "sh.saqoo.CCDiary.gemini-api-key"

    // Legacy identifiers for migration
    private static let legacyClaudeAPIService = "com.ccdiary.claude-api-key"
    private static let legacyGeminiAPIService = "com.ccdiary.gemini-api-key"

    private static let migrationLock = NSLock()
    private nonisolated(unsafe) static var hasMigrated = false

    /// Migrate keys from legacy identifiers (call once at app startup)
    static func migrateIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        guard !hasMigrated else { return }
        hasMigrated = true

        // Migrate Claude API key
        if load(service: claudeAPIService) == nil,
           let legacyKey = load(service: legacyClaudeAPIService) {
            try? save(key: legacyKey, service: claudeAPIService)
            delete(service: legacyClaudeAPIService)
        }

        // Migrate Gemini API key
        if load(service: geminiAPIService) == nil,
           let legacyKey = load(service: legacyGeminiAPIService) {
            try? save(key: legacyKey, service: geminiAPIService)
            delete(service: legacyGeminiAPIService)
        }
    }

    /// Save a key to the Keychain
    static func save(key: String, service: String) throws {
        let data = key.data(using: .utf8)!

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }

    /// Load a key from the Keychain
    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Delete a key from the Keychain
    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        }
    }
}
