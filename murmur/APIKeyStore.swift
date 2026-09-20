import Foundation
import Security

nonisolated enum APIKeyStore {
    enum Account: String, CaseIterable, Sendable {
        case openAI
        case anthropic
        case deepseek
        case cursor

        var keychainAccount: String {
            switch self {
            case .openAI: "OPENAI_API_KEY"
            case .anthropic: "ANTHROPIC_API_KEY"
            case .deepseek: "DEEPSEEK_API_KEY"
            case .cursor: "CURSOR_API_KEY"
            }
        }
    }

    private static let service = "app.murmur"

    static func load(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    static func hasKey(_ account: Account) -> Bool {
        load(account) != nil
    }

    static func save(_ key: String, to account: Account) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        delete(account)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyError(message: "Could not save the API key (\(status)).")
        }
    }

    static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct KeyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
