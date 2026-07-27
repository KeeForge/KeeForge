import Foundation

enum SettingsService {
    // MARK: - Keys

    private enum Key {
        static let autoLockTimeout = "KeeForge.autoLockTimeout"
        static let lockOnBackground = "KeeForge.lockOnBackground"
        static let clipboardTimeout = "KeeForge.clipboardTimeout"
        static let autoUnlockWithFaceID = "KeeForge.autoUnlockWithFaceID"
        static let showWebsiteIcons = "KeeForge.showWebsiteIcons"
        static let showDatabaseUsageStats = "KeeForge.showDatabaseUsageStats"
        static let quickAutoFillEnabled = "KeeForge.quickAutoFillEnabled"
        static let autoFillCopyTOTP = "KeeForge.autoFillCopyTOTP"
        static let appearanceMode = "KeeForge.appearanceMode"
        static let hasTipped = "KeeForge.hasTipped"
        static let macLockPolicy = "KeeForge.macLockPolicy"
        static let blockScreenCapture = "KeeForge.blockScreenCapture"
    }

    static let appearanceModeDefaultsKey = Key.appearanceMode

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
    }

    // MARK: - Auto-Lock Timeout

    enum AutoLockTimeout: String, CaseIterable, Sendable {
        case immediately = "Immediately"
        case thirtySeconds = "30 Seconds"
        case oneMinute = "1 Minute"
        case fiveMinutes = "5 Minutes"
        case never = "Never"

        var seconds: TimeInterval? {
            switch self {
            case .immediately: 0
            case .thirtySeconds: 30
            case .oneMinute: 60
            case .fiveMinutes: 300
            case .never: nil
            }
        }

        var title: String {
            switch self {
            case .immediately: String(localized: "Immediately")
            case .thirtySeconds: String(localized: "30 Seconds")
            case .oneMinute: String(localized: "1 Minute")
            case .fiveMinutes: String(localized: "5 Minutes")
            case .never: String(localized: "Never")
            }
        }
    }

    // MARK: - Clipboard Timeout

    enum ClipboardTimeout: String, CaseIterable, Sendable {
        case tenSeconds = "10 Seconds"
        case thirtySeconds = "30 Seconds"
        case oneMinute = "1 Minute"

        var seconds: TimeInterval {
            switch self {
            case .tenSeconds: 10
            case .thirtySeconds: 30
            case .oneMinute: 60
            }
        }

        var title: String {
            switch self {
            case .tenSeconds: String(localized: "10 Seconds")
            case .thirtySeconds: String(localized: "30 Seconds")
            case .oneMinute: String(localized: "1 Minute")
            }
        }
    }

    // MARK: - macOS Lock Policy
    //
    // macOS has no single "backgrounded" moment to mirror iOS's lock-on-
    // background — apps deactivate constantly during window switching — so the
    // default maps to the deterministic "user walked away" events
    // `MacLockMonitor` observes: screen lock, screensaver, sleep, and
    // fast-user-switch resign.

    enum MacLockPolicy: String, CaseIterable, Sendable {
        case screenLockOrSleep = "screenLockOrSleep"
        case appDeactivates = "appDeactivates"

        var title: String {
            switch self {
            case .screenLockOrSleep:
                return String(localized: "When the Screen Locks or Sleeps")
            case .appDeactivates:
                return String(localized: "When KeeForge Is Not the Active App")
            }
        }
    }

    static var macLockPolicy: MacLockPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.macLockPolicy) else {
                return .screenLockOrSleep
            }
            return MacLockPolicy(rawValue: raw) ?? .screenLockOrSleep
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.macLockPolicy)
        }
    }

    // MARK: - Appearance Mode

    enum AppearanceMode: String, CaseIterable, Sendable {
        case system = "system"
        case light = "light"
        case dark = "dark"

        var title: String {
            switch self {
            case .system:
                return String(localized: "System Default")
            case .light:
                return String(localized: "Light")
            case .dark:
                return String(localized: "Dark")
            }
        }
    }

    // MARK: - Accessors

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearanceMode) else {
                return .system
            }
            return AppearanceMode(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode)
        }
    }

    static var autoLockTimeout: AutoLockTimeout {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.autoLockTimeout) else {
                return .immediately
            }
            return AutoLockTimeout(rawValue: raw) ?? .immediately
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.autoLockTimeout)
        }
    }

    /// App Group-shared so the AutoFill extensions bound their own copies with
    /// the same timeout the app uses. The value used to live in the app-local
    /// standard defaults, so a read that finds nothing in the group container
    /// falls back to the legacy value and migrates it once — existing users
    /// keep the timeout they picked.
    static var clipboardTimeout: ClipboardTimeout {
        get {
            if let raw = sharedDefaults.string(forKey: Key.clipboardTimeout) {
                return ClipboardTimeout(rawValue: raw) ?? .thirtySeconds
            }
            guard let legacyRaw = UserDefaults.standard.string(forKey: Key.clipboardTimeout) else {
                return .thirtySeconds
            }
            sharedDefaults.set(legacyRaw, forKey: Key.clipboardTimeout)
            return ClipboardTimeout(rawValue: legacyRaw) ?? .thirtySeconds
        }
        set {
            sharedDefaults.set(newValue.rawValue, forKey: Key.clipboardTimeout)
        }
    }

    /// Opt-in: after AutoFill fills a password for an entry that also has a
    /// verification code, the current code is copied to the clipboard so it can
    /// be pasted into OTP fields iOS does not recognize. iOS only — see the
    /// gate in `CredentialProviderCoordinator.completeRequest(with:)`.
    static var autoFillCopyTOTP: Bool {
        get {
            sharedDefaults.bool(forKey: Key.autoFillCopyTOTP)
        }
        set {
            sharedDefaults.set(newValue, forKey: Key.autoFillCopyTOTP)
        }
    }

    static var lockOnBackground: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.lockOnBackground) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.lockOnBackground)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.lockOnBackground)
        }
    }

    static var autoUnlockWithFaceID: Bool {
        get {
            sharedDefaults.bool(forKey: Key.autoUnlockWithFaceID)
        }
        set {
            sharedDefaults.set(newValue, forKey: Key.autoUnlockWithFaceID)
        }
    }

    static var showWebsiteIcons: Bool {
        get {
            sharedDefaults.bool(forKey: Key.showWebsiteIcons)
        }
        set {
            sharedDefaults.set(newValue, forKey: Key.showWebsiteIcons)
        }
    }

    static var showDatabaseUsageStats: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.showDatabaseUsageStats) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.showDatabaseUsageStats)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.showDatabaseUsageStats)
        }
    }

    static var quickAutoFillEnabled: Bool {
        get {
            // Default to true — QuickType AutoFill should be on unless explicitly disabled
            if sharedDefaults.object(forKey: Key.quickAutoFillEnabled) == nil {
                return true
            }
            return sharedDefaults.bool(forKey: Key.quickAutoFillEnabled)
        }
        set {
            sharedDefaults.set(newValue, forKey: Key.quickAutoFillEnabled)
        }
    }

    static var hasTipped: Bool {
        get {
            UserDefaults.standard.bool(forKey: Key.hasTipped)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.hasTipped)
        }
    }

    // MARK: - Block Screen Capture (macOS)
    //
    // macOS-only in the UI, but the key exists cross-platform so the setting
    // round-trips in shared tests; iOS shields via `UIScreen.isCaptured`
    // instead. App-local defaults, not the App Group — a per-device UI
    // preference, not extension state.

    static var blockScreenCapture: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.blockScreenCapture) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.blockScreenCapture)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.blockScreenCapture)
        }
    }
}
