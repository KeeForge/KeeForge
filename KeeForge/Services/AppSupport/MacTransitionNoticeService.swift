#if os(macOS)
import Foundation
import os

/// One-time notice for people arriving from the "Designed for iPad" build.
///
/// Two builds sharing `com.keevault.app` make the App Group's availability
/// itself a signal. macOS binds the container to one signing
/// `validationCategory`, and the losing build is denied — so on first launch
/// the Mac app sees one of exactly three things, and the notice has to be
/// right in all of them:
///
/// - **A list is there.** An upgrading install whose container resolved.
/// - **No list, container fine.** A genuinely fresh Mac install.
/// - **No container at all.** `containerURL(forSecurityApplicationGroupIdentifier:)`
///   returns nil when the group is denied. A fresh install always gets its
///   group, so this can only be the denied case — which is precisely when the
///   user is staring at an empty list and most needs the instructions.
///
/// The third case is why this does not simply ask whether the file exists:
/// when the group is denied there is no container URL to ask about.
@MainActor
enum MacTransitionNoticeService {
    private static let presentedKey = "KeeForge.macTransitionNotice.presented"
    private static let logger = Logger(subsystem: "KeeForge", category: "MacTransition")

    enum LegacyState: String {
        /// `database-list.json` is present in a readable App Group container.
        case listPresent
        /// The container resolved and holds no list — a fresh Mac install.
        case freshInstall
        /// The App Group could not be resolved at all.
        case containerUnavailable

        var warrantsNotice: Bool {
            switch self {
            case .listPresent, .containerUnavailable: true
            case .freshInstall: false
            }
        }
    }

    /// Decides once, on the first launch that reaches it, and records the
    /// decision either way so the notice can never reappear later.
    static func claimPresentation(
        defaults: UserDefaults = .standard,
        legacyState: LegacyState = legacyState()
    ) -> Bool {
        guard defaults.bool(forKey: presentedKey) == false else { return false }
        defaults.set(true, forKey: presentedKey)
        logger.info("first launch, legacy state: \(legacyState.rawValue, privacy: .public)")
        return legacyState.warrantsNotice
    }

    static func legacyState() -> LegacyState {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID
        ) else {
            return .containerUnavailable
        }

        let listURL = container.appendingPathComponent("database-list.json")
        return FileManager.default.fileExists(atPath: listURL.path) ? .listPresent : .freshInstall
    }
}
#endif
