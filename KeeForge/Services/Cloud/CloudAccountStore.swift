import Foundation

enum CloudAccountStore {
    private static let storageKey = "KeeForge.cloudAccounts"

    #if os(macOS)
    /// One-time scrub of the App Group suite, run as a side effect of the
    /// first `defaults` access. `static let` gives thread-safe lazy init.
    private static let didScrubGroupSuite: Bool = {
        if let groupSuite = UserDefaults(suiteName: SharedVaultStore.appGroupID) {
            migrateAccounts(from: groupSuite, to: .standard)
        }
        return true
    }()
    #endif

    /// The `UserDefaults` backing cloud-account records: app-sandbox standard
    /// defaults on macOS, the App Group suite on iOS. See
    /// `SharedVaultStore.cloudAccountDefaults` for the full privacy rationale
    /// (App Group containers are readable by the logged-in user's other
    /// non-sandboxed processes on macOS 14). On macOS, first access also
    /// scrubs any value an earlier build wrote to the group suite.
    private static var defaults: UserDefaults {
        #if os(macOS)
        _ = didScrubGroupSuite
        #endif
        return SharedVaultStore.cloudAccountDefaults
    }

    /// One-time migration/scrub used on macOS: earlier builds wrote
    /// cloud-account records to the App Group suite. Copies any legacy value
    /// to `destination` (without clobbering a value already there), then
    /// removes it from `source` so previously written PII is scrubbed from
    /// the group container. Platform-independent and injection-based so it
    /// can be unit-tested on the iOS test destination.
    static func migrateAccounts(from source: UserDefaults, to destination: UserDefaults) {
        guard let legacyData = source.data(forKey: storageKey) else { return }
        if destination.data(forKey: storageKey) == nil {
            destination.set(legacyData, forKey: storageKey)
        }
        source.removeObject(forKey: storageKey)
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
