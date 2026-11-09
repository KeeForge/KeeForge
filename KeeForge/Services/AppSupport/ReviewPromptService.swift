import Foundation
#if os(iOS)
import StoreKit
import UIKit
#endif

/// Asks for an App Store rating at most once per app version, and only at a
/// success moment: a clean save, or an unlock once AutoFill has proven useful.
/// The system throttles the prompt further on its own.
@MainActor
enum ReviewPromptService {
    private enum Key {
        static let successfulSaveCount = "KeeForge.reviewPrompt.successfulSaveCount"
        static let lastPromptedVersion = "KeeForge.reviewPrompt.lastPromptedVersion"
        static let suppressed = "KeeForge.reviewPrompt.suppressed"
    }

    nonisolated(unsafe) static var minimumSuccessfulSaves = 3
    nonisolated(unsafe) static var minimumSuccessfulAutoFills = 5
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    nonisolated(unsafe) static var currentVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// Distribution-channel gate, defaulted from the build's own channel: the
    /// StoreKit review prompt only works for an App Store install, so the
    /// notarized Developer ID build silently no-ops instead of failing. Still a
    /// `var` so tests can drive both sides.
    nonisolated(unsafe) static var isAppStoreBuild = DistributionChannel.supportsStoreKit

    /// Injected review presenter. macOS has no scene-based StoreKit entry point
    /// the way iOS does; the app wires SwiftUI's `RequestReviewAction`
    /// (`@Environment(\.requestReview)`) in here so the service stays free of a
    /// view dependency and stays unit-testable (tests leave it `nil`, so the
    /// prompt no-ops). When set, it takes precedence on every platform.
    nonisolated(unsafe) static var requestReviewHandler: (() -> Void)?

    /// UI-test launches persist the counters, so the system prompt would
    /// otherwise cover whichever test reaches a threshold. Launches without
    /// `-ui-testing` opt out through the `KeeForge.reviewPrompt.suppressed`
    /// argument-domain default.
    nonisolated(unsafe) static var isSuppressedForUITesting: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") { return true }
        #endif
        return UserDefaults.standard.bool(forKey: Key.suppressed)
    }()

    static var successfulSaveCount: Int {
        get { defaults.integer(forKey: Key.successfulSaveCount) }
        set { defaults.set(newValue, forKey: Key.successfulSaveCount) }
    }

    static var lastPromptedVersion: String? {
        get { defaults.string(forKey: Key.lastPromptedVersion) }
        set { defaults.set(newValue, forKey: Key.lastPromptedVersion) }
    }

    /// Recorded by the AutoFill extensions in App Group defaults; the
    /// extension cannot present the prompt itself, so the app acts on it.
    static var successfulAutoFillCount: Int {
        SettingsService.successfulAutoFillCount
    }

    static var hasPromptedForCurrentVersion: Bool {
        guard let currentVersion else { return true }
        return lastPromptedVersion == currentVersion
    }

    /// Call after a save that reached storage. `followsError` is true when the
    /// save retried or resolved an error the user just saw.
    static func noteSuccessfulSave(followsError: Bool) {
        successfulSaveCount += 1
        guard !followsError, successfulSaveCount >= minimumSuccessfulSaves else { return }
        requestReviewIfNotYetPromptedForVersion()
    }

    /// Call after an unlock. `followsError` is true when a failed attempt
    /// preceded it.
    static func noteSuccessfulUnlock(followsError: Bool) {
        guard !followsError, successfulAutoFillCount >= minimumSuccessfulAutoFills else { return }
        requestReviewIfNotYetPromptedForVersion()
    }

    private static func requestReviewIfNotYetPromptedForVersion() {
        guard !hasPromptedForCurrentVersion else { return }
        // Non-App-Store builds cannot show a StoreKit review prompt.
        guard isAppStoreBuild, !isSuppressedForUITesting else { return }
        lastPromptedVersion = currentVersion
        presentReviewPrompt()
    }

    private static func presentReviewPrompt() {
        // App-injected presenter wins on every platform.
        if let requestReviewHandler {
            requestReviewHandler()
            return
        }

        #if os(iOS)
        // iOS keeps the scene-based path via `AppStore.requestReview(in:)`,
        // which replaced the deprecated `SKStoreReviewController` in iOS 18.
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            AppStore.requestReview(in: scene)
        }
        #else
        // macOS routes through SwiftUI's `RequestReviewAction`, which the app
        // injects as `requestReviewHandler`; unset (e.g. in tests) means no-op.
        #endif
    }

    static func resetForTesting() {
        defaults.removeObject(forKey: Key.successfulSaveCount)
        defaults.removeObject(forKey: Key.lastPromptedVersion)
    }
}
