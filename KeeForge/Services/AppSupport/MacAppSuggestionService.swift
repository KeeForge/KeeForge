import Foundation

/// Decides whether to suggest the native Mac app, and owns the suggestion's
/// dismissal flag.
///
/// The suggestion is for the iPhone and iPad app running on a Mac, which is the
/// only place `ProcessInfo.isiOSAppOnMac` is true: it is false on iPhone and
/// iPad, and false in the native Mac app.
@MainActor
enum MacAppSuggestionService {
    private enum Key {
        static let dismissed = "KeeForge.macAppSuggestion.dismissed"
    }

    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    nonisolated(unsafe) static var isiOSAppOnMac: @Sendable () -> Bool = {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    /// KeeForge's App Store listing. It is a universal purchase, so on a Mac
    /// this is where the native app is installed from.
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6759309295")

    static var isDismissed: Bool {
        get {
            guard !isForcedForUITesting else { return false }
            return defaults.bool(forKey: Key.dismissed)
        }
        set { defaults.set(newValue, forKey: Key.dismissed) }
    }

    static var isSuggestionAvailable: Bool {
        isForcedForUITesting || isiOSAppOnMac()
    }

    /// No simulator reports `isiOSAppOnMac`, so UI tests opt in with
    /// UI_TEST_SHOW_MAC_APP_SUGGESTION=1, which also ignores a persisted
    /// dismissal so every launch starts with the banner up.
    private nonisolated static var isForcedForUITesting: Bool {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("-ui-testing") else { return false }
        return processInfo.environment["UI_TEST_SHOW_MAC_APP_SUGGESTION"] == "1"
    }

    static func resetForTesting() {
        defaults.removeObject(forKey: Key.dismissed)
        isiOSAppOnMac = { ProcessInfo.processInfo.isiOSAppOnMac }
    }
}
