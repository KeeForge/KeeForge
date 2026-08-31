import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#endif

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
    nonisolated(unsafe) static var enableRequester: @Sendable () async -> Bool = {
        await systemEnableRequest()
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

    /// Asks the user to enable KeeForge as the system AutoFill provider.
    ///
    /// The system prompt reports whether the provider ended up enabled.
    static func requestEnableAutoFill() async -> Bool {
        await enableRequester()
    }

    private static func systemEnableRequest() async -> Bool {
        await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
    }

    /// Opens the system's AutoFill provider settings: Settings ▸ General ▸
    /// AutoFill & Passwords on iOS, System Settings ▸ General ▸ AutoFill &
    /// Passwords on macOS. This is the single macOS entry point for that pane
    /// — call it instead of re-deriving the deep link.
    static func openAutoFillSettings() async {
        #if os(iOS)
        try? await ASSettingsHelper.openCredentialProviderAppSettings()
        #else
        do {
            try await ASSettingsHelper.openCredentialProviderAppSettings()
        } catch {
            // The helper is the documented route, but a failure here would
            // leave the Mac with no way to reach the pane from inside the app.
            if let url = Self.macAutoFillSettingsURL {
                _ = NSWorkspace.shared.open(url)
            }
        }
        #endif
    }

    #if os(macOS)
    /// System Settings' Passwords pane, which hosts the AutoFill provider
    /// list the app needs the user to reach.
    private static let macAutoFillSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension"
    )
    #endif

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
        enabledProvider = { await ASCredentialIdentityStore.shared.state().isEnabled }
        enableRequester = { await systemEnableRequest() }
    }
}
