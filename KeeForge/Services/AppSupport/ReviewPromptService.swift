import Foundation
import StoreKit
#if os(iOS)
import UIKit
#endif

@MainActor
enum ReviewPromptService {
    private enum Key {
        static let actionCount = "KeeForge.reviewPrompt.actionCount"
        static let hasPrompted = "KeeForge.reviewPrompt.hasPrompted"
    }

    nonisolated(unsafe) static var minimumActions = 10
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Distribution-channel gate. The Mac App Store and iOS App Store builds
    /// leave this `true`. Slice 07 introduces a real channel flag for the
    /// notarized Developer ID (direct-download) build; that build must set this
    /// to `false` so the StoreKit review prompt — which only works for App
    /// Store installs — silently no-ops instead of failing. Hook lives here so
    /// slice 07 only has to flip it at launch.
    nonisolated(unsafe) static var isAppStoreBuild = true

    /// Injected review presenter. macOS has no scene-based StoreKit entry point
    /// the way iOS does; the app wires SwiftUI's `RequestReviewAction`
    /// (`@Environment(\.requestReview)`) in here so the service stays free of a
    /// view dependency and stays unit-testable (tests leave it `nil`, so the
    /// prompt no-ops). When set, it takes precedence on every platform.
    nonisolated(unsafe) static var requestReviewHandler: (() -> Void)?

    static var actionCount: Int {
        get { defaults.integer(forKey: Key.actionCount) }
        set { defaults.set(newValue, forKey: Key.actionCount) }
    }

    static var hasPrompted: Bool {
        get { defaults.bool(forKey: Key.hasPrompted) }
        set { defaults.set(newValue, forKey: Key.hasPrompted) }
    }

    static func recordMeaningfulAction() {
        actionCount += 1
    }

    static func shouldPrompt() -> Bool {
        guard !hasPrompted else { return false }
        guard actionCount >= minimumActions else { return false }
        return true
    }

    static func requestReviewIfAppropriate() {
        recordMeaningfulAction()

        guard shouldPrompt() else { return }

        hasPrompted = true

        presentReviewPrompt()
    }

    private static func presentReviewPrompt() {
        // Non-App-Store builds cannot show a StoreKit review prompt; skip.
        guard isAppStoreBuild else { return }

        // App-injected presenter wins on every platform.
        if let requestReviewHandler {
            requestReviewHandler()
            return
        }

        #if os(iOS)
        // iOS keeps the existing scene-based path (not deprecated on iOS).
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
        #else
        // macOS: `SKStoreReviewController.requestReview()` was the slice-01
        // interim and is deprecated on macOS 15. The supported modern entry
        // point is SwiftUI's `RequestReviewAction`, which the app injects via
        // `requestReviewHandler`. If it is unset (e.g. in unit tests), no-op.
        #endif
    }

    static func resetForTesting() {
        defaults.removeObject(forKey: Key.actionCount)
        defaults.removeObject(forKey: Key.hasPrompted)
    }
}
