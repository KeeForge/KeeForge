#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// Unit tests for `MacLockMonitor` using injected notification centers — no
/// real screen locking, sleeping, or app deactivation happens here.
@MainActor
final class MacLockMonitorTests: XCTestCase {
    private var appCenter: NotificationCenter!
    private var workspaceCenter: NotificationCenter!
    private var distributedCenter: NotificationCenter!
    private var monitor: MacLockMonitor!
    private var policy: SettingsService.MacLockPolicy = .screenLockOrSleep
    private var receivedTriggers: [MacLockMonitor.Trigger] = []
    private var becameActiveCount = 0
    private var remainingHostWindows = 0
    private var isAuthenticationPromptUp = false
    private var frontmostApplication: pid_t?

    private let ownApp = ProcessInfo.processInfo.processIdentifier
    private let promptHost: pid_t = 70_001
    private let otherApp: pid_t = 70_002

    override func setUp() async throws {
        try await super.setUp()
        appCenter = NotificationCenter()
        workspaceCenter = NotificationCenter()
        distributedCenter = NotificationCenter()
        policy = .screenLockOrSleep
        receivedTriggers = []
        becameActiveCount = 0
        remainingHostWindows = 0
        isAuthenticationPromptUp = false
        frontmostApplication = nil

        monitor = MacLockMonitor(
            notificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter,
            lockPolicyProvider: { [weak self] in self?.policy ?? .screenLockOrSleep },
            remainingWindowCounter: { [weak self] _ in self?.remainingHostWindows ?? 0 },
            authenticationPromptProvider: { [weak self] in self?.isAuthenticationPromptUp ?? false },
            frontmostApplicationProvider: { [weak self] in self?.frontmostApplication }
        )
        monitor.onLockTriggered = { [weak self] trigger in
            self?.receivedTriggers.append(trigger)
        }
        monitor.onDidBecomeActive = { [weak self] in
            self?.becameActiveCount += 1
        }
        monitor.start()
    }

    override func tearDown() async throws {
        monitor.stop()
        monitor = nil
        try await super.tearDown()
    }

    // MARK: - Deterministic lock triggers (fire under every policy)

    func testScreenLockNotificationFiresLock() {
        distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.screenLocked])
    }

    func testScreensaverStartNotificationFiresLock() {
        distributedCenter.post(name: MacLockMonitor.screensaverDidStartNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.screensaverStarted])
    }

    func testWillSleepNotificationFiresLock() {
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.systemWillSleep])
    }

    func testSessionResignNotificationFiresLock() {
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.sessionResignedActive])
    }

    // MARK: - App deactivation obeys the lock policy

    func testAppResignActiveDoesNotFireLockUnderDefaultPolicy() {
        policy = .screenLockOrSleep
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testAppResignActiveFiresLockUnderStrictPolicy() {
        policy = .appDeactivates
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testPolicyIsReadPerEventNotCaptured() {
        policy = .screenLockOrSleep
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(receivedTriggers.isEmpty)

        policy = .appDeactivates
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    // MARK: - The app's own authentication prompt (#203)

    /// The system shows the prompt from its own process, so revealing a
    /// password deactivates the app. Under the strict policy that locked the
    /// vault the prompt was asked for.
    func testAppResignActiveBehindOwnAuthenticationPromptDoesNotFireLock() {
        resignActiveBehindAuthenticationPrompt()

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testAnsweringTheAuthenticationPromptDoesNotFireLock() {
        resignActiveBehindAuthenticationPrompt()

        isAuthenticationPromptUp = false
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(receivedTriggers.isEmpty)
        XCTAssertEqual(becameActiveCount, 1)
    }

    func testAnotherAppTakingOverWhileThePromptIsUpFiresLock() {
        resignActiveBehindAuthenticationPrompt()

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    /// The prompt can end with another app in front, and then nothing
    /// reactivates KeeForge.
    func testAnotherAppTakingOverAfterThePromptEndedFiresLock() {
        resignActiveBehindAuthenticationPrompt()

        isAuthenticationPromptUp = false
        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testThePromptHostAndTheAppItselfComingForwardDoNotFireLock() {
        resignActiveBehindAuthenticationPrompt()

        monitor.handleApplicationDidActivate(processIdentifier: promptHost)
        monitor.handleApplicationDidActivate(processIdentifier: ownApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// The deactivation can arrive before the prompt's process is reported
    /// frontmost; the first application to come forward is then the host.
    func testThePromptHostIsLearnedFromTheFirstActivationWhenNotYetFrontmost() {
        resignActiveBehindAuthenticationPrompt(frontmost: ownApp)

        monitor.handleApplicationDidActivate(processIdentifier: promptHost)
        XCTAssertTrue(receivedTriggers.isEmpty)

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    /// Once the prompt is gone, an unknown application cannot be its host.
    func testAnUnknownHostIsNotLearnedAfterThePromptEnded() {
        resignActiveBehindAuthenticationPrompt(frontmost: nil)

        isAuthenticationPromptUp = false
        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testAHeldDeactivationFiresLockOnlyOnce() {
        resignActiveBehindAuthenticationPrompt()

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)
        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testBecomingActiveEndsTheHeldDeactivation() {
        resignActiveBehindAuthenticationPrompt()
        isAuthenticationPromptUp = false
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)
        XCTAssertTrue(receivedTriggers.isEmpty, "A switch from the active app arrives as its own deactivation")

        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testApplicationActivationWithoutAHeldDeactivationDoesNotFireLock() {
        policy = .appDeactivates

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testDeterministicTriggersStillFireLockWhileThePromptIsUp() {
        resignActiveBehindAuthenticationPrompt()

        distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertEqual(receivedTriggers, [.screenLocked])
    }

    func testAuthenticationPromptDoesNotMatterUnderDefaultPolicy() {
        resignActiveBehindAuthenticationPrompt(policy: .screenLockOrSleep)

        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// The observer reads the activated application out of the notification,
    /// which only a real running application can stand in for.
    func testWorkspaceActivationNotificationReachesTheHeldDeactivation() throws {
        let runningApp = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ownApp }
        )
        resignActiveBehindAuthenticationPrompt()

        workspaceCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: runningApp]
        )

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    private func resignActiveBehindAuthenticationPrompt(
        policy: SettingsService.MacLockPolicy = .appDeactivates,
        frontmost: pid_t? = 70_001
    ) {
        self.policy = policy
        isAuthenticationPromptUp = true
        frontmostApplication = frontmost
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
    }

    // MARK: - Became active

    // MARK: - Window close

    func testClosingTheLastHostWindowFiresLock() {
        remainingHostWindows = 0
        monitor.handleWindowWillClose(nil)
        XCTAssertEqual(receivedTriggers, [.lastWindowClosed])
    }

    func testClosingAWindowWhileAnotherRemainsDoesNotFireLock() {
        remainingHostWindows = 1
        monitor.handleWindowWillClose(nil)
        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// Unlike app deactivation, this trigger is unconditional: the vault has no
    /// window left to lock it from under any policy.
    func testWindowCloseFiresLockUnderEveryPolicy() {
        for candidate in [SettingsService.MacLockPolicy.screenLockOrSleep, .appDeactivates] {
            policy = candidate
            receivedTriggers = []
            remainingHostWindows = 0
            monitor.handleWindowWillClose(nil)
            XCTAssertEqual(receivedTriggers, [.lastWindowClosed], "policy \(candidate)")
        }
    }

    func testDidBecomeActiveNotificationFiresBecameActiveCallback() {
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(becameActiveCount, 1)
        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    // MARK: - Lifecycle

    func testStopRemovesAllObservers() {
        monitor.stop()

        distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(receivedTriggers.isEmpty)
        XCTAssertEqual(becameActiveCount, 0)
    }

    func testStopDropsAHeldDeactivation() {
        resignActiveBehindAuthenticationPrompt()

        monitor.stop()
        monitor.handleApplicationDidActivate(processIdentifier: otherApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testStartIsIdempotent() {
        monitor.start()
        monitor.start()

        distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.screenLocked], "Repeated start() must not duplicate observers")
    }

    func testNotificationsOnWrongCenterAreIgnored() {
        // Screen-lock name posted on the app center (not the injected
        // distributed center) must not fire.
        appCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        XCTAssertTrue(receivedTriggers.isEmpty)
    }
}
#endif
