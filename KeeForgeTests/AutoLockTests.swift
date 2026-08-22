import XCTest
@testable import KeeForge
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class AutoLockTests: XCTestCase {
    private let fixturePassword = "testpassword123"
    private var savedAutoLockTimeout: SettingsService.AutoLockTimeout!
    private var savedLockOnBackground: Bool!
    private var savedMacLockPolicy: SettingsService.MacLockPolicy!
    private var savedClipboardTimeout: SettingsService.ClipboardTimeout!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        savedAutoLockTimeout = SettingsService.autoLockTimeout
        savedLockOnBackground = SettingsService.lockOnBackground
        savedMacLockPolicy = SettingsService.macLockPolicy
        savedClipboardTimeout = SettingsService.clipboardTimeout
        // The clipboard assertions below race the copy's expiration date, so
        // pin the longest timeout rather than inheriting whatever a previous
        // test left in UserDefaults.
        SettingsService.clipboardTimeout = .oneMinute
    }

    override func tearDown() async throws {
        SettingsService.autoLockTimeout = savedAutoLockTimeout
        SettingsService.lockOnBackground = savedLockOnBackground
        SettingsService.macLockPolicy = savedMacLockPolicy
        SettingsService.clipboardTimeout = savedClipboardTimeout
        // These tests write to the real system pasteboard; do not leave a probe
        // value behind for the rest of the suite (or the simulator).
        clearPasteboard()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    private func clearPasteboard() {
        #if os(iOS)
        UIPasteboard.general.items = []
        #else
        NSPasteboard.general.clearContents()
        #endif
    }

    private var pasteboardString: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    func testLockClearsRootGroup() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.rootGroup)

        vm.lock()

        XCTAssertNil(vm.rootGroup)
    }

    func testLockClearsCompositeKey() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.compositeKey)

        vm.lock()

        XCTAssertNil(vm.compositeKey)
    }

    func testLockSetsStateLocked() async throws {
        let vm = try await makeUnlockedViewModel()
        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked before lock()")
            return
        }

        vm.lock()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after lock()")
            return
        }
    }

    func testLockPreservesSelectedDatabaseReference() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertTrue(vm.hasSavedFile)

        vm.lock()

        XCTAssertTrue(vm.hasSavedFile)
    }

    func testLockClearsSearchText() async throws {
        let vm = try await makeUnlockedViewModel()
        vm.searchText = "test"

        vm.lock()

        XCTAssertEqual(vm.searchText, "")
    }

    func testLockClearsNavigationPath() async throws {
        let vm = try await makeUnlockedViewModel()
        vm.navigationPath.append("something")

        vm.lock()

        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    func testInactivityTimerCreatedWithCorrectInterval() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()

        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 300, accuracy: 0.001)
    }

    func testInactivityTimerThirtySecondsInterval() async throws {
        SettingsService.autoLockTimeout = .thirtySeconds
        let vm = try await makeUnlockedViewModel()

        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 30, accuracy: 0.001)
    }

    func testInactivityTimerCancelledOnLock() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.inactivityTimer)

        vm.lock()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testNeverSettingMeansNoTimer() async throws {
        SettingsService.autoLockTimeout = .never
        let vm = try await makeUnlockedViewModel()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testImmediatelySettingMeansNoForegroundTimer() async throws {
        SettingsService.autoLockTimeout = .immediately
        let vm = try await makeUnlockedViewModel()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testResetInactivityTimerDoesNothingWhenLocked() throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try makeViewModel()

        vm.resetInactivityTimer()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testBackgroundLockEnabledLocksImmediatelyOnBackground() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()

        vm.handleSceneDidEnterBackground()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after backgrounding with background lock enabled")
            return
        }
    }

    func testBackgroundLockEnabledRequiresAuthenticatedResumeForDirtyDraft() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()
        try makeDirty(vm)

        vm.handleSceneDidEnterBackground()

        guard case .unlocked = vm.state else {
            XCTFail("Expected the dirty draft to await a resume decision")
            return
        }
        XCTAssertNotNil(vm.draft)
        XCTAssertTrue(vm.pendingLockRequest?.requiresAuthenticationToContinueEditing == true)
    }

#if os(iOS)
    func testBackgroundLockLeavesCopiedValueOnPasteboard() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()

        ClipboardService.copy("COPY-PROBE-BACKGROUND")
        vm.handleSceneDidEnterBackground()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after backgrounding with background lock enabled")
            return
        }
        // Backgrounding is exactly when the user switches away to paste, so the
        // automatic lock must leave the pasteboard intact.
        XCTAssertEqual(pasteboardString, "COPY-PROBE-BACKGROUND")
    }

    /// The background exemption must not outlive the trip it was written for:
    /// once the user is back in KeeForge, an explicit lock still scrubs.
    func testManualLockAfterBackgroundLockStillScrubsCopiedValue() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()

        ClipboardService.copy("COPY-PROBE-ROUNDTRIP")
        vm.handleSceneDidEnterBackground()
        XCTAssertEqual(pasteboardString, "COPY-PROBE-ROUNDTRIP")

        await vm.unlock(password: fixturePassword)
        vm.lock(manuallyTriggered: true)

        XCTAssertNil(pasteboardString)
    }
#endif

    func testManualLockScrubsCopiedValueFromPasteboard() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()

        ClipboardService.copy("COPY-PROBE-MANUAL")
        vm.lock(manuallyTriggered: true)

        XCTAssertNil(pasteboardString)
    }

    /// The inactivity timeout fires with the app in the foreground — the user
    /// walked away rather than switched away — so it is not exempt.
    func testInactivityLockScrubsCopiedValueFromPasteboard() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()

        ClipboardService.copy("COPY-PROBE-INACTIVITY")
        vm.lockRequest()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after an inactivity lock request")
            return
        }
        XCTAssertNil(pasteboardString)
    }

#if os(macOS)
    /// On the Mac the background entry point is `MacLockMonitor` (screen lock,
    /// screensaver, sleep, user switching), and macOS has neither
    /// `.expirationDate` nor `.localOnly` — so it must never take the iOS
    /// backgrounding exemption.
    func testMacSystemLockScrubsCopiedValueFromPasteboard() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()

        ClipboardService.copy("COPY-PROBE-MAC-SYSTEM-LOCK")
        vm.handleSceneDidEnterBackground()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after a Mac system lock trigger")
            return
        }
        XCTAssertNil(pasteboardString)
    }
#endif

    // The lock-on-background switch and its deferred inactivity check are iOS
    // scene-phase behavior. macOS never defers: `handleSceneDidEnterBackground`
    // is reached only from `MacLockMonitor`, which always locks.
#if os(iOS)
    func testBackgroundLockDisabledPreservesVaultAndResumesRemainingTime() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        XCTAssertEqual(vm.inactivityDeadline, clock.now.addingTimeInterval(300))

        vm.handleSceneDidEnterBackground()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked while backgrounded with background lock disabled")
            return
        }
        XCTAssertNil(vm.inactivityTimer)

        clock.advance(by: 120)
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked after returning before deadline")
            return
        }
        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityDeadline, Date(timeIntervalSince1970: 1_300))
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 180, accuracy: 0.001)
    }

    func testBackgroundLockDisabledLocksAfterDeadlineOnForegroundReturn() async throws {
        SettingsService.autoLockTimeout = .thirtySeconds
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 31)
        vm.handleSceneDidBecomeActive()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after returning after the inactivity deadline")
            return
        }
    }

    func testBackgroundLockDisabledNeverKeepsVaultUnlocked() async throws {
        SettingsService.autoLockTimeout = .never
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 600)
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked with Never timeout and background lock disabled")
            return
        }
        XCTAssertNil(vm.inactivityTimer)
    }

    func testBackgroundLockDisabledImmediatelyLocksOnForegroundReturn() async throws {
        SettingsService.autoLockTimeout = .immediately
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 1)
        vm.handleSceneDidBecomeActive()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked with Immediate timeout after background return")
            return
        }
    }
#endif

    // MARK: - macOS trigger mapping (MacLockMonitor → lock paths)

    #if os(macOS)
    private struct MacTriggerHarness {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let distributedCenter = NotificationCenter()
        let monitor: MacLockMonitor

        @MainActor
        init(viewModel: DatabaseViewModel) {
            monitor = MacLockMonitor(
                notificationCenter: appCenter,
                workspaceNotificationCenter: workspaceCenter,
                distributedNotificationCenter: distributedCenter
            )
            monitor.onLockTriggered = { _ in
                viewModel.handleSceneDidEnterBackground()
            }
            monitor.start()
        }
    }

    private func assertLocked(
        _ vm: DatabaseViewModel,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .locked = vm.state else {
            XCTFail(message, file: file, line: line)
            return
        }
    }

    func testMacScreenLockTriggerLocksUnlockedVault() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)

        assertLocked(vm, "Expected .locked after the screen-lock trigger")
    }

    func testMacScreensaverTriggerLocksUnlockedVault() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.distributedCenter.post(name: MacLockMonitor.screensaverDidStartNotification, object: nil)

        assertLocked(vm, "Expected .locked after the screensaver trigger")
    }

    func testMacSleepTriggerLocksUnlockedVault() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        assertLocked(vm, "Expected .locked after the system-sleep trigger")
    }

    func testMacSessionResignTriggerLocksUnlockedVault() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)

        assertLocked(vm, "Expected .locked after the session-resign trigger")
    }

    /// `lockOnBackground` is an iOS-only setting that macOS never renders, so
    /// a stale `false` in defaults must not disable the Mac lock guarantee.
    func testMacScreenLockTriggerLocksEvenWithBackgroundLockDisabled() async throws {
        SettingsService.lockOnBackground = false
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.distributedCenter.post(name: MacLockMonitor.screenIsLockedNotification, object: nil)

        assertLocked(vm, "Expected .locked after the screen-lock trigger with lockOnBackground off")
    }

    func testMacAppDeactivationDoesNotLockUnderDefaultPolicy() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .screenLockOrSleep
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)

        guard case .unlocked = vm.state else {
            XCTFail("App deactivation must not lock under the default macOS policy")
            return
        }
    }

    func testMacAppDeactivationLocksUnderStrictPolicy() async throws {
        SettingsService.lockOnBackground = true
        SettingsService.macLockPolicy = .appDeactivates
        let vm = try await makeUnlockedViewModel()
        let harness = MacTriggerHarness(viewModel: vm)
        defer { harness.monitor.stop() }

        harness.appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)

        assertLocked(vm, "Expected .locked after app deactivation under the strict policy")
    }
    #endif

    private func makeUnlockedViewModel() async throws -> DatabaseViewModel {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)
        return vm
    }

    private func makeUnlockedViewModel(
        nowProvider: @escaping @Sendable () -> Date
    ) async throws -> DatabaseViewModel {
        let vm = try makeViewModel(nowProvider: nowProvider)
        await vm.unlock(password: fixturePassword)
        return vm
    }

    private func makeViewModel(
        nowProvider: @escaping @Sendable () -> Date = { .now }
    ) throws -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: fixtureURL()),
            nowProvider: nowProvider
        )
    }

    private func makeDirty(_ viewModel: DatabaseViewModel) throws {
        let rootGroup = try XCTUnwrap(viewModel.rootGroup)
        let sessionKey = try XCTUnwrap(viewModel.sessionKey)
        let cleanDraft = DatabaseDraft(
            rootGroup: rootGroup,
            meta: KPMeta(
                recycleBinUUID: rootGroup.recycleBinUUID,
                hasRecycleBinUUIDElement: rootGroup.recycleBinUUID != nil
            ),
            sessionKey: sessionKey
        )
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: rootGroup)
        viewModel.draft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Unsaved", password: "secret")
            )
        )
    }

    private func fixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: AutoLockTests.self))
    }
}

private final class MutableNowProvider: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}
