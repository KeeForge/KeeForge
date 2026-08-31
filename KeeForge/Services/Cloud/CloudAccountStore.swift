import Foundation

enum CloudAccountStore {
    private static let storageKey = "KeeForge.cloudAccounts"

    /// The `UserDefaults` backing cloud-account records: app-sandbox standard
    /// defaults on macOS, the App Group suite on iOS. See
    /// `SharedVaultStore.cloudAccountDefaults` for the privacy rationale.
    private static var defaults: UserDefaults {
        return SharedVaultStore.cloudAccountDefaults
    }

    static var accounts: [CloudAccount] {
        loadAccounts()
    }

    static func accounts(for provider: String) -> [CloudAccount] {
        loadAccounts()
            .filter { $0.provider == provider }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func account(provider: String, accountId: String) -> CloudAccount? {
        loadAccounts().first { $0.provider == provider && $0.id == accountId }
    }

    static func isConnected(provider: String, accountId: String) -> Bool {
        account(provider: provider, accountId: accountId) != nil
    }

    static func upsert(_ account: CloudAccount) {
        var current = loadAccounts()
        if let index = current.firstIndex(where: { $0.provider == account.provider && $0.id == account.id }) {
            current[index] = account
        } else {
            current.append(account)
        }
        saveAccounts(current)
    }

    static func remove(provider: String, accountId: String) {
        saveAccounts(loadAccounts().filter { !($0.provider == provider && $0.id == accountId) })
    }

    static func clearAll() {
        defaults.removeObject(forKey: storageKey)
    }

    private static func loadAccounts() -> [CloudAccount] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CloudAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveAccounts(_ accounts: [CloudAccount]) {
        guard let encoded = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(encoded, forKey: storageKey)
    }
}
