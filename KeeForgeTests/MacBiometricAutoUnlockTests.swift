#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacBiometricAutoUnlockTests: XCTestCase {
    private var eligible = true
    private var foreground = true
    private var cycle = 0
    private var attempts = 0
    private var outcome: DatabaseViewModel.BiometricUnlockOutcome = .unlocked

    override func setUp() async throws {
        try await super.setUp()
        eligible = true
        foreground = true
        cycle = 0
        attempts = 0
        outcome = .unlocked
    }

    func testOpeningOrReturningToForegroundPromptsOncePerLockCycle() async {
        let controller = makeController()
        let activation = controller.requestAttempt()
        let keyWindow = controller.requestAttempt()
        await activation.value
        await keyWindow.value
        XCTAssertEqual(attempts, 1)

        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)

        cycle += 1
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 2)
    }

    func testBackgroundOpeningWaitsForForegroundReturn() async {
        let controller = makeController()
        foreground = false
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 0)

        foreground = true
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)
    }

    func testIneligibleSessionDoesNotConsumeItsAttempt() async {
        let controller = makeController()
        eligible = false
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 0)

        eligible = true
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)
    }

    func testForegroundIsRecheckedAfterActivationObserversRun() async {
        let controller = makeController()
        let request = controller.requestAttempt()
        foreground = false
        await request.value
        XCTAssertEqual(attempts, 0)
    }

    func testScreenLockSleepOrOtherNewLockCycleInvalidatesQueuedActivation() async {
        let controller = makeController()
        let request = controller.requestAttempt()
        cycle += 1
        await request.value
        XCTAssertEqual(attempts, 0)

        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)
    }

    func testUnmountInvalidatesQueuedPrompt() async {
        let controller = makeController()
        let request = controller.requestAttempt()
        controller.invalidatePendingAttempt()
        await request.value
        XCTAssertEqual(attempts, 0)
    }

    func testPasswordFallbackAndFailureDoNotRepromptOnAuthenticationReactivation() async {
        for result in [DatabaseViewModel.BiometricUnlockOutcome.passwordFallback, .failed] {
            let controller = makeController()
            outcome = result
            let before = attempts
            await controller.requestAttempt().value
            await controller.requestAttempt().value
            XCTAssertEqual(attempts, before + 1)
        }
    }

    func testUnavailablePromptCanRetryOnNextForegroundEventWithoutLooping() async {
        let controller = makeController()
        outcome = .promptUnavailable
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)

        outcome = .unlocked
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 2)
    }

    func testNewLockCycleCannotStartOverlappingAuthentication() async {
        let started = expectation(description: "Authentication started")
        var finish: CheckedContinuation<DatabaseViewModel.BiometricUnlockOutcome, Never>?
        let controller = MacBiometricAutoUnlockController(
            isEligible: { self.eligible }, lockCycleID: { self.cycle },
            isForeground: { self.foreground },
            unlock: {
                self.attempts += 1
                return await withCheckedContinuation {
                    finish = $0
                    started.fulfill()
                }
            }
        )
        let first = controller.requestAttempt()
        await fulfillment(of: [started], timeout: 2)
        cycle += 1
        await controller.requestAttempt().value
        XCTAssertEqual(attempts, 1)
        finish?.resume(returning: .failed)
        await first.value
    }

    func testEachReturnToTheWindowRequestsAnAttempt() async {
        let centers = makeCenters()
        let triggers: [(NotificationCenter, Notification.Name)] = [
            (centers.app, NSApplication.didBecomeActiveNotification),
            (centers.app, NSWindow.didBecomeKeyNotification),
            (centers.distributed, MacBiometricAutoUnlockController.screenIsUnlockedNotification),
            (centers.workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        let controller = makeController()
        controller.startObserving(window: nil, centers: centers)
        await controller.latestAttempt?.value
        XCTAssertEqual(attempts, 1, "Opening prompts")

        for (center, name) in triggers {
            cycle += 1
            center.post(name: name, object: nil)
            await controller.latestAttempt?.value
            XCTAssertEqual(attempts, cycle + 1, name.rawValue)
        }
        controller.stopObserving()
    }

    func testLockRequestAndResigningActiveCancelTheQueuedPrompt() async {
        for name in [MacBiometricAutoUnlockController.lockRequestedNotification, NSApplication.didResignActiveNotification] {
            let centers = makeCenters()
            let controller = makeController()
            let before = attempts
            controller.startObserving(window: nil, centers: centers)
            centers.app.post(name: name, object: nil)
            await controller.latestAttempt?.value
            XCTAssertEqual(attempts, before, name.rawValue)
            controller.stopObserving()
        }
    }

    func testStoppedControllerIgnoresLaterReturns() async {
        let centers = makeCenters()
        let controller = makeController()
        controller.startObserving(window: nil, centers: centers)
        await controller.latestAttempt?.value
        controller.stopObserving()
        let finished = controller.latestAttempt

        cycle += 1
        centers.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await controller.latestAttempt?.value
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.latestAttempt == finished)
    }

    private func makeCenters() -> MacBiometricAutoUnlockController.NotificationCenters {
        MacBiometricAutoUnlockController.NotificationCenters(
            app: NotificationCenter(),
            workspace: NotificationCenter(),
            distributed: NotificationCenter()
        )
    }

    private func makeController() -> MacBiometricAutoUnlockController {
        MacBiometricAutoUnlockController(
            isEligible: { self.eligible }, lockCycleID: { self.cycle },
            isForeground: { self.foreground },
            unlock: {
                self.attempts += 1
                return self.outcome
            }
        )
    }
}
#endif
