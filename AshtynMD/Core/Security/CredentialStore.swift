import Foundation
import Security

/// API credentials as generic-password items in the macOS Keychain. Secrets
/// never touch preferences, logs, crash reports, or project files.
enum CredentialStore {
    static let service = "com.kadeem.ashtynmd.ai-credentials"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    /// Stores (or, with nil, removes) the secret for a provider.
    static func setSecret(_ secret: String?, for provider: AIProviderID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        guard let secret, !secret.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func secret(for provider: AIProviderID) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func hasSecret(for provider: AIProviderID) -> Bool {
        (try? secret(for: provider)).flatMap { $0 }?.isEmpty == false
    }
}
