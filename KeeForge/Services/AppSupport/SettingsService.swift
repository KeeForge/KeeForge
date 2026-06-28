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
        static let appearanceMode = "KeeForge.appearanceMode"
        static let hasTipped = "KeeForge.hasTipped"
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
    }

    // MARK: - Appearance Mode

    enum AppearanceMode: String, CaseIterable, Sendable {
        case system = "system"
        case light = "light"
        case dark = "dark"

        var title: String {
            switch self {
            case .system:
                return "System Default"
            case .light:
                return "Light"
            case .dark:
                return "Dark"
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

    static var clipboardTimeout: ClipboardTimeout {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.clipboardTimeout) else {
                return .thirtySeconds
            }
            return ClipboardTimeout(rawValue: raw) ?? .thirtySeconds
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.clipboardTimeout)
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
}
