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

    override func setUp() async throws {
        try await super.setUp()
        appCenter = NotificationCenter()
        workspaceCenter = NotificationCenter()
        distributedCenter = NotificationCenter()
        policy = .screenLockOrSleep
        receivedTriggers = []
        becameActiveCount = 0
        remainingHostWindows = 0

        monitor = MacLockMonitor(
            notificationCenter: appCenter,
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter,
            lockPolicyProvider: { [weak self] in self?.policy ?? .screenLockOrSleep },
            remainingWindowCounter: { [weak self] _ in self?.remainingHostWindows ?? 0 }
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
