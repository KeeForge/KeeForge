#if os(macOS)
import RemoteFileTransports
import XCTest
@testable import KeeForge

@MainActor
final class MacUnlockFormModelTests: XCTestCase {
    private let wrongKey = DatabaseOpenFailure(title: "Couldn't Unlock Database", summary: "Wrong key", technicalDetails: "",
        errorCode: "auth.invalid_credentials", category: .authentication, countsTowardFailedAttempts: true,
        canChooseDifferentFile: false)
    private let missingFile = DatabaseOpenFailure(title: "Database File Unavailable", summary: "Gone", technicalDetails: "",
        errorCode: "file.not_found", category: .fileAccess, countsTowardFailedAttempts: false, canChooseDifferentFile: true)
    private let signInNeeded = DatabaseOpenFailure(title: "Reconnect Cloud Account", summary: "Sign in", technicalDetails: "",
        errorCode: "cloud.not_authenticated", category: .cloud, countsTowardFailedAttempts: false,
        canChooseDifferentFile: false)

    // MARK: - Layout and submit gate

    func testLayoutFollowsBiometricAvailability() {
        let (session, _, model) = makeModel()

        session.biometricUnlockAvailability = .available
        XCTAssertEqual(model.layout, .biometricPrimary)
        XCTAssertFalse(model.showsBiometricUnavailableNote)
        XCTAssertTrue(model.canUnlockWithBiometrics)

        session.biometricUnlockAvailability = .unavailableWithStoredKey
        XCTAssertEqual(model.layout, .passwordPrimary)
        XCTAssertTrue(model.showsBiometricUnavailableNote)
        XCTAssertFalse(model.canUnlockWithBiometrics)

        session.biometricUnlockAvailability = .none
        XCTAssertEqual(model.layout, .passwordPrimary)
        XCTAssertFalse(model.showsBiometricUnavailableNote)
    }

    func testTouchIDIsOffWhileAnOpenIsRunning() {
        let (session, _, model) = makeModel()
        session.biometricUnlockAvailability = .available
        session.state = .unlocking

        XCTAssertFalse(model.canUnlockWithBiometrics)
    }

    func testCanSubmitNeedsAKeyPartAndNoOpenOrRead() async {
        let suspension = KeyFileReadSuspension()
        let (session, _, model) = makeModel(readData: { _ in await suspension.wait() })
        XCTAssertFalse(model.canSubmit, "Nothing typed or picked")

        model.password = "secret"
        XCTAssertTrue(model.canSubmit)
        session.state = .unlocking
        XCTAssertFalse(model.canSubmit, "An open is running")
        session.state = .locked
        model.password = ""

        let reading = Task { await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/vault.keyx")) }
        await suspension.waitUntilStarted()
        XCTAssertTrue(model.isLoadingKeyFile)
        XCTAssertFalse(model.canSubmit, "The key file is still loading")
        await suspension.resolve(Data([7]))
        await reading.value

        XCTAssertEqual(model.keyLine, .picked("vault.keyx"))
        XCTAssertTrue(model.canSubmit, "A key file alone is a key part")
    }

    // MARK: - Hardware key

    func testHardwareKeyOffersBothUSBSlotsAndKeepsAStoredChoiceThisMacCannotReach() {
        let (session, _, model) = makeModel()
        XCTAssertTrue(model.showsHardwareKey)
        XCTAssertEqual(model.hardwareKeyOptions, [
            HardwareKeyConfiguration(transport: .usb, slot: .one),
            HardwareKeyConfiguration(transport: .usb, slot: .two),
        ])

        let nfc = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        session.hardwareKey = nfc
        XCTAssertEqual(model.hardwareKeyOptions.last, nfc)

        session.availableHardwareKeyTransports = []
        session.hardwareKey = nil
        XCTAssertFalse(model.showsHardwareKey)
    }

    func testAYubiKeyAloneIsAKeyPart() async {
        let (session, _, model) = makeModel()
        XCTAssertFalse(model.canSubmit)

        await model.setHardwareKey(HardwareKeyConfiguration(transport: .usb, slot: .two))

        XCTAssertEqual(session.hardwareKeyWrites, [HardwareKeyConfiguration(transport: .usb, slot: .two)])
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        XCTAssertEqual(session.unlockCalls.map(\.password), [""])
        XCTAssertNil(session.unlockCalls.first?.keyFileData)
    }

    func testHardwareKeyChangeBlocksSubmitUntilStoredAndReportsAFailedWrite() async {
        let (session, _, model) = makeModel()
        model.password = "secret"
        let gate = Gate()
        session.onSetHardwareKey = { await gate.wait() }
        session.hardwareKeyOutcome = .rejected

        let change = Task { await model.setHardwareKey(HardwareKeyConfiguration(transport: .usb, slot: .one)) }
        await gate.waitUntilWaiting()
        XCTAssertFalse(model.canSubmit, "The choice is still being stored")
        gate.open()
        await change.value

        XCTAssertTrue(model.canSubmit)
        XCTAssertNil(model.hardwareKey)
        XCTAssertEqual(model.selectionAlert?.title, String(localized: "Hardware Key"))
    }

    func testHardwareKeyIsNotChangedDuringAnOpen() async {
        let (session, _, model) = makeModel()
        session.state = .unlocking

        await model.setHardwareKey(HardwareKeyConfiguration(transport: .usb, slot: .one))

        XCTAssertTrue(session.hardwareKeyWrites.isEmpty)
    }

    // MARK: - Submit

    func testSubmitClearsThePasswordBeforeTheOpenRuns() async {
        let (session, _, model) = makeModel()
        var passwordDuringOpen: String?
        session.onUnlock = { [weak model] in passwordDuringOpen = model?.password }
        session.unlockResult = .error(wrongKey)
        model.password = "secret"

        await model.submit()

        XCTAssertEqual(passwordDuringOpen, "")
        XCTAssertEqual(session.unlockCalls.map(\.password), ["secret"])
        XCTAssertEqual(model.password, "")
    }

    func testWrongAttemptShowsTheFieldErrorAndKeepsThePickedKeyFile() async {
        let (session, _, model) = makeModel(readData: { _ in Data([1, 2, 3]) })
        session.unlockResult = .error(wrongKey)
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/personal.keyx"))
        model.password = "wrong"

        await model.submit()

        XCTAssertTrue(model.showsFieldError)
        XCTAssertEqual(model.keyLine, .picked("personal.keyx"))
        XCTAssertEqual(session.unlockCalls.last?.keyFileData, Data([1, 2, 3]))

        model.password = "r"
        XCTAssertFalse(model.showsFieldError, "Typing clears the error")

        session.unlockResult = .unlocked
        await model.submit()
        XCTAssertEqual(session.unlockCalls.last?.keyFileData, Data([1, 2, 3]), "The second attempt reuses the pick")
    }

    func testFailureTheFieldCannotFixShowsNoFieldError() async {
        let (session, _, model) = makeModel()
        session.unlockResult = .error(missingFile)
        model.password = "secret"

        await model.submit()

        XCTAssertFalse(model.showsFieldError)
    }

    func testSuccessClearsEverySecret() async {
        let (session, _, model) = makeModel(readData: { _ in Data([9, 9]) })
        session.unlockResult = .unlocked
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/personal.keyx"))
        model.password = "secret"
        model.isPasswordVisible = true

        await model.submit()

        XCTAssertEqual(model.password, "")
        XCTAssertFalse(model.isPasswordVisible)
        XCTAssertEqual(model.keyLine, .none)
        XCTAssertEqual(session.unlockCalls.last?.keyFileData, Data([9, 9]),
            "Wiping the form's copy leaves the bytes the session was handed intact")
    }

    func testClearKeyFileAndClearSecretsDropThePick() async {
        let (_, _, model) = makeModel(readData: { _ in Data([4]) })
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/a.keyx"))
        model.clearKeyFile()
        XCTAssertEqual(model.keyLine, .none)

        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/b.keyx"))
        model.password = "typed"
        model.clearSecrets()
        XCTAssertEqual(model.keyLine, .none)
        XCTAssertEqual(model.password, "")
        XCTAssertFalse(model.canSubmit)
    }

    func testAttemptEndingAfterTheFormWasClearedChangesNothing() async {
        let (session, _, model) = makeModel()
        let gate = Gate()
        session.onUnlock = { await gate.wait() }
        session.unlockResult = .error(wrongKey)
        model.password = "secret"

        let submitting = Task { await model.submit() }
        await gate.waitUntilWaiting()
        model.clearSecrets()
        gate.open()
        await submitting.value

        XCTAssertFalse(model.showsFieldError)
    }

    // MARK: - Key files

    func testAssociatedKeyFileLoadsWhenNothingWasPicked() async {
        let (session, _, model) = makeModel()
        session.associatedKeyFile = (Data([5]), "personal.keyx")

        await model.loadAssociatedKeyFileIfNeeded()

        XCTAssertEqual(model.keyLine, .associated("personal.keyx"))
        model.password = ""
        XCTAssertTrue(model.canSubmit)
    }

    func testAssociatedKeyFileNeverReplacesAManualPick() async {
        let (session, _, model) = makeModel(readData: { _ in Data([1]) })
        session.associatedKeyFile = (Data([5]), "associated.keyx")
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/picked.keyx"))

        await model.loadAssociatedKeyFileIfNeeded()

        XCTAssertEqual(model.keyLine, .picked("picked.keyx"))
        XCTAssertEqual(session.associatedLoadCount, 0)
    }

    func testAssociatedReadFinishingAfterAPickIsDropped() async {
        let (session, _, model) = makeModel(readData: { _ in Data([1]) })
        let gate = Gate()
        session.associatedKeyFile = (Data([5]), "associated.keyx")
        session.onLoadAssociated = { await gate.wait() }

        let loading = Task { await model.loadAssociatedKeyFileIfNeeded() }
        await gate.waitUntilWaiting()
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/picked.keyx"))
        gate.open()
        await loading.value

        XCTAssertEqual(model.keyLine, .picked("picked.keyx"))
    }

    func testAssociatedReadFinishingAfterTheFormWasClearedIsDropped() async {
        let (session, _, model) = makeModel()
        let gate = Gate()
        session.associatedKeyFile = (Data([5]), "associated.keyx")
        session.onLoadAssociated = { await gate.wait() }

        let loading = Task { await model.loadAssociatedKeyFileIfNeeded() }
        await gate.waitUntilWaiting()
        model.clearSecrets()
        gate.open()
        await loading.value

        XCTAssertEqual(model.keyLine, .none)
    }

    func testReplacedOrClearedKeyFileReadIsDropped() async {
        let suspension = KeyFileReadSuspension()
        let first = URL(fileURLWithPath: "/tmp/first.keyx")
        let (_, _, model) = makeModel(readData: { url in
            if url.lastPathComponent == "first.keyx" { return await suspension.wait() }
            return Data([2])
        })

        let reading = Task { await model.useKeyFile(at: first) }
        await suspension.waitUntilStarted()
        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/second.keyx"))
        await suspension.resolve(Data([1]))
        await reading.value
        XCTAssertEqual(model.keyLine, .picked("second.keyx"))

        let suspension2 = KeyFileReadSuspension()
        let (_, _, model2) = makeModel(readData: { _ in await suspension2.wait() })
        let reading2 = Task { await model2.useKeyFile(at: first) }
        await suspension2.waitUntilStarted()
        model2.clearKeyFile()
        await suspension2.resolve(Data([1]))
        await reading2.value
        XCTAssertEqual(model2.keyLine, .none)
        XCTAssertFalse(model2.isLoadingKeyFile)
    }

    func testChooseKeyFileReadsWhatThePanelReturnsAndCancelChangesNothing() async {
        let (_, picker, model) = makeModel(readData: { _ in Data([3]) })

        await model.chooseKeyFile()
        XCTAssertEqual(model.keyLine, .none)

        picker.keyFileURL = URL(fileURLWithPath: "/tmp/chosen.keyx")
        await model.chooseKeyFile()
        XCTAssertEqual(model.keyLine, .picked("chosen.keyx"))
        XCTAssertEqual(picker.keyFileRequests, 2)
    }

    func testUnreadableKeyFileRaisesTheSelectionAlert() async {
        let (_, _, model) = makeModel(readData: { _ in throw CocoaError(.fileReadNoPermission) })

        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/locked.keyx"))

        XCTAssertEqual(model.keyLine, .none)
        XCTAssertNotNil(model.selectionAlert)
    }

    // MARK: - Biometrics and focus

    func testBiometricFallbackCancelAndUnavailableRequestFocus() async {
        for outcome: DatabaseViewModel.BiometricUnlockOutcome in [.passwordFallback, .cancelled, .promptUnavailable] {
            let (session, _, model) = makeModel()
            session.biometricUnlockAvailability = .available
            session.biometricOutcome = outcome

            await model.unlockWithBiometrics()

            XCTAssertEqual(model.focusRequest, 1, "\(outcome)")
        }
    }

    func testBiometricSuccessAndFailureDoNotRequestFocus() async {
        for outcome: DatabaseViewModel.BiometricUnlockOutcome in [.unlocked, .failed] {
            let (session, _, model) = makeModel()
            session.biometricUnlockAvailability = .available
            session.biometricOutcome = outcome

            await model.unlockWithBiometrics()

            XCTAssertEqual(model.focusRequest, 0, "\(outcome)")
            XCTAssertEqual(session.biometricCalls, 1)
        }
    }

    func testPasswordAttemptsNeverRequestFocus() async {
        let (session, _, model) = makeModel()
        session.unlockResult = .error(wrongKey)
        model.password = "wrong"

        await model.submit()

        XCTAssertEqual(model.focusRequest, 0)
    }

    func testTheFormNeverPromptsForBiometricsUnlessAsked() async {
        let (session, _, model) = makeModel()
        session.biometricUnlockAvailability = .available
        session.associatedKeyFile = (Data([5]), "personal.keyx")
        session.unlockResult = .error(wrongKey)

        await model.loadAssociatedKeyFileIfNeeded()
        session.state = .error(wrongKey)
        session.state = .locked
        model.password = "wrong"
        await model.submit()
        model.clearSecrets()
        _ = model.escape()
        model.tryAgain()
        XCTAssertEqual(session.biometricCalls, 0)

        session.biometricUnlockAvailability = .unavailableWithStoredKey
        await model.unlockWithBiometrics()
        XCTAssertEqual(session.biometricCalls, 0, "No prompt when Touch ID cannot answer")

        session.biometricUnlockAvailability = .available
        session.state = .unlocking
        await model.unlockWithBiometrics()
        XCTAssertEqual(session.biometricCalls, 0, "No prompt while an open runs")
    }

    // MARK: - Escape, Locate, Try Again

    func testEscapeIsRefusedWhileUnlocking() {
        let (session, _, model) = makeModel()
        XCTAssertTrue(model.escape())
        session.state = .error(wrongKey)
        XCTAssertTrue(model.escape())
        session.state = .unlocking
        XCTAssertFalse(model.escape())
    }

    func testLocateRelinksTheChosenDatabaseFile() async {
        let (session, picker, model) = makeModel()
        session.canRelinkDatabaseFile = true
        picker.databaseURL = URL(fileURLWithPath: "/tmp/moved.kdbx")

        await model.locateDatabaseFile()

        XCTAssertEqual(session.relinked, [URL(fileURLWithPath: "/tmp/moved.kdbx")])
        XCTAssertNil(model.selectionAlert)
    }

    func testLocateDoesNothingWhenCancelledOrNotRelinkable() async {
        let (session, picker, model) = makeModel()
        session.canRelinkDatabaseFile = true
        await model.locateDatabaseFile()
        XCTAssertEqual(picker.databaseRequests, 1)

        session.canRelinkDatabaseFile = false
        picker.databaseURL = URL(fileURLWithPath: "/tmp/moved.kdbx")
        await model.locateDatabaseFile()
        XCTAssertEqual(picker.databaseRequests, 1, "No panel when the failure cannot be relinked")
        XCTAssertTrue(session.relinked.isEmpty)
        XCTAssertNil(model.selectionAlert)
    }

    func testTryAgainReturnsToTheForm() {
        let (session, _, model) = makeModel()
        session.state = .error(missingFile)

        model.tryAgain()

        XCTAssertEqual(session.dismissCount, 1)
    }

    // MARK: - Reconnect

    func testReconnectSignsInThenReturnsToTheForm() async {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)
        var signIns = 0

        await model.reconnect { signIns += 1 }

        XCTAssertEqual(signIns, 1)
        XCTAssertEqual(session.dismissCount, 1)
        XCTAssertFalse(model.isReconnecting)
        XCTAssertNil(model.selectionAlert)
    }

    func testCancelledReconnectStaysOnTheRecoveryPage() async {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)

        await model.reconnect { throw CloudProviderError.authenticationCancelled }

        XCTAssertEqual(session.dismissCount, 0)
        XCTAssertNil(model.selectionAlert)
        XCTAssertFalse(model.isReconnecting)
    }

    func testFailedReconnectSaysWhyAndStays() async {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)

        await model.reconnect { throw CloudProviderError.notAuthenticated }

        XCTAssertEqual(session.dismissCount, 0)
        XCTAssertEqual(model.selectionAlert?.title, String(localized: "Reconnect Cloud Account"))
        XCTAssertEqual(model.selectionAlert?.message, CloudProviderError.notAuthenticated.localizedDescription)
    }

    func testReconnectOvertakenByClearingOrRunningTwiceChangesNothing() async {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)
        let gate = Gate()
        let first = Task { await model.reconnect { await gate.wait() } }
        await gate.waitUntilWaiting()
        XCTAssertTrue(model.isReconnecting)
        var second = 0
        await model.reconnect { second += 1 }
        XCTAssertEqual(second, 0, "One sign-in at a time")

        model.clearSecrets()
        gate.open()
        await first.value
        XCTAssertEqual(session.dismissCount, 0, "A window closed or locked meanwhile is left alone")
        XCTAssertFalse(model.isReconnecting)

        session.state = .locked
        await model.reconnect { second += 1 }
        XCTAssertEqual(second, 0, "Only from a failure")
    }

    // MARK: - The typed password's lifetime

    func testTouchIDTakesATypedPasswordOutOfTheFieldBeforeItPrompts() async {
        for outcome: DatabaseViewModel.BiometricUnlockOutcome in [.unlocked, .passwordFallback, .cancelled,
                                                                  .promptUnavailable, .failed] {
            let (session, _, model) = makeModel()
            session.biometricUnlockAvailability = .available
            session.biometricOutcome = outcome
            var passwordDuringPrompt: String?
            session.onBiometric = { [weak model] in passwordDuringPrompt = model?.password }
            model.password = "typed"

            await model.unlockWithBiometrics()

            XCTAssertEqual(passwordDuringPrompt, "", "\(outcome)")
            XCTAssertEqual(model.password, "", "\(outcome)")
        }
    }

    func testLeavingTheFormForAPageThatCannotShowThePasswordDropsIt() {
        let recovery = MacDatabaseOpenPage.RecoveryPage(symbol: .missingFile, title: "Gone", subtitle: "", summary: "",
            actions: [.tryAgain], errorCode: "file.not_found")
        let opening = MacDatabaseOpenPage.Opening(steps: [], status: "", canCancel: true)
        let pages: [MacDatabaseOpenPage?] = [.recovery(recovery), .opening(opening), .unavailable, nil]
        for page in pages {
            let (_, _, model) = makeModel()
            model.password = "typed"
            model.isPasswordVisible = true

            model.windowDidShow(page)

            XCTAssertEqual(model.password, "", String(describing: page))
            XCTAssertFalse(model.isPasswordVisible, String(describing: page))
        }

        let (_, _, model) = makeModel()
        model.password = "typed"
        model.windowDidShow(.form(card: nil, footer: nil))
        model.windowDidShow(.form(card: MacDatabaseOpenPage.FailureCard(title: "", summary: "", code: ""), footer: nil))
        XCTAssertEqual(model.password, "typed", "The form shows and clears its own field")
    }

    // MARK: - Key-file association

    func testAnAssociatedKeyFileCanBeClearedForThisAttempt() async {
        let (session, _, model) = makeModel()
        session.keyFileAssociation = association("personal.keyx")
        session.associatedKeyFile = (Data([5]), "personal.keyx")
        session.unlockResult = .error(wrongKey)
        await model.loadAssociatedKeyFileIfNeeded()
        XCTAssertEqual(model.keyLine, .associated("personal.keyx"))

        model.clearKeyFile()
        XCTAssertEqual(model.keyLine, .none)
        await model.loadAssociatedKeyFileIfNeeded()
        XCTAssertEqual(model.keyLine, .none, "Not read back for this attempt")
        model.password = "only the password"
        await model.submit()
        XCTAssertNil(session.unlockCalls.last?.keyFileData)
        await model.loadAssociatedKeyFileIfNeeded()
        XCTAssertEqual(model.keyLine, .none, "A wrong attempt keeps it cleared")
        XCTAssertEqual(session.associatedLoadCount, 1)

        model.clearSecrets()
        await model.loadAssociatedKeyFileIfNeeded()
        XCTAssertEqual(model.keyLine, .associated("personal.keyx"), "The next lock cycle offers it again")
    }

    func testAClearedAssociationWipesWhatTheFormLoaded() async {
        let (session, _, model) = makeModel()
        session.keyFileAssociation = association("personal.keyx")
        session.associatedKeyFile = (Data([5]), "personal.keyx")
        await model.reconcileKeyFileAssociation()
        XCTAssertEqual(model.keyLine, .associated("personal.keyx"))

        session.keyFileAssociation = nil
        session.associatedKeyFile = nil
        await model.reconcileKeyFileAssociation()

        XCTAssertEqual(model.keyLine, .none)
        model.password = "secret"
        await model.submit()
        XCTAssertNil(session.unlockCalls.last?.keyFileData)
    }

    func testANewAssociationIsReadUnlessAFileWasPicked() async {
        let (session, _, model) = makeModel(readData: { _ in Data([1]) })
        session.keyFileAssociation = association("old.keyx")
        session.associatedKeyFile = (Data([5]), "old.keyx")
        await model.reconcileKeyFileAssociation()
        model.clearKeyFile()

        session.keyFileAssociation = association("new.keyx")
        session.associatedKeyFile = (Data([6]), "new.keyx")
        await model.reconcileKeyFileAssociation()
        XCTAssertEqual(model.keyLine, .associated("new.keyx"), "A new association replaces a cleared old one")

        await model.reconcileKeyFileAssociation()
        XCTAssertEqual(session.associatedLoadCount, 2, "An unchanged association is not read again")

        await model.useKeyFile(at: URL(fileURLWithPath: "/tmp/picked.keyx"))
        session.keyFileAssociation = association("newer.keyx")
        session.associatedKeyFile = (Data([7]), "newer.keyx")
        await model.reconcileKeyFileAssociation()
        XCTAssertEqual(model.keyLine, .picked("picked.keyx"))
        XCTAssertEqual(session.associatedLoadCount, 2)
    }

    func testAReadOfAnAssociationThatChangedMeanwhileIsDropped() async {
        let (session, _, model) = makeModel()
        let gate = Gate()
        session.keyFileAssociation = association("old.keyx")
        session.associatedKeyFile = (Data([5]), "old.keyx")
        session.onLoadAssociated = { await gate.wait() }

        let loading = Task { await model.reconcileKeyFileAssociation() }
        await gate.waitUntilWaiting()
        session.onLoadAssociated = nil
        session.keyFileAssociation = nil
        session.associatedKeyFile = nil
        await model.reconcileKeyFileAssociation()
        gate.open()
        await loading.value

        XCTAssertEqual(model.keyLine, .none)
    }

    func testAssociationChangedBeforeObservationRejectsTheOldRead() async {
        let (session, _, model) = makeModel()
        let gate = Gate()
        session.keyFileAssociation = association("old.keyx")
        session.associatedKeyFile = (Data([5]), "old.keyx")
        session.onLoadAssociated = { await gate.wait() }

        let loading = Task { await model.loadAssociatedKeyFileIfNeeded() }
        await gate.waitUntilWaiting()
        session.keyFileAssociation = association("new.keyx")
        gate.open()
        await loading.value
        XCTAssertEqual(model.keyLine, .none, "The observer has not reconciled the new reference yet")

        session.onLoadAssociated = nil
        session.associatedKeyFile = (Data([6]), "new.keyx")
        await model.reconcileKeyFileAssociation()
        XCTAssertEqual(model.keyLine, .associated("new.keyx"))
    }

    func testAssociationReconciliationNeverReloadsKeyBytesIntoAnUnlockedForm() async {
        let (session, _, model) = makeModel()
        session.keyFileAssociation = association("personal.keyx")
        session.associatedKeyFile = (Data([5]), "personal.keyx")
        session.state = .unlocked

        await model.reconcileKeyFileAssociation()

        XCTAssertEqual(model.keyLine, .none)
        XCTAssertEqual(session.associatedLoadCount, 0)
    }

    // MARK: - Reconnect through the production provider

    func testReconnectEntersTheServerPasswordAgainThroughTheRealWebDAVProviderAndReturnsToTheForm() async throws {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)
        let base = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/dav/")
        let accountID = WebDAVURL.accountId(normalizedBaseURL: base, username: "alice")
        try seedWebDAVCredential(WebDAVCredential(serverURL: base.absoluteString, username: "alice", password: "old"),
                                 accountID: accountID)
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: { request in
            let authorized = request.value(forHTTPHeaderField: "Authorization")
                == "Basic " + Data("alice:new".utf8).base64EncodedString()
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: authorized ? 207 : 401, httpVersion: nil, headerFields: nil)))
        }))
        let reconnect = try XCTUnwrap(MacServerReconnect(reference: webDAVReference(accountID: accountID),
                                                         provider: { _ in provider }))
        var shown: [MacServerCredentialForm] = []

        await model.reconnect {
            try await reconnect.run { form in
                shown.append(form)
                guard case .webDAV(let webDAV) = form else { return false }
                webDAV.password = "old"
                guard await webDAV.connect() == nil else { return true }
                webDAV.password = "new"
                return await webDAV.connect() != nil
            }
        }

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(session.dismissCount, 1, "Back to the form for the master password")
        XCTAssertNil(model.selectionAlert)
        let stored = try XCTUnwrap(CloudTokenStore.tokenData(provider: CloudProviderKind.webDAV.rawValue,
                                                             accountId: accountID))
        XCTAssertEqual(try JSONDecoder().decode(WebDAVCredential.self, from: stored).password, "new")
    }

    func testClosingTheReconnectFormStaysOnTheRecoveryPage() async throws {
        let (session, _, model) = makeModel()
        session.state = .error(signInNeeded)
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: { _ in
            XCTFail("Nothing was entered")
            throw URLError(.cancelled)
        }))
        let reconnect = try XCTUnwrap(MacServerReconnect(reference: webDAVReference(accountID: "webdav-none"),
                                                         provider: { _ in provider }))

        await model.reconnect { try await reconnect.run { _ in false } }

        XCTAssertEqual(session.dismissCount, 0)
        XCTAssertNil(model.selectionAlert)
        XCTAssertFalse(model.isReconnecting)
    }

    private func webDAVReference(accountID: String) -> DatabaseReference {
        var reference = MacLockedPageFixtures.reference(filename: "work-vault.kdbx", provider: .webDAV)
        reference.source = .cloud(CloudSyncMetadata(provider: CloudProviderKind.webDAV.rawValue, accountId: accountID,
            fileId: "/vault.kdbx", displayPath: "/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
            lastSyncedAt: nil, lastSyncIssue: nil))
        return reference
    }

    private func seedWebDAVCredential(_ credential: WebDAVCredential, accountID: String) throws {
        guard CloudTokenStore.setTokenData(try JSONEncoder().encode(credential), provider: CloudProviderKind.webDAV.rawValue,
                                           accountId: accountID) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        addTeardownBlock {
            _ = CloudTokenStore.deleteToken(provider: CloudProviderKind.webDAV.rawValue, accountId: accountID)
            CloudAccountStore.remove(provider: CloudProviderKind.webDAV.rawValue, accountId: accountID)
        }
    }

    private func association(_ filename: String) -> MacKeyFileAssociation? {
        MacKeyFileAssociation(reference: MacLockedPageFixtures.reference(filename: "vault.kdbx", keyFile: filename))
    }

    // MARK: - Helpers

    private func makeModel(
        readData: @escaping @Sendable (URL) async throws -> Data = { _ in Data() }
    ) -> (FakeUnlockSession, FakeFilePicker, MacUnlockFormModel) {
        let session = FakeUnlockSession()
        let picker = FakeFilePicker()
        let model = MacUnlockFormModel(session: session, filePicker: picker,
            keyFileSelection: UnlockKeyFileSelection(readData: readData))
        return (session, picker, model)
    }
}

@MainActor
private final class FakeUnlockSession: MacUnlockSession {
    var state: DatabaseViewModel.State = .locked
    var biometricUnlockAvailability: DatabaseViewModel.BiometricUnlockAvailability = .none
    var canRelinkDatabaseFile = false
    var keyFileAssociation: MacKeyFileAssociation?
    var hardwareKey: HardwareKeyConfiguration?
    var availableHardwareKeyTransports: [HardwareKeyConfiguration.Transport] = [.usb]
    var hardwareKeyOutcome: DatabaseListStore.HardwarePreferenceOutcome = .saved
    var onSetHardwareKey: (@MainActor () async -> Void)?
    private(set) var hardwareKeyWrites: [HardwareKeyConfiguration?] = []
    var unlockResult: DatabaseViewModel.State = .unlocked
    var biometricOutcome: DatabaseViewModel.BiometricUnlockOutcome = .cancelled
    var associatedKeyFile: (Data, String)?
    var onUnlock: (@MainActor () async -> Void)?
    var onLoadAssociated: (@MainActor () async -> Void)?
    var onBiometric: (@MainActor () -> Void)?
    private(set) var unlockCalls: [(password: String, keyFileData: Data?)] = []
    private(set) var biometricCalls = 0
    private(set) var associatedLoadCount = 0
    private(set) var relinked: [URL] = []
    private(set) var dismissCount = 0

    func unlock(password: String, keyFileData: Data?) async {
        unlockCalls.append((password, keyFileData))
        state = .unlocking
        await onUnlock?()
        state = unlockResult
    }

    func setHardwareKey(_ hardwareKey: HardwareKeyConfiguration?) async -> DatabaseListStore.HardwarePreferenceOutcome {
        hardwareKeyWrites.append(hardwareKey)
        await onSetHardwareKey?()
        if hardwareKeyOutcome == .saved { self.hardwareKey = hardwareKey }
        return hardwareKeyOutcome
    }

    func unlockWithBiometrics() async -> DatabaseViewModel.BiometricUnlockOutcome {
        biometricCalls += 1
        onBiometric?()
        return biometricOutcome
    }

    func loadAssociatedKeyFile() async -> (data: Data, filename: String)? {
        associatedLoadCount += 1
        await onLoadAssociated?()
        return associatedKeyFile.map { (data: $0.0, filename: $0.1) }
    }

    func relinkDatabaseFile(to url: URL) throws {
        relinked.append(url)
        state = .locked
    }

    func dismissOpenFailure() {
        dismissCount += 1
        state = .locked
    }
}

@MainActor
private final class FakeFilePicker: MacUnlockFilePicking {
    var keyFileURL: URL?
    var databaseURL: URL?
    private(set) var keyFileRequests = 0
    private(set) var databaseRequests = 0

    func chooseKeyFile() async -> URL? {
        keyFileRequests += 1
        return keyFileURL
    }

    func locateDatabase() async -> URL? {
        databaseRequests += 1
        return databaseURL
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting() async {
        while continuation == nil { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor KeyFileReadSuspension {
    private var continuation: CheckedContinuation<Data, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func wait() async -> Data {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resolve(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
#endif
