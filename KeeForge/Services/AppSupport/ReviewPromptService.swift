import Foundation
import StoreKit

@MainActor
enum ReviewPromptService {
    private enum Key {
        static let actionCount = "KeeForge.reviewPrompt.actionCount"
        static let hasPrompted = "KeeForge.reviewPrompt.hasPrompted"
    }

    nonisolated(unsafe) static var minimumActions = 10
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

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

        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    static func resetForTesting() {
        defaults.removeObject(forKey: Key.actionCount)
        defaults.removeObject(forKey: Key.hasPrompted)
    }
}
