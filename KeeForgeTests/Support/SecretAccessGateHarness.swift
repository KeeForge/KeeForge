import Foundation
@testable import KeeForge

/// A `SecretAccessGate` over a clock, a setting, and a prompt the test owns,
/// so no system dialog is raised and no time has to pass.
@MainActor
final class SecretAccessGateHarness {
    struct PromptDeclined: Error {}

    /// Setting it tells the live gates, the way Settings does. Turn
    /// `announcesSettingChanges` off to stand in for a bare write.
    var gracePeriod: SettingsService.AuthenticationGracePeriod {
        didSet {
            if announcesSettingChanges {
                SecretAccessGate.gracePeriodSettingDidChange()
            }
        }
    }
    var announcesSettingChanges = true
    var isAuthenticationAvailable = true
    /// False makes the next prompts fail the way a cancelled one does.
    var promptSucceeds = true
    /// Runs while the prompt is up, before it answers.
    var duringPrompt: (() -> Void)?
    private(set) var promptReasons: [String] = []
    private(set) var now = ContinuousClock.now

    private(set) lazy var gate = SecretAccessGate(
        gracePeriod: { [weak self] in self?.gracePeriod ?? .alwaysAsk },
        now: { [weak self] in self?.now ?? .now },
        isAuthenticationAvailable: { [weak self] in self?.isAuthenticationAvailable ?? true },
        prompt: { [weak self] reason in
            guard let self else { throw PromptDeclined() }
            self.promptReasons.append(reason)
            self.duringPrompt?()
            if self.promptSucceeds == false {
                throw PromptDeclined()
            }
        }
    )

    init(gracePeriod: SettingsService.AuthenticationGracePeriod = .fiveMinutes) {
        self.gracePeriod = gracePeriod
    }

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }
}
