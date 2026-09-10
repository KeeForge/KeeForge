#if os(macOS)
import Foundation

/// One-time notice for people arriving from the "Designed for iPad" build.
///
/// The Mac app inherits that build's App Group, so the database list it shows
/// on first launch may be intact, stale, or empty depending on how macOS
/// resolved the shared container between two builds sharing a bundle
/// identifier. The notice therefore says what to do rather than reporting what
/// was found — it has to read correctly in all three states.
///
/// The presence of `database-list.json` is the trigger: a fresh Mac install has
/// none, and an upgrading one has it whether or not its *contents* are
/// readable. `fileExists` still answers when a read is denied, which is exactly
/// the case that matters.
@MainActor
enum MacTransitionNoticeService {
    private static let presentedKey = "KeeForge.macTransitionNotice.presented"

    /// Decides once, on the first launch that reaches it, and records the
    /// decision either way so the notice can never reappear later.
    static func claimPresentation(
        defaults: UserDefaults = .standard,
        hasLegacyDatabaseList: Bool = hasLegacyDatabaseList()
    ) -> Bool {
        guard defaults.bool(forKey: presentedKey) == false else { return false }
        defaults.set(true, forKey: presentedKey)
        return hasLegacyDatabaseList
    }

    static func hasLegacyDatabaseList() -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID
        ) else {
            return false
        }

        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent("database-list.json").path
        )
    }
}
#endif
