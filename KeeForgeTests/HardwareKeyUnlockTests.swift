import CryptoKit
import XCTest
@testable import KeeForge

/// Unlocking a database whose composite key includes a YubiKey
/// challenge-response, driven through `DatabaseViewModel` with an emulated key
/// in place of YubiKit.
@MainActor
final class HardwareKeyUnlockTests: XCTestCase {
    private let slotTwoOverNFC = HardwareKeyConfiguration(transport: .nfc, slot: .two)

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    func testUnlockWithYubiKeyOpensDatabaseReadOnly() async throws {
        var requests: [(challenge: Data, configuration: HardwareKeyConfiguration)] = []
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, configuration in
            requests.append((challenge, configuration))
            return YubiKeyEmulator.response(to: challenge)
        }

        await vm.unlock(password: fixture.password)

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state) \(String(describing: vm.openFailure))")
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.configuration, slotTwoOverNFC)
        XCTAssertEqual(
            requests.first?.challenge,
            try ChallengeResponseKey.challenge(forDatabase: fixture.data(in: bundle))
        )
        XCTAssertTrue(vm.sessionUsesHardwareKey)
        XCTAssertTrue(vm.isReadOnly)
        XCTAssertFalse(vm.isFormatReadOnly)
        XCTAssertFalse(vm.isAwaitingHardwareKey)
        XCTAssertTrue(vm.rootGroup?.allEntries.contains { $0.title == "YubiKey Entry" } == true)
    }

    func testSaveIsRefusedAfterYubiKeyUnlock() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, _ in
            YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)

        do {
            try await vm.save()
            XCTFail("A YubiKey session must not save")
        } catch SaveError.databaseIsReadOnly {
        } catch {
            XCTFail("Expected databaseIsReadOnly, got \(error)")
        }
    }

    func testLockEndsTheHardwareKeySession() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, _ in
            YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)

        vm.lock()

        XCTAssertFalse(vm.sessionUsesHardwareKey)
        XCTAssertFalse(vm.isReadOnly)
    }

    func testWrongYubiKeyIsReportedAsCredentialsIncludingTheYubiKey() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, _ in
            YubiKeyEmulator.response(to: challenge, secret: Data("another-yubikey-secr".utf8))
        }

        await vm.unlock(password: fixture.password)

        let failure = try XCTUnwrap(vm.openFailure)
        XCTAssertEqual(failure.errorCode, "auth.invalid_credentials")
        XCTAssertTrue(failure.summary.contains("YubiKey"), failure.summary)
        XCTAssertEqual(vm.failedAttempts, 1)
    }

    /// The case from the issue: the database needs a YubiKey nobody chose.
    func testMissingYubiKeySuggestsHardwareKeyWhereTheDeviceHasOne() async throws {
        var calledResponder = false
        let vm = try makeViewModel(hardwareKey: nil, transports: [.nfc]) { _, _ in
            calledResponder = true
            return Data()
        }

        await vm.unlock(password: fixture.password)

        let failure = try XCTUnwrap(vm.openFailure)
        XCTAssertEqual(failure.errorCode, "auth.invalid_credentials")
        XCTAssertTrue(failure.summary.contains("Hardware Key"), failure.summary)
        XCTAssertFalse(calledResponder)
    }

    func testMissingYubiKeyKeepsThePlainSummaryWithoutAnyTransport() async throws {
        let vm = try makeViewModel(hardwareKey: nil, transports: []) { _, _ in Data() }

        await vm.unlock(password: fixture.password)

        let failure = try XCTUnwrap(vm.openFailure)
        XCTAssertEqual(failure.errorCode, "auth.invalid_credentials")
        XCTAssertFalse(failure.summary.contains("YubiKey"), failure.summary)
    }

    func testCancellingTheYubiKeyRequestLeavesARetryableFailure() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw HardwareKeyError.cancelled
            }
            XCTFail("The request should have been cancelled")
            return Data()
        }

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { vm.isAwaitingHardwareKey }
        vm.cancelHardwareKeyRequest()
        await unlock.value

        let failure = try XCTUnwrap(vm.openFailure)
        XCTAssertEqual(failure.errorCode, "hardware_key.cancelled")
        XCTAssertTrue(failure.canRetryUnlock)
        XCTAssertFalse(failure.countsTowardFailedAttempts)
        XCTAssertEqual(vm.failedAttempts, 0)
        XCTAssertFalse(vm.isAwaitingHardwareKey)
    }

    func testLockWhileWaitingForTheYubiKeyCancelsTheRequest() async throws {
        let vm = try makeViewModel(hardwareKey: HardwareKeyConfiguration(transport: .lightning, slot: .two)) { challenge, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw HardwareKeyError.cancelled
            }
            return YubiKeyEmulator.response(to: challenge)
        }

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { vm.isAwaitingHardwareKey }
        vm.lock()
        await unlock.value

        XCTAssertNil(vm.rootGroup, "The request finishing after the lock must not unlock")
        assertLocked(vm, "the late failure must not replace the lock")
    }

    // A key that answers after the lock anyway: YubiKit can hand back a
    // response it had already read when the cancellation arrived.
    func testLateAnswerAfterLockDoesNotUnlock() async throws {
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.lock()
        key.answer()
        await unlock.value

        assertLocked(vm)
        XCTAssertNil(vm.rootGroup)
        XCTAssertFalse(vm.sessionUsesHardwareKey)
    }

    func testBackgroundingWhileWaitingForTheYubiKeyLocksWhenLockOnBackgroundIsOn() async throws {
        #if os(iOS)
        let savedLockOnBackground = SettingsService.lockOnBackground
        defer { SettingsService.lockOnBackground = savedLockOnBackground }
        SettingsService.lockOnBackground = true
        #endif
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.handleSceneDidEnterBackground()
        key.answer()
        await unlock.value

        assertLocked(vm)
        XCTAssertNil(vm.rootGroup, "A valid answer after backgrounding must not unlock behind the lock")
    }

    #if os(iOS)
    func testBackgroundingWhileWaitingLeavesTheUnlockRunningWhenLockOnBackgroundIsOff() async throws {
        let savedLockOnBackground = SettingsService.lockOnBackground
        defer { SettingsService.lockOnBackground = savedLockOnBackground }
        SettingsService.lockOnBackground = false
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.handleSceneDidEnterBackground()
        key.answer()
        await unlock.value

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state)")
        }
    }
    #endif

    #if os(iOS)
    // With lock-on-background off, a session the key opens while the app is
    // away is a backgrounded session: the return applies the auto-lock timeout.
    func testUnlockFinishingInTheBackgroundAppliesTheAutoLockTimeoutOnReturn() async throws {
        let savedLockOnBackground = SettingsService.lockOnBackground
        let savedAutoLockTimeout = SettingsService.autoLockTimeout
        defer {
            SettingsService.lockOnBackground = savedLockOnBackground
            SettingsService.autoLockTimeout = savedAutoLockTimeout
        }
        SettingsService.lockOnBackground = false
        SettingsService.autoLockTimeout = .immediately
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.handleSceneDidEnterBackground()
        key.answer()
        await unlock.value
        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked while still in the background, got \(vm.state)")
        }
        XCTAssertNil(vm.inactivityTimer, "The timer waits for the return, as for any backgrounded session")

        vm.handleSceneDidBecomeActive()

        assertLocked(vm, "an immediate auto-lock must apply to a session opened in the background")
    }

    func testUnlockFinishingAfterTheReturnIsNotTreatedAsBackgrounded() async throws {
        let savedLockOnBackground = SettingsService.lockOnBackground
        let savedAutoLockTimeout = SettingsService.autoLockTimeout
        defer {
            SettingsService.lockOnBackground = savedLockOnBackground
            SettingsService.autoLockTimeout = savedAutoLockTimeout
        }
        SettingsService.lockOnBackground = false
        SettingsService.autoLockTimeout = .immediately
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.handleSceneDidEnterBackground()
        vm.handleSceneDidBecomeActive()
        key.answer()
        await unlock.value
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state)")
        }
    }
    #endif

    // lock() cancels the request, but a key can still hold its answer; the
    // superseded attempt ending later must not take the next one's Cancel away.
    func testSupersededAttemptLeavesTheNextAttemptsRequestCancellable() async throws {
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let first = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.requestCount == 1 }
        vm.lock()
        XCTAssertFalse(vm.isAwaitingHardwareKey, "The lock ends the wait")
        let second = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.requestCount == 2 }
        key.answer()
        await first.value

        XCTAssertTrue(vm.isAwaitingHardwareKey, "The second request is still waiting for the key")
        vm.cancelHardwareKeyRequest()
        key.answer()
        await second.value

        XCTAssertNil(vm.rootGroup, "Cancel must still reach the second request")
        XCTAssertEqual(vm.openFailure?.errorCode, "hardware_key.cancelled")
    }

    func testCancelWinsOverAnAnswerThatArrivesAfterIt() async throws {
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.cancelHardwareKeyRequest()
        key.answer()
        await unlock.value

        XCTAssertNil(vm.rootGroup)
        XCTAssertEqual(vm.openFailure?.errorCode, "hardware_key.cancelled")
        XCTAssertEqual(vm.failedAttempts, 0)
    }

    func testRemovedYubiKeyIsReportedAsDisconnected() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { _, _ in
            throw HardwareKeyError.disconnected
        }

        await vm.unlock(password: fixture.password)

        XCTAssertEqual(vm.openFailure?.errorCode, "hardware_key.disconnected")
        XCTAssertEqual(vm.openFailure?.category, .hardwareKey)
        XCTAssertEqual(vm.failedAttempts, 0)
    }

    func testKDBX31IsRefusedBeforeTheYubiKeyIsAsked() async throws {
        var calledResponder = false
        let vm = try makeViewModel(
            fixture: .legacyKDBX31,
            hardwareKey: slotTwoOverNFC
        ) { _, _ in
            calledResponder = true
            return Data()
        }

        await vm.unlock(password: KDBXTestFixture.legacyKDBX31.password)

        XCTAssertEqual(vm.openFailure?.errorCode, "hardware_key.unsupported_database")
        XCTAssertFalse(calledResponder)
    }

    /// Quick Launch stores the pre-key for a hardware-key database, so the
    /// biometric path must still ask the YubiKey.
    func testBiometricUnlockAnswersTheChallengeWithTheStoredPreKey() async throws {
        let preKey = try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil)
        var responderCalls = 0
        let vm = try makeViewModel(
            hardwareKey: slotTwoOverNFC,
            biometricKey: preKey
        ) { challenge, _ in
            responderCalls += 1
            return YubiKeyEmulator.response(to: challenge)
        }

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(responderCalls, 1)
        XCTAssertTrue(vm.isReadOnly)
    }

    func testChangingOnlyTheSlotKeepsTheStoredQuickLaunchKey() throws {
        let reference = try TestDatabaseSupport.makeReference(for: fixture.url(in: bundle))
        DatabaseListStore.update(reference)
        defer { KeychainService.deleteCompositeKey(for: reference.id) }
        try requireStoredKey(for: reference.id)

        DatabaseListStore.setHardwareKey(slotTwoOverNFC, for: reference)
        XCTAssertFalse(KeychainService.hasStoredKey(for: reference.id), "Turning the YubiKey on changes what the item means")

        try requireStoredKey(for: reference.id)
        DatabaseListStore.setHardwareKey(HardwareKeyConfiguration(transport: .nfc, slot: .one), for: reference)
        XCTAssertTrue(KeychainService.hasStoredKey(for: reference.id), "A slot change keeps the pre-key")

        DatabaseListStore.setHardwareKey(nil, for: reference)
        XCTAssertFalse(KeychainService.hasStoredKey(for: reference.id), "Turning the YubiKey off changes what the item means")
        XCTAssertNil(DatabaseListStore.databases.first { $0.id == reference.id }?.hardwareKey)
    }

    // MARK: - Helpers

    private var fixture: KDBXTestFixture { .challengeResponse }

    private var bundle: Bundle { Bundle(for: Self.self) }

    private func makeViewModel(
        fixture: KDBXTestFixture = .challengeResponse,
        hardwareKey: HardwareKeyConfiguration?,
        transports: [HardwareKeyConfiguration.Transport] = [.nfc],
        biometricKey: SymmetricKey? = nil,
        respond: @escaping DatabaseViewModel.HardwareKeyResponseOperation
    ) throws -> DatabaseViewModel {
        var reference = try TestDatabaseSupport.makeReference(for: fixture.url(in: bundle))
        reference.hardwareKey = hardwareKey
        return DatabaseViewModel(
            databaseReference: reference,
            biometricCompositeKeyOperation: { _, _ in
                guard let biometricKey else { throw KeychainService.KeychainError.retrieveFailed(errSecItemNotFound) }
                return biometricKey
            },
            hardwareKeyResponseOperation: respond,
            hardwareKeyTransportsProvider: { transports }
        )
    }

    private func requireStoredKey(for databaseID: UUID) throws {
        do {
            try KeychainService.storeCompositeKey(SymmetricKey(size: .bits256), for: databaseID)
        } catch {
            throw XCTSkip("Keychain writes are unavailable in the current test host: \(error)")
        }
    }

    /// A YubiKey that holds its (correct) answers until told to give them,
    /// oldest request first, and ignores cancellation meanwhile.
    @MainActor
    private final class HeldYubiKey {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var requestCount = 0

        var isHolding: Bool { continuations.isEmpty == false }

        var respond: DatabaseViewModel.HardwareKeyResponseOperation {
            { [self] challenge, _ in
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                    requestCount += 1
                }
                return YubiKeyEmulator.response(to: challenge)
            }
        }

        func answer() {
            guard continuations.isEmpty == false else { return }
            continuations.removeFirst().resume()
        }
    }

    private func assertLocked(
        _ vm: DatabaseViewModel,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .locked = vm.state else {
            return XCTFail("Expected locked, got \(vm.state) \(message)", file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition never became true")
    }
}
