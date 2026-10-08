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
    private var isAuthenticationPromptPending = false
    private var frontmostApplication: MacLockMonitor.ForegroundApplication?
    private var scheduledDeadlines: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []

    private let reactivationGracePeriod: TimeInterval = 7
    private let ownApp = MacLockMonitor.ForegroundApplication(
        processIdentifier: ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: "com.keevault.app.mac",
        bundleURL: URL(fileURLWithPath: "/Applications/KeeForge.app")
    )
    /// The system's authentication UI as the workspace reports it while a
    /// prompt is up.
    private let promptHost = MacLockMonitor.ForegroundApplication(
        processIdentifier: 70_001,
        bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
        bundleURL: URL(fileURLWithPath: "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle")
    )
    private let otherApp = MacLockMonitor.ForegroundApplication(
        processIdentifier: 70_002,
        bundleIdentifier: "com.apple.finder",
        bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    )
    /// An application that only declares the prompt's bundle identifier.
    private let impostor = MacLockMonitor.ForegroundApplication(
        processIdentifier: 70_003,
        bundleIdentifier: "com.apple.LocalAuthentication.UIAgent",
        bundleURL: URL(fileURLWithPath: "/Applications/Impostor.app")
    )

    override func setUp() async throws {
        try await super.setUp()
        appCenter = NotificationCenter()
        workspaceCenter = NotificationCenter()
        distributedCenter = NotificationCenter()
        policy = .screenLockOrSleep
        receivedTriggers = []
        becameActiveCount = 0
        remainingHostWindows = 0
        isAuthenticationPromptPending = false
        frontmostApplication = nil
        scheduledDeadlines = []

        monitor = MacLockMonitor(
            notificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter,
            lockPolicyProvider: { [weak self] in self?.policy ?? .screenLockOrSleep },
            remainingWindowCounter: { [weak self] _ in self?.remainingHostWindows ?? 0 },
            authenticationPromptProvider: { [weak self] in self?.isAuthenticationPromptPending ?? false },
            frontmostApplicationProvider: { [weak self] in self?.frontmostApplication },
            reactivationGracePeriod: reactivationGracePeriod,
            deadlineScheduler: { [weak self] delay, work in
                self?.scheduledDeadlines.append((delay: delay, work: work))
            }
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

        endAuthenticationPrompt()
        becomeActive()
        letScheduledDeadlinesPass()

        XCTAssertTrue(receivedTriggers.isEmpty)
        XCTAssertEqual(becameActiveCount, 1)
    }

    func testAnotherAppTakingOverWhileThePromptIsUpFiresLock() {
        resignActiveBehindAuthenticationPrompt()

        activate(otherApp)

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    /// The prompt can end with another app in front, and then nothing
    /// reactivates KeeForge.
    func testAnotherAppTakingOverAfterThePromptEndedFiresLock() {
        resignActiveBehindAuthenticationPrompt()

        endAuthenticationPrompt()
        activate(otherApp)
        letScheduledDeadlinesPass()

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testThePromptHostAndTheAppItselfComingForwardDoNotFireLock() {
        resignActiveBehindAuthenticationPrompt()

        activate(promptHost)
        activate(ownApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testAHeldDeactivationFiresLockOnlyOnce() {
        resignActiveBehindAuthenticationPrompt()

        activate(otherApp)
        activate(otherApp)
        endAuthenticationPrompt()
        letScheduledDeadlinesPass()

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testBecomingActiveEndsTheHeldDeactivation() {
        resignActiveBehindAuthenticationPrompt()
        endAuthenticationPrompt()
        becomeActive()

        activate(otherApp)
        XCTAssertTrue(receivedTriggers.isEmpty, "A switch from the active app arrives as its own deactivation")

        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testApplicationActivationWithoutAHeldDeactivationDoesNotFireLock() {
        policy = .appDeactivates

        activate(otherApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testDeterministicTriggersStillFireLockWhileThePromptIsUp() {
        resignActiveBehindAuthenticationPrompt()

        distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)
        activate(otherApp)
        endAuthenticationPrompt()
        letScheduledDeadlinesPass()

        XCTAssertEqual(receivedTriggers, [.screenLocked])
    }

    func testAuthenticationPromptDoesNotMatterUnderDefaultPolicy() {
        resignActiveBehindAuthenticationPrompt(policy: .screenLockOrSleep)

        activate(otherApp)
        endAuthenticationPrompt()
        letScheduledDeadlinesPass()

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// The hold was made under the strict policy; a lock it turns into later
    /// must not outlast a change away from that policy.
    func testAHeldDeactivationDoesNotFireLockAfterThePolicyChanged() {
        resignActiveBehindAuthenticationPrompt()

        policy = .screenLockOrSleep
        activate(otherApp)

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// The observer reads the activated application out of the notification,
    /// which only a real running application can stand in for.
    func testWorkspaceActivationNotificationReachesTheHeldDeactivation() throws {
        let runningApp = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ownApp.processIdentifier
                    && MacLockMonitor.ForegroundApplication($0).isSystemAuthenticationPrompt == false
            }
        )
        resignActiveBehindAuthenticationPrompt()

        workspaceCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: runningApp]
        )

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    // MARK: - Only the prompt itself holds the lock

    /// The request is marked before the prompt appears, so the user can leave
    /// for another application in between. That application is not the
    /// prompt, during the request or after it.
    func testLeavingForAnotherAppWhileAPromptIsPendingFiresLock() {
        resignActiveWhileAPromptIsPending(frontmost: otherApp)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])

        activate(otherApp)
        endAuthenticationPrompt()
        activate(otherApp)
        letScheduledDeadlinesPass()

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    /// The deactivation can be delivered before the workspace reports who
    /// took the foreground. The first application to come forward then is
    /// judged like any other, not taken for the prompt.
    func testAnotherAppComingForwardFirstIsNotTakenForThePrompt() {
        for frontmost in [ownApp, nil] {
            receivedTriggers = []
            resignActiveWhileAPromptIsPending(frontmost: frontmost)
            XCTAssertTrue(receivedTriggers.isEmpty)

            activate(otherApp)
            XCTAssertEqual(receivedTriggers, [.appResignedActive])

            endAuthenticationPrompt()
            activate(otherApp)
            letScheduledDeadlinesPass()
            XCTAssertEqual(receivedTriggers, [.appResignedActive])
        }
    }

    func testThePromptComingForwardAfterTheDeactivationKeepsTheHold() {
        resignActiveWhileAPromptIsPending(frontmost: ownApp)

        activate(promptHost)
        XCTAssertTrue(receivedTriggers.isEmpty)

        activate(otherApp)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testAnAppDeclaringThePromptBundleIdentifierIsNotThePrompt() {
        resignActiveWhileAPromptIsPending(frontmost: impostor)
        XCTAssertEqual(receivedTriggers, [.appResignedActive])

        becomeActive()
        resignActiveBehindAuthenticationPrompt()
        activate(impostor)
        XCTAssertEqual(receivedTriggers, [.appResignedActive, .appResignedActive])
    }

    func testOnlyTheSystemAuthenticationUIIsRecognizedAsThePrompt() {
        typealias Application = MacLockMonitor.ForegroundApplication
        let identifier = Application.systemAuthenticationPromptBundleIdentifier
        func application(_ bundleIdentifier: String?, _ bundleURL: URL?) -> Application {
            Application(processIdentifier: 1, bundleIdentifier: bundleIdentifier, bundleURL: bundleURL)
        }

        XCTAssertTrue(promptHost.isSystemAuthenticationPrompt)
        XCTAssertFalse(otherApp.isSystemAuthenticationPrompt, "On the system volume, but not the prompt")
        XCTAssertFalse(impostor.isSystemAuthenticationPrompt)
        XCTAssertFalse(application(identifier, nil).isSystemAuthenticationPrompt)
        XCTAssertFalse(application(nil, promptHost.bundleURL).isSystemAuthenticationPrompt)
        XCTAssertFalse(
            application(identifier, URL(fileURLWithPath: "/System/Library/../../Applications/Impostor.app"))
                .isSystemAuthenticationPrompt,
            "A path that only starts like the system volume"
        )
        XCTAssertFalse(
            application(identifier, URL(fileURLWithPath: "/Users/Shared/System/Library/coreautha.bundle"))
                .isSystemAuthenticationPrompt
        )
        XCTAssertFalse(
            application(identifier, URL(string: "https://example.com/System/Library/coreautha.bundle"))
                .isSystemAuthenticationPrompt
        )
    }

    // MARK: - The end of the prompt settles the hold

    /// A hold must not outlive its prompt: if nothing brings KeeForge back,
    /// the lock it stood for is requested.
    func testThePromptEndingWithoutReactivationFiresLockAtTheDeadline() {
        resignActiveBehindAuthenticationPrompt()

        endAuthenticationPrompt()
        XCTAssertTrue(receivedTriggers.isEmpty, "The reply can arrive just before the reactivation")
        XCTAssertEqual(scheduledDeadlines.map(\.delay), [reactivationGracePeriod])

        letScheduledDeadlinesPass()
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    /// A request that ended without the prompt ever taking the foreground
    /// from anyone the workspace reported is settled the same way.
    func testAPromptThatNeverCameForwardFiresLockAtTheDeadline() {
        resignActiveWhileAPromptIsPending(frontmost: ownApp)

        endAuthenticationPrompt()
        letScheduledDeadlinesPass()

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testThePromptEndingWithAnotherAppInFrontFiresLockAtOnce() {
        resignActiveBehindAuthenticationPrompt()

        frontmostApplication = otherApp
        endAuthenticationPrompt()

        XCTAssertEqual(receivedTriggers, [.appResignedActive])
        XCTAssertTrue(scheduledDeadlines.isEmpty)
    }

    func testReactivationBeforeTheDeadlineDoesNotFireLock() {
        resignActiveBehindAuthenticationPrompt()

        endAuthenticationPrompt()
        becomeActive()
        letScheduledDeadlinesPass()

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// A deadline belongs to the hold it was scheduled for. Passing after
    /// KeeForge was active again, it must not lock behind a later prompt.
    func testAPassedDeadlineDoesNotFireLockBehindALaterPrompt() {
        resignActiveBehindAuthenticationPrompt()
        endAuthenticationPrompt()
        becomeActive()

        resignActiveBehindAuthenticationPrompt()
        letScheduledDeadlinesPass()

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    /// A second request before KeeForge was active again: its prompt takes
    /// over the hold, and its own end settles it.
    func testANewPromptBeforeTheDeadlineKeepsTheHoldUntilItEnds() {
        resignActiveBehindAuthenticationPrompt()
        endAuthenticationPrompt()

        beginAuthenticationPrompt()
        letScheduledDeadlinesPass()
        XCTAssertTrue(receivedTriggers.isEmpty)

        endAuthenticationPrompt()
        letScheduledDeadlinesPass()
        XCTAssertEqual(receivedTriggers, [.appResignedActive])
    }

    func testThePromptEndingWithoutAHeldDeactivationSchedulesNothing() {
        policy = .appDeactivates

        beginAuthenticationPrompt()
        endAuthenticationPrompt()

        XCTAssertTrue(scheduledDeadlines.isEmpty)
        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    private func resignActiveBehindAuthenticationPrompt(
        policy: SettingsService.MacLockPolicy = .appDeactivates
    ) {
        resignActiveWhileAPromptIsPending(frontmost: promptHost, policy: policy)
    }

    /// `frontmost` is what the workspace reports when the deactivation
    /// arrives.
    private func resignActiveWhileAPromptIsPending(
        frontmost: MacLockMonitor.ForegroundApplication?,
        policy: SettingsService.MacLockPolicy = .appDeactivates
    ) {
        self.policy = policy
        beginAuthenticationPrompt()
        frontmostApplication = frontmost
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// What `BiometricService` does around a request: it changes its flag and
    /// posts the change.
    private func beginAuthenticationPrompt() {
        isAuthenticationPromptPending = true
        appCenter.post(name: BiometricService.authenticationInProgressDidChangeNotification, object: nil)
    }

    private func endAuthenticationPrompt() {
        isAuthenticationPromptPending = false
        appCenter.post(name: BiometricService.authenticationInProgressDidChangeNotification, object: nil)
    }

    private func becomeActive() {
        frontmostApplication = ownApp
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func activate(_ application: MacLockMonitor.ForegroundApplication) {
        frontmostApplication = application
        monitor.handleApplicationDidActivate(application)
    }

    private func letScheduledDeadlinesPass() {
        let deadlines = scheduledDeadlines
        scheduledDeadlines = []
        for deadline in deadlines {
            deadline.work()
        }
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
        endAuthenticationPrompt()

        monitor.stop()
        activate(otherApp)
        letScheduledDeadlinesPass()

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
