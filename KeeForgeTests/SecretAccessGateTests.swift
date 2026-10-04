import XCTest
@testable import KeeForge

/// The recent-authentication grace period on its own: what opens it, how long
/// it lasts, and what ends it.
@MainActor
final class SecretAccessGateTests: XCTestCase {
    func testAlwaysAskRequiresAuthenticationRightAfterAnAuthentication() {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)

        harness.gate.noteSuccessfulAuthentication()

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testNothingIsGrantedBeforeAnAuthentication() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testAnAuthenticationOpensTheGracePeriodForTheSelectedDuration() throws {
        for gracePeriod in SettingsService.AuthenticationGracePeriod.allCases where gracePeriod != .alwaysAsk {
            let duration = try XCTUnwrap(gracePeriod.duration)
            let harness = SecretAccessGateHarness(gracePeriod: gracePeriod)
            harness.gate.noteSuccessfulAuthentication()

            harness.advance(by: duration - .seconds(1))
            XCTAssertFalse(harness.gate.requiresAuthentication, "\(gracePeriod) ended early")

            harness.advance(by: .seconds(1))
            XCTAssertTrue(harness.gate.requiresAuthentication, "\(gracePeriod) outlived its duration")
        }
    }

    func testRevealingInsideTheGracePeriodDoesNotExtendIt() {
        let harness = SecretAccessGateHarness(gracePeriod: .thirtySeconds)
        harness.gate.noteSuccessfulAuthentication()

        harness.advance(by: .seconds(20))
        XCTAssertFalse(harness.gate.requiresAuthentication)
        harness.advance(by: .seconds(20))

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testASuccessfulPromptRefreshesTheGracePeriod() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .thirtySeconds)
        harness.gate.noteSuccessfulAuthentication()
        harness.advance(by: .seconds(40))
        XCTAssertTrue(harness.gate.requiresAuthentication)

        try await harness.gate.authenticate(reason: "View password")

        XCTAssertEqual(harness.promptReasons, ["View password"])
        harness.advance(by: .seconds(29))
        XCTAssertFalse(harness.gate.requiresAuthentication)
        harness.advance(by: .seconds(1))
        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testAFailedPromptNeverStartsAGracePeriod() async {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.promptSucceeds = false

        await assertPromptFails(harness)

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testAFailedPromptEndsARunningGracePeriod() async {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()
        harness.promptSucceeds = false

        await assertPromptFails(harness)

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testInvalidatingEndsTheGracePeriod() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()

        harness.gate.invalidate()

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    /// A lock that lands while the prompt is still up wins over its answer.
    func testAnInvalidationDuringThePromptLeavesNoGracePeriod() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.duringPrompt = { [unowned harness] in harness.gate.invalidate() }

        try await harness.gate.authenticate(reason: "Copy password")

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testSwitchingToAlwaysAskAppliesImmediately() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()

        harness.gracePeriod = .alwaysAsk

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    func testShorteningTheGracePeriodAppliesImmediately() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()
        harness.advance(by: .seconds(45))

        harness.gracePeriod = .thirtySeconds

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    /// The grant is gone, not hidden: picking the old period again in the
    /// same visit to Settings, with no reveal or copy in between, must not
    /// bring it back.
    func testSwitchingToAlwaysAskAndBackTakesANewAuthentication() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()

        harness.gracePeriod = .alwaysAsk
        harness.gracePeriod = .fiveMinutes

        XCTAssertTrue(harness.gate.requiresAuthentication)
        try await harness.gate.authenticate(reason: "View password")
        XCTAssertFalse(harness.gate.requiresAuthentication)
    }

    /// 45 seconds in, 30 Seconds has already run out. Going back to
    /// 5 Minutes must not revive the rest of the original grant.
    func testShorteningPastTheElapsedTimeAndLengtheningAgainTakesANewAuthentication() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()
        harness.advance(by: .seconds(45))

        harness.gracePeriod = .thirtySeconds
        harness.gracePeriod = .fiveMinutes

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    /// A shorter period that has not run out yet keeps counting from the
    /// original authentication, and stays the limit after lengthening.
    func testAShortenedGrantKeepsTheShorterLimitAfterLengtheningAgain() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.gate.noteSuccessfulAuthentication()
        harness.advance(by: .seconds(20))

        harness.gracePeriod = .oneMinute
        harness.gracePeriod = .fiveMinutes

        harness.advance(by: .seconds(39))
        XCTAssertFalse(harness.gate.requiresAuthentication, "One minute had not run out")
        harness.advance(by: .seconds(1))
        XCTAssertTrue(harness.gate.requiresAuthentication, "The grant outlived the one minute it was cut to")
    }

    /// The gate also tightens when it is asked, for a setting written
    /// without telling it.
    func testAnUnannouncedTighteningStillSticksOnceTheGateWasAsked() {
        let harness = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        harness.announcesSettingChanges = false
        harness.gate.noteSuccessfulAuthentication()

        harness.gracePeriod = .alwaysAsk
        XCTAssertTrue(harness.gate.requiresAuthentication)
        harness.gracePeriod = .fiveMinutes

        XCTAssertTrue(harness.gate.requiresAuthentication)
    }

    /// One gate per session: a changed setting has to reach all of them.
    func testAChangedSettingReachesEveryLiveGate() {
        let first = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        let second = SecretAccessGateHarness(gracePeriod: .fiveMinutes)
        first.gate.noteSuccessfulAuthentication()
        second.gate.noteSuccessfulAuthentication()
        first.announcesSettingChanges = false
        first.gracePeriod = .alwaysAsk

        second.gracePeriod = .alwaysAsk
        first.gracePeriod = .fiveMinutes
        second.gracePeriod = .fiveMinutes

        XCTAssertTrue(first.gate.requiresAuthentication)
        XCTAssertTrue(second.gate.requiresAuthentication)
    }

    /// Otherwise whoever holds an unlocked app could pick a longer period in
    /// Settings and skip the prompt it was about to get.
    func testLengtheningTheGracePeriodTakesANewAuthentication() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        harness.gate.noteSuccessfulAuthentication()
        harness.gracePeriod = .fiveMinutes
        XCTAssertTrue(harness.gate.requiresAuthentication, "Always Ask was in force at the authentication")

        harness.gracePeriod = .thirtySeconds
        try await harness.gate.authenticate(reason: "View password")
        harness.gracePeriod = .fiveMinutes
        harness.advance(by: .seconds(40))
        XCTAssertTrue(harness.gate.requiresAuthentication, "The grant was earned at 30 seconds")

        try await harness.gate.authenticate(reason: "View password")
        harness.advance(by: .seconds(40))
        XCTAssertFalse(harness.gate.requiresAuthentication)
    }

    func testADeviceWithoutOwnerAuthenticationIsNeverAsked() {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        harness.isAuthenticationAvailable = false

        XCTAssertFalse(harness.gate.requiresAuthentication)
    }

    private func assertPromptFails(
        _ harness: SecretAccessGateHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await harness.gate.authenticate(reason: "View password")
            XCTFail("A declined prompt must throw", file: file, line: line)
        } catch {
            XCTAssertTrue(error is SecretAccessGateHarness.PromptDeclined, file: file, line: line)
        }
    }
}

/// The grace period across one database session: unlocking opens it, and
/// every way the session ends or leaves the foreground closes it.
@MainActor
final class SecretAccessSessionTests: XCTestCase {
    private let fixturePassword = "testpassword123"
    private var savedLockOnBackground: Bool!
    private var savedAutoLockTimeout: SettingsService.AutoLockTimeout!
    private var savedGracePeriod: SettingsService.AuthenticationGracePeriod!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        savedLockOnBackground = SettingsService.lockOnBackground
        savedAutoLockTimeout = SettingsService.autoLockTimeout
        savedGracePeriod = SettingsService.authenticationGracePeriod
    }

    override func tearDown() async throws {
        SettingsService.lockOnBackground = savedLockOnBackground
        SettingsService.autoLockTimeout = savedAutoLockTimeout
        SettingsService.authenticationGracePeriod = savedGracePeriod
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    func testUnlockingOpensTheGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        XCTAssertFalse(vm.secretAccess.requiresAuthentication)
        XCTAssertTrue(harness.promptReasons.isEmpty)
    }

    func testUnlockingWithAlwaysAskStillRequiresAuthentication() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let vm = try await makeUnlockedViewModel(harness)

        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    func testAFailedUnlockOpensNoGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try makeViewModel(harness)

        await vm.unlock(password: "not the password")

        guard case .error = vm.state else {
            return XCTFail("Expected the wrong password to fail, got \(vm.state)")
        }
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    /// A wrong password on a session that still holds a grant is a failed
    /// authentication like any other.
    func testAFailedUnlockEndsARunningGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        await vm.unlock(password: "not the password")

        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    func testLockEndsTheGracePeriodWithoutALockRequest() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        vm.lock()

        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    func testLockingEndsTheGracePeriodAndUnlockingAgainOpensANewOne() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        vm.lockRequest(manuallyTriggered: true)

        guard case .locked = vm.state else {
            return XCTFail("Expected locked, got \(vm.state)")
        }
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)

        await vm.unlock(password: fixturePassword)
        XCTAssertFalse(vm.secretAccess.requiresAuthentication)
    }

    func testTheInactivityTimeoutEndsTheGracePeriod() async throws {
        SettingsService.autoLockTimeout = .thirtySeconds
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        try XCTUnwrap(vm.inactivityTimer).fire()
        try await waitUntil { vm.state == .locked }

        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    /// The session stays open while the editor's prompt is up, so the lock
    /// itself cannot be what ends the grace period.
    func testALockDeferredByUnsavedWorkStillEndsTheGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)
        vm.setEditorHasUnsavedChanges(true, editorID: UUID())

        vm.lockRequest()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected the unsaved editor to defer the lock, got \(vm.state)")
        }
        XCTAssertNotNil(vm.pendingLockRequest)
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    func testKeepEditingAfterAnAutomaticLockAuthenticatesAndReopensTheGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)
        vm.setEditorHasUnsavedChanges(true, editorID: UUID())
        vm.lockRequest()

        await vm.continueEditingAfterLockRequest()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected the session to stay open, got \(vm.state)")
        }
        XCTAssertEqual(harness.promptReasons.count, 1)
        XCTAssertNil(vm.pendingLockRequest)
        XCTAssertFalse(vm.secretAccess.requiresAuthentication)
    }

    func testDecliningKeepEditingAfterAnAutomaticLockLocksWithoutAGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)
        vm.setEditorHasUnsavedChanges(true, editorID: UUID())
        vm.lockRequest()
        harness.promptSucceeds = false

        await vm.continueEditingAfterLockRequest()

        guard case .locked = vm.state else {
            return XCTFail("Expected locked, got \(vm.state)")
        }
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    func testKeepEditingAfterAManualLockDoesNotReopenTheGracePeriod() async throws {
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)
        vm.setEditorHasUnsavedChanges(true, editorID: UUID())
        vm.lockRequest(manuallyTriggered: true)

        await vm.continueEditingAfterLockRequest()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected the session to stay open, got \(vm.state)")
        }
        XCTAssertTrue(harness.promptReasons.isEmpty)
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }

    #if os(iOS)
    // macOS reaches the background handler only from a lock trigger, which
    // the lock tests above cover; on iOS the session can survive it.
    func testBackgroundingEndsTheGracePeriodEvenWhenTheSessionStaysUnlocked() async throws {
        SettingsService.lockOnBackground = false
        SettingsService.autoLockTimeout = .never
        let harness = SecretAccessGateHarness()
        let vm = try await makeUnlockedViewModel(harness)

        vm.handleSceneDidEnterBackground()
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected the session to survive the background, got \(vm.state)")
        }
        XCTAssertTrue(vm.secretAccess.requiresAuthentication)
    }
    #endif

    /// The setting as shipped, through the gate a session builds for itself:
    /// a second session never inherits the first one's grace period.
    func testEachSessionKeepsItsOwnGracePeriod() async throws {
        SettingsService.authenticationGracePeriod = .fiveMinutes
        let first = DatabaseViewModel(databaseReference: try makeReference())
        await first.unlock(password: fixturePassword)
        XCTAssertTrue(first.secretAccess.isWithinGracePeriod)

        let second = DatabaseViewModel(databaseReference: try makeReference())

        XCTAssertFalse(second.secretAccess.isWithinGracePeriod)
        first.lockRequest(force: true)
        XCTAssertFalse(first.secretAccess.isWithinGracePeriod)
    }

    /// The path the Settings picker takes, against the gate a session builds
    /// for itself: Always Ask and back, with no reveal or copy in between.
    func testPickingAlwaysAskAndBackInSettingsEndsAnOpenSessionsGracePeriod() async throws {
        SettingsService.authenticationGracePeriod = .fiveMinutes
        let vm = DatabaseViewModel(databaseReference: try makeReference())
        addTeardownBlock { @MainActor in
            vm.lockRequest(force: true)
        }
        await vm.unlock(password: fixturePassword)
        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state)")
        }
        let settings = AppSettingsViewModel()

        settings.authenticationGracePeriod = .alwaysAsk
        settings.authenticationGracePeriod = .fiveMinutes

        XCTAssertEqual(SettingsService.authenticationGracePeriod, .fiveMinutes)
        XCTAssertFalse(vm.secretAccess.isWithinGracePeriod)
    }

    func testTheShippedDefaultOpensNoGracePeriod() async throws {
        UserDefaults.standard.removeObject(forKey: "KeeForge.authenticationGracePeriod")
        let vm = DatabaseViewModel(databaseReference: try makeReference())

        await vm.unlock(password: fixturePassword)

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state)")
        }
        XCTAssertFalse(vm.secretAccess.isWithinGracePeriod)
        vm.lockRequest(force: true)
    }

    // MARK: - Helpers

    private func makeReference() throws -> DatabaseReference {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        return try TestDatabaseSupport.makeReference(for: url)
    }

    private func makeViewModel(_ harness: SecretAccessGateHarness) throws -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: try makeReference(),
            deviceOwnerAuthAvailabilityCheck: { true },
            secretAccess: harness.gate
        )
    }

    private func makeUnlockedViewModel(_ harness: SecretAccessGateHarness) async throws -> DatabaseViewModel {
        let vm = try makeViewModel(harness)
        addTeardownBlock { @MainActor in
            vm.lockRequest(force: true)
        }
        await vm.unlock(password: fixturePassword)
        return try XCTUnwrap(vm.state == .unlocked ? vm : nil, "The fixture did not unlock: \(vm.state)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition never became true")
    }
}
