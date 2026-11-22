import CryptoKit
import XCTest
import KDBXKit
@testable import KeeForge

#if os(iOS)
import CoreNFC
#endif

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

    func testHardwareKeyTransportsMatchThePlatform() {
        XCTAssertEqual(HardwareKeyConfiguration.Transport.allCases, [.nfc, .usb])
        #if os(macOS)
        XCTAssertEqual(HardwareKeyService.availableTransports, [.usb])
        #else
        XCTAssertTrue(HardwareKeyService.availableTransports.allSatisfy { $0 == .nfc })
        #endif
    }

    func testPromptFollowsTheTransport() {
        XCTAssertEqual(HardwareKeyService.prompt(for: .nfc), String(localized: "Hold your YubiKey near the top of your device."))
        XCTAssertEqual(HardwareKeyService.prompt(for: .usb), String(localized: "Touch your YubiKey if it flashes."))
    }

    func testTransportThisDeviceLacksIsRefusedBeforeAnyRequest() async {
        #if os(macOS)
        let unreachable = HardwareKeyConfiguration(transport: .nfc, slot: .one)
        #else
        let unreachable = HardwareKeyConfiguration(transport: .usb, slot: .one)
        #endif
        do {
            _ = try await HardwareKeyService.response(to: Data(count: 64), using: unreachable)
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? HardwareKeyError, .unavailable)
        }
    }

    #if os(iOS)
    func testAppDeclaresNFCWithoutExternalAccessoryProtocols() throws {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols"))
        let identifiers = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: "com.apple.developer.nfc.readersession.iso7816.select-identifiers"
        ) as? [String])
        XCTAssertEqual(identifiers, ["A000000527200101", "A0000005272001"])
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription"))
    }

    func testDisconnectMapsNFCUserCancellationAndTimeoutForTheUnlockUI() {
        let cancellation = NSError(
            domain: NFCReaderError.errorDomain,
            code: NFCReaderError.Code.readerSessionInvalidationErrorUserCanceled.rawValue
        )
        let timeout = NSError(
            domain: NFCReaderError.errorDomain,
            code: NFCReaderError.Code.readerSessionInvalidationErrorSessionTimeout.rawValue
        )

        XCTAssertEqual(HardwareKeyErrorMapper.disconnectError(cancellation), .cancelled)
        XCTAssertEqual(HardwareKeyErrorMapper.disconnectError(timeout), .timedOut)
        XCTAssertEqual(HardwareKeyErrorMapper.disconnectError(nil), .disconnected)
    }
    #endif

    func testUnlockWithYubiKeyOpensDatabaseForEditing() async throws {
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
        XCTAssertFalse(vm.isReadOnly)
        XCTAssertFalse(vm.isAwaitingHardwareKey)
        XCTAssertTrue(vm.rootGroup?.allEntries.contains { $0.title == "YubiKey Entry" } == true)
    }

    func testYubiKeyUnlockLeavesTheMasterKeySummaryUnknown() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, _ in
            YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)
        XCTAssertTrue(vm.sessionUsesHardwareKey)
        XCTAssertNil(vm.masterKeyComposition)
    }

    /// A save keeps the KDF salt the YubiKey answered, so the saved file
    /// asks the same challenge and the same key opens it without a new touch.
    func testSaveKeepsTheChallengeSoTheYubiKeyStillOpensTheFile() async throws {
        let reference = try makeWritableCopy()
        let original = try Data(contentsOf: try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: reference)))
        var requests = 0
        let vm = makeViewModel(reference: reference) { challenge, _ in
            requests += 1
            return YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)
        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state) \(String(describing: vm.openFailure))")
        }
        let groupID = try XCTUnwrap(vm.visibleRootGroup?.id)

        _ = try vm.createEntry(parentGroupID: groupID, draft: EntryDraftPayload(title: "Saved With YubiKey"))
        try await vm.save()

        XCTAssertEqual(requests, 1, "Saving asks the YubiKey nothing")
        let saved = try Data(contentsOf: try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: reference)))
        XCTAssertNotEqual(saved, original)
        XCTAssertEqual(try ChallengeResponseKey.challenge(forDatabase: saved),
                       try ChallengeResponseKey.challenge(forDatabase: original))
        XCTAssertNotEqual(try KDBXContainer.readHeader(from: saved).masterSeed,
                          try KDBXContainer.readHeader(from: original).masterSeed)

        let reopened = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await reopened.unlock(password: fixture.password)
        XCTAssertTrue(reopened.rootGroup?.allEntries.contains { $0.title == "Saved With YubiKey" } == true)
    }

    func testWriteWithAYubiKeyKeyRefusesASaltItDidNotAnswer() throws {
        let data = try fixture.data(in: bundle)
        let challenge = try ChallengeResponseKey.challenge(forDatabase: data)
        let preKey = try KDBXCrypto.preKey(password: fixture.password, keyFileData: nil)
        let key = ChallengeResponseKey.compositeKey(
            preKey: preKey, response: YubiKeyEmulator.response(to: challenge), challenge: challenge
        )
        let opened = try KDBXParser.parse(data: data, compositeKey: key, sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp)
        var otherSalt = opened.header
        otherSalt.kdfParameters["S"] = .bytes(Data(repeating: 9, count: 32))

        XCTAssertEqual(ChallengeResponseKey.kdfSaltRotation(compositeKey: key), .keep)
        XCTAssertEqual(ChallengeResponseKey.kdfSaltRotation(compositeKey: preKey), .rotate)
        XCTAssertThrowsError(try KDBXWriter.write(
            rootGroup: opened.rootGroup, meta: opened.meta, compositeKey: key, header: otherSalt,
            sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp
        )) { XCTAssertEqual($0 as? HardwareKeyError, .challengeChanged) }
    }

    /// Changing the password keeps the YubiKey: the key answers the pinned
    /// challenge once more and the new file opens with the new password and it.
    func testChangingThePasswordKeepsTheYubiKey() async throws {
        let reference = try makeWritableCopy()
        var requests: [Data] = []
        let vm = makeViewModel(reference: reference) { challenge, _ in
            requests.append(challenge)
            return YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)

        try await vm.changeMasterKey(newPassword: "new-password", newKeyFileData: nil,
                                     newKeyFileBookmarkData: nil, newKeyFileFilename: nil)

        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests.first, requests.last, "The change draws a new salt for the key to answer")
        let saved = try Data(contentsOf: try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: reference)))
        XCTAssertEqual(try ChallengeResponseKey.challenge(forDatabase: saved), requests.last)
        XCTAssertNil(vm.masterKeyComposition)
        XCTAssertTrue(vm.sessionUsesHardwareKey)
        let reopened = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await reopened.unlock(password: "new-password")
        guard case .unlocked = reopened.state else {
            return XCTFail("Expected unlocked, got \(reopened.state) \(String(describing: reopened.openFailure))")
        }
    }

    func testAddingAYubiKeyToAPasswordDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("test.kdbx")
        try FileManager.default.copyItem(at: KDBXTestFixture.test.url(in: bundle), to: copy)
        let reference = try TestDatabaseSupport.makeReference(for: copy)
        DatabaseListStore.testUpsert(reference)
        let vm = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await vm.unlock(password: KDBXTestFixture.test.password)
        XCTAssertFalse(vm.sessionUsesHardwareKey)

        try await vm.changeMasterKey(newPassword: "with-yubikey", newKeyFileData: nil, newKeyFileBookmarkData: nil,
                                     newKeyFileFilename: nil, newHardwareKey: .set(slotTwoOverNFC))

        XCTAssertTrue(vm.sessionUsesHardwareKey)
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }?.hardwareKey, slotTwoOverNFC)
        let updated = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        let passwordOnly = makeViewModel(reference: { var r = updated; r.hardwareKey = nil; return r }()) { _, _ in
            XCTFail("No YubiKey configured"); return Data()
        }
        await passwordOnly.unlock(password: "with-yubikey")
        if case .unlocked = passwordOnly.state { XCTFail("The password alone must not open it any more") }
        let reopened = makeViewModel(reference: updated) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await reopened.unlock(password: "with-yubikey")
        guard case .unlocked = reopened.state else {
            return XCTFail("Expected unlocked, got \(reopened.state) \(String(describing: reopened.openFailure))")
        }
    }

    func testRemovingTheYubiKeyLeavesAPasswordDatabase() async throws {
        let reference = try makeWritableCopy()
        let vm = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await vm.unlock(password: fixture.password)

        try await vm.changeMasterKey(newPassword: "no-yubikey", newKeyFileData: nil, newKeyFileBookmarkData: nil,
                                     newKeyFileFilename: nil, newHardwareKey: .set(nil))

        XCTAssertFalse(vm.sessionUsesHardwareKey)
        let updated = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertNil(updated.hardwareKey)
        let reopened = makeViewModel(reference: updated) { _, _ in XCTFail("No YubiKey any more"); return Data() }
        await reopened.unlock(password: "no-yubikey")
        guard case .unlocked = reopened.state else {
            return XCTFail("Expected unlocked, got \(reopened.state) \(String(describing: reopened.openFailure))")
        }
    }

    /// A database created with a YubiKey carries the salt the key answered
    /// and opens with the password and that key only.
    func testNewDatabaseWithAYubiKeyOpensWithIt() async throws {
        var asked: [Data] = []
        let creation = DatabaseCreationViewModel(
            hardwareKeyTransports: [.nfc],
            hardwareKeyResponse: { challenge, configuration in
                XCTAssertEqual(configuration, self.slotTwoOverNFC)
                asked.append(challenge)
                return YubiKeyEmulator.response(to: challenge)
            }
        )
        creation.databaseName = "With YubiKey"
        creation.password = "created"
        creation.confirmPassword = "created"
        creation.hardwareKeyChoice = slotTwoOverNFC

        let didPrepare = await creation.prepareForExport()

        XCTAssertTrue(didPrepare, creation.creationError ?? creation.validationError ?? "")
        let bytes = creation.preparedEncryptedBytes
        XCTAssertEqual(asked, [try ChallengeResponseKey.challenge(forDatabase: bytes)])
        let preKey = try KDBXCrypto.preKey(password: "created", keyFileData: nil)
        XCTAssertThrowsError(try KDBXParser.parse(data: bytes, compositeKey: KDBXCrypto.compositeKey(password: "created"),
                                                  sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp))
        let challenge = try ChallengeResponseKey.challenge(forDatabase: bytes)
        let key = ChallengeResponseKey.compositeKey(preKey: preKey, response: YubiKeyEmulator.response(to: challenge),
                                                    challenge: challenge)
        XCTAssertNoThrow(try KDBXParser.parse(data: bytes, compositeKey: key, sessionKey: SymmetricKey(size: .bits256),
                                              kdfPolicy: .mainApp))
    }

    func testNewDatabaseMayUseAYubiKeyAlone() async {
        let creation = DatabaseCreationViewModel(hardwareKeyTransports: [.nfc]) { challenge, _ in
            YubiKeyEmulator.response(to: challenge)
        }
        creation.databaseName = "YubiKey Only"
        creation.hardwareKeyChoice = slotTwoOverNFC

        let didPrepare = await creation.prepareForExport()

        XCTAssertTrue(didPrepare, creation.creationError ?? creation.validationError ?? "")
    }

    func testYubiKeyAloneIsAValidNewMasterKey() async throws {
        let reference = try makeWritableCopy()
        let vm = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await vm.unlock(password: fixture.password)

        try await vm.changeMasterKey(newPassword: nil, newKeyFileData: nil,
                                     newKeyFileBookmarkData: nil, newKeyFileFilename: nil)

        let reopened = makeViewModel(reference: reference) { challenge, _ in YubiKeyEmulator.response(to: challenge) }
        await reopened.unlock(password: "")
        guard case .unlocked = reopened.state else {
            return XCTFail("Expected unlocked, got \(reopened.state) \(String(describing: reopened.openFailure))")
        }
    }

    func testLockEndsTheHardwareKeySession() async throws {
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC) { challenge, _ in
            YubiKeyEmulator.response(to: challenge)
        }
        await vm.unlock(password: fixture.password)

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state): \(String(describing: vm.openFailure))")
        }
        XCTAssertTrue(vm.sessionUsesHardwareKey)

        vm.lock()

        XCTAssertFalse(vm.sessionUsesHardwareKey)
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
        XCTAssertFalse(vm.didManuallyLock, "The iOS Cancel ends only the YubiKey request, not the session")
    }

    /// The opening's own Cancel ends the whole attempt, YubiKey request included.
    func testCancellingTheUnlockAttemptWhileWaitingForTheYubiKeyLocks() async throws {
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        XCTAssertTrue(vm.cancelUnlockAttempt())
        key.answer()
        await unlock.value

        assertLocked(vm)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(vm.openFailure)
        XCTAssertFalse(vm.isAwaitingHardwareKey)
        XCTAssertTrue(vm.didManuallyLock)
    }

    func testLockWhileWaitingForTheYubiKeyCancelsTheRequest() async throws {
        let vm = try makeViewModel(hardwareKey: HardwareKeyConfiguration(transport: .nfc, slot: .two)) { challenge, _ in
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

    func testDatabaseTransitionCancelsUnlockAndIgnoresALateYubiKeyAnswer() async throws {
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)
        let routing = AppRoutingCoordinator()
        let unlock = Task { await vm.unlock(password: fixture.password) }
        defer {
            vm.lock()
            key.answer()
            unlock.cancel()
        }
        try await waitUntil { key.isHolding }
        guard key.isHolding else { return XCTFail("The unlock never reached the held YubiKey request") }
        XCTAssertEqual(vm.state, .unlocking)

        routing.requestDatabaseTransition(to: .close, from: vm)
        key.answer()
        await unlock.value

        assertLocked(vm)
        guard case .close? = routing.completeDatabaseTransition(from: vm) else {
            return XCTFail("Closing should cancel the unlock and retain its destination")
        }
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

    // Backgrounding ends the grace period, so an unlock that finishes while
    // the app is still away must not open one for the return.
    func testUnlockFinishingInTheBackgroundOpensNoAuthenticationGracePeriod() async throws {
        let savedLockOnBackground = SettingsService.lockOnBackground
        let savedAutoLockTimeout = SettingsService.autoLockTimeout
        let savedGracePeriod = SettingsService.authenticationGracePeriod
        defer {
            SettingsService.lockOnBackground = savedLockOnBackground
            SettingsService.autoLockTimeout = savedAutoLockTimeout
            SettingsService.authenticationGracePeriod = savedGracePeriod
        }
        SettingsService.lockOnBackground = false
        SettingsService.autoLockTimeout = .never
        SettingsService.authenticationGracePeriod = .fiveMinutes
        let key = HeldYubiKey()
        let vm = try makeViewModel(hardwareKey: slotTwoOverNFC, respond: key.respond)

        let unlock = Task { await vm.unlock(password: fixture.password) }
        try await waitUntil { key.isHolding }
        vm.handleSceneDidEnterBackground()
        key.answer()
        await unlock.value
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            return XCTFail("Expected unlocked, got \(vm.state)")
        }
        XCTAssertFalse(vm.secretAccess.isWithinGracePeriod)
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
    }

    func testChangingOnlyTheSlotKeepsTheStoredQuickLaunchKey() throws {
        let reference = try TestDatabaseSupport.makeReference(for: fixture.url(in: bundle))
        DatabaseListStore.testUpsert(reference)
        defer { KeychainService.deleteCompositeKey(for: reference.id) }
        try requireStoredKey(for: reference.id)

        DatabaseListStore.setHardwareKey(slotTwoOverNFC, for: reference)
        XCTAssertFalse(KeychainService.hasStoredKey(for: reference.id), "Turning the YubiKey on changes what the item means")

        try requireStoredKey(for: reference.id)
        let withHardware = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        DatabaseListStore.setHardwareKey(HardwareKeyConfiguration(transport: .nfc, slot: .one), for: withHardware)
        XCTAssertTrue(KeychainService.hasStoredKey(for: reference.id), "A slot change keeps the pre-key")

        let withOtherSlot = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        DatabaseListStore.setHardwareKey(nil, for: withOtherSlot)
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
                return QuickUnlockKeys(storedKey: biometricKey)
            },
            hardwareKeyResponseOperation: respond,
            hardwareKeyTransportsProvider: { transports }
        )
    }

    /// The fixture copied to its own folder with `slotTwoOverNFC`, so a save
    /// never touches the bundle.
    private func makeWritableCopy() throws -> DatabaseReference {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("challenge-response.kdbx")
        try FileManager.default.copyItem(at: fixture.url(in: bundle), to: copy)
        var reference = try TestDatabaseSupport.makeReference(for: copy)
        reference.hardwareKey = slotTwoOverNFC
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    private func makeViewModel(
        reference: DatabaseReference,
        respond: @escaping DatabaseViewModel.HardwareKeyResponseOperation
    ) -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: reference,
            biometricCompositeKeyOperation: { _, _ in throw KeychainService.KeychainError.retrieveFailed(errSecItemNotFound) },
            hardwareKeyResponseOperation: respond,
            hardwareKeyTransportsProvider: { [.nfc] }
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
