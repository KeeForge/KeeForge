import Foundation
import Security

enum CloudTokenStore {
    static func setTokenData(_ data: Data, provider: String, accountId: String) -> Bool {
        let query = itemQuery(provider: provider, accountId: accountId, includeData: false)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func tokenData(provider: String, accountId: String) -> Data? {
        var query = itemQuery(provider: provider, accountId: accountId, includeData: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func deleteToken(provider: String, accountId: String) -> Bool {
        let query = itemQuery(provider: provider, accountId: accountId, includeData: false)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func allAccountIDs(provider: String) -> [String] {
        var query = itemQuery(provider: provider, accountId: nil, includeData: false)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted()
    }

    private static func itemQuery(provider: String, accountId: String?, includeData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.keevault.cloud-token.\(provider)",
        ]

        if let accountId {
            query[kSecAttrAccount as String] = accountId
        }

        if includeData {
            query[kSecReturnData as String] = true
        }

        if let accessGroup = sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }

    private static var sharedAccessGroup: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "CloudKeychainAccessGroup") as? String else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
