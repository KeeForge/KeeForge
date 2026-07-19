import AuthenticationServices
import Foundation

/// Tracks whether KeeForge is enabled as the system AutoFill credential
/// provider and owns the "enable AutoFill" tip dismissal flag.
/// Main-app only; the extension cannot run while the provider is disabled.
@MainActor
enum AutoFillStatusService {
    private enum Key {
        static let tipDismissed = "KeeForge.autoFillTip.dismissed"
    }

    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    nonisolated(unsafe) static var enabledProvider: @Sendable () async -> Bool = {
        await ASCredentialIdentityStore.shared.state().isEnabled
    }

    static var tipDismissed: Bool {
        get {
            guard !isTipForcedForUITesting else { return false }
            return defaults.bool(forKey: Key.tipDismissed)
        }
        set { defaults.set(newValue, forKey: Key.tipDismissed) }
    }

    static func isAutoFillEnabled() async -> Bool {
        guard !isTipForcedForUITesting else { return false }
        return await enabledProvider()
    }

    /// iOS: shows the system prompt in-app and returns whether the provider
    /// ended up enabled. macOS: no-op until the Mac AutoFill extension ships
    /// (slice 05 of the macOS port); `requestToTurnOnCredentialProviderExtension`
    /// needs macOS 15 and there is no extension to enable yet.
    static func requestEnableAutoFill() async -> Bool? {
        #if os(iOS)
        return await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
        #else
        return nil
        #endif
    }

    static func openAutoFillSettings() async {
        #if os(iOS)
        try? await ASSettingsHelper.openCredentialProviderAppSettings()
        #endif
        // macOS: no credential-provider settings deep link until slice 05.
    }

    /// UI tests suppress the tip by default so it cannot pollute unrelated
    /// tests or App Store screenshots; UI_TEST_SHOW_AUTOFILL_TIP=1 opts a
    /// test back in with deterministic (disabled, undismissed) state.
    nonisolated static var isTipSuppressedForUITesting: Bool {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("-ui-testing") else { return false }
        return processInfo.environment["UI_TEST_SHOW_AUTOFILL_TIP"] != "1"
    }

    private nonisolated static var isTipForcedForUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_SHOW_AUTOFILL_TIP"] == "1"
    }

    static func resetForTesting() {
        defaults.removeObject(forKey: Key.tipDismissed)
    }
}
