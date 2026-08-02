// Runs on both iOS and macOS. Tests below platform-gate only where the
// underlying API is genuinely unavailable: save/generate-password are
// `API_UNAVAILABLE(macos)`, one-time codes need macOS 15.
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

/// Verifies that `CredentialProviderCoordinator.cleanup()` — the extension's
/// only "lock" — runs on every completion path: success, user cancel, error
/// alert dismissal, and extension-context cancellation.
@MainActor
final class CredentialProviderCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        resetAutoFillSettings()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        resetAutoFillSettings()
        try await super.tearDown()
    }

    /// The AutoFill settings this suite writes live in the App Group suite and
    /// survive the process, so they are cleared on both ends of every test —
    /// otherwise a leftover value silently changes an unrelated test's meaning.
    private func resetAutoFillSettings() {
        let sharedDefaults = UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
        sharedDefaults.removeObject(forKey: "KeeForge.quickAutoFillEnabled")
        sharedDefaults.removeObject(forKey: "KeeForge.autoFillCopyTOTP")
        sharedDefaults.removeObject(forKey: "KeeForge.autoUnlockWithFaceID")
    }

    // MARK: - Required cleanup-path tests

    func test_requestPreparedBeforeAppearance_waitsForActivePresentation() throws {
        let (coordinator, presenter) = makeCoordinator()
        try seedResolvableDefaultDatabase()

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])

        XCTAssertNil(presenter.unlockPrompt)

        presenter.isPresentationActive = true
        coordinator.presentationDidBecomeActive()

        XCTAssertNotNil(presenter.unlockPrompt)
    }

    func test_requestPreparedAfterAppearance_activatesPresentation() async throws {
        let (coordinator, presenter) = makeCoordinator()
        try seedResolvableDefaultDatabase()
        presenter.isPresentationActive = true
        let promptPresented = expectation(description: "unlock prompt presented")
        presenter.onUnlockPromptPresented = { promptPresented.fulfill() }

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])

        await fulfillment(of: [promptPresented], timeout: 1)
        XCTAssertNotNil(presenter.unlockPrompt)
    }

    func test_cleanup_runsOnCancel() throws {
        let (coordinator, presenter) = makeCoordinator()
        try seedResolvableDefaultDatabase()

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentationDidBecomeActive()

        let prompt = try XCTUnwrap(presenter.unlockPrompt, "Unlock prompt should be requested")
        // Simulate an unlocked vault that must be torn down on cancel.
        seedUnlockedVaultState(coordinator)

        prompt.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnError() async throws {
        let (coordinator, presenter) = makeCoordinator()
        try seedResolvableDefaultDatabase()

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentationDidBecomeActive()

        let prompt = try XCTUnwrap(presenter.unlockPrompt, "Unlock prompt should be requested")
        // Simulate stale vault state that must be torn down when the user
        // dismisses the error alert.
        seedUnlockedVaultState(coordinator)

        let errorPresented = expectation(description: "unlock error presented")
        presenter.onUnlockErrorPresented = { errorPresented.fulfill() }

        // The seeded default database has no valid KDBX bytes behind it (the
        // bookmarked file is a placeholder, no cached copy), so unlocking fails.
        prompt.onSubmitPassword("wrong-password")
        await fulfillment(of: [errorPresented], timeout: 10)

        let unlockError = try XCTUnwrap(presenter.unlockError)
        XCTAssertNotNil(coordinator.sessionKey, "State should survive until the error alert is dismissed")

        unlockError.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnSuccessfulCompletion() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        var sessionKeyWasNilAtCompletion = false
        presenter.onCompleteRequest = { _ in
            sessionKeyWasNilAtCompletion = coordinator.sessionKey == nil
        }

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential)
        XCTAssertEqual(credential.user, "octocat")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertTrue(
            sessionKeyWasNilAtCompletion,
            "cleanup() must run before the credential is handed to the shell"
        )
        assertCleanedUp(coordinator)
    }

    func test_terminalCompletionIsDeliveredExactlyOnce() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.completeRequest(with: entry)
        coordinator.cancelRequest(code: .failed)

        XCTAssertEqual(presenter.cancelledErrorCodes, [], "A completed request must not be cancelled again")
        XCTAssertNotNil(presenter.completedCredential)
    }

    func test_cancelDuringUnlockInvalidatesLateContinuation() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseReference = try seedResolvableDefaultDatabase()
        coordinator.activeDatabaseReference = databaseReference

        let unlockEntered = expectation(description: "unlock task entered its async seam")
        let unlockCancelled = expectation(description: "unlock task observed cancellation")
        coordinator.unlockWorkOverride = {
            unlockEntered.fulfill()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                unlockCancelled.fulfill()
                throw error
            }
        }

        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentUnlockPromptIfNeeded()
        let prompt = try XCTUnwrap(presenter.unlockPrompt)
        prompt.onChooseBiometrics()

        await fulfillment(of: [unlockEntered], timeout: 1)
        coordinator.cancelRequest(code: .userCanceled)
        await fulfillment(of: [unlockCancelled], timeout: 1)

        XCTAssertEqual(presenter.cancelledErrorCodes, [.userCanceled])
        XCTAssertNil(presenter.searchView, "A cancelled unlock must not present a late picker")
        assertCleanedUp(coordinator)

        presenter.unlockPrompt = nil
        coordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        coordinator.presentationDidBecomeActive()
        XCTAssertNotNil(presenter.unlockPrompt, "A new request must present its unlock prompt")
    }

    // MARK: - Additional cleanup paths the pre-existing suite did not cover

    func test_cleanup_runsOnSearchViewCancel() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(
                title: "GitHub",
                username: "octocat",
                password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
                url: "https://github.com/login"
            ),
            KPEntry(
                title: "GitHub Work",
                username: "worktocat",
                password: try EncryptedValue.encrypt("hunter3", using: sessionKey),
                url: "https://github.com/enterprise"
            ),
        ]

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "Multiple matches should present the search view")
        XCTAssertEqual(searchView.entries.count, 2)

        searchView.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnReadOnlyNoticeDismissal() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)

        coordinator.presentReadOnlyAlertAndCancel(message: "This database is read-only.")

        let notice = try XCTUnwrap(presenter.readOnlyNotice)
        XCTAssertEqual(notice.message, "This database is read-only.")

        notice.onAcknowledge()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_possibleMatchesStartSeparatedButKeepFullSearchCorpus() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(
                title: "Sibling",
                username: "sibling",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://tro.sitio.com/login"
            ),
            KPEntry(
                title: "Unrelated",
                username: "other",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://other.example"
            )
        ]

        coordinator.serviceIdentifiers = [
            ASCredentialServiceIdentifier(identifier: "https://acs.sitio.com", type: .URL)
        ]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertTrue(searchView.entries.isEmpty)
        XCTAssertEqual(searchView.possibleEntries.map(\.title), ["Sibling"])
        XCTAssertEqual(searchView.searchEntries.count, 2)
        XCTAssertEqual(searchView.initialSearchText, "")
    }

    func test_fuzzyCandidatesArePossibleAndMultipleCandidatesRemainAvailable() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(
                title: "acs.sitio.com legacy",
                username: "fuzzy",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://unrelated.example"
            ),
            KPEntry(
                title: "Sibling One",
                username: "one",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://one.sitio.com"
            ),
            KPEntry(
                title: "Sibling Two",
                username: "two",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://two.sitio.com"
            )
        ]

        coordinator.serviceIdentifiers = [
            ASCredentialServiceIdentifier(identifier: "https://acs.sitio.com", type: .URL)
        ]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertTrue(searchView.entries.isEmpty, "Broad fuzzy matches must not be exact results")
        XCTAssertEqual(searchView.possibleEntries.map(\.title), ["acs.sitio.com legacy", "Sibling One", "Sibling Two"])
    }

    func test_cleanup_runsOnExtensionConfigurationCancellation() {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)

        coordinator.prepareInterfaceForExtensionConfiguration()

        XCTAssertEqual(presenter.cancelledError?.code, .failed)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnOneTimeCodeCompletion() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "TOTP Entry",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )

        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.completeOTCRequest(with: entry)

        let code = try XCTUnwrap(presenter.completedOneTimeCode)
        XCTAssertEqual(code.count, 6)
        XCTAssertNotEqual(code, "------")
        assertCleanedUp(coordinator)
    }

    // MARK: - One-time-code list requests (issue #20)

    func test_otcList_singleMatch_completesWithCode() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let matching = KPEntry(
            title: "GitHub",
            url: "https://github.com/login",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )
        let other = KPEntry(
            title: "Example",
            url: "https://example.com",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        XCTAssertTrue(coordinator.hasPendingOTCListRequest, "List request must be recorded for post-unlock handling")
        seedUnlockedVaultState(coordinator, entries: [matching, other], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let code = try XCTUnwrap(presenter.completedOneTimeCode, "A single service match should complete without a picker")
        XCTAssertEqual(code.count, 6)
        XCTAssertNotEqual(code, "------")
        assertCleanedUp(coordinator)
    }

    func test_otcList_prefersMostSpecificOrderedServiceIdentifier() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let specific = KPEntry(
            title: "Specific",
            url: "https://vt.example.com/login",
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey))
        )
        let root = KPEntry(
            title: "Root",
            url: "https://example.com/login",
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey))
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [
            ASCredentialServiceIdentifier(identifier: "vt.example.com", type: .domain),
            ASCredentialServiceIdentifier(identifier: "example.com", type: .domain),
        ])
        seedUnlockedVaultState(coordinator, entries: [root, specific], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        XCTAssertNotNil(presenter.completedOneTimeCode, "The more specific ordered host should win")
        XCTAssertNil(presenter.searchView)
        assertCleanedUp(coordinator)
    }

    func test_otcList_multipleMatches_presentsPickerAndCompletesOnSelection() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try ["GitHub", "GitHub Work"].map { title in
            KPEntry(
                title: title,
                url: "https://github.com/login",
                totpConfig: TOTPConfig(
                    secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
                )
            )
        }

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "Multiple matches should present the picker")
        XCTAssertEqual(searchView.entries.count, 2)
        XCTAssertEqual(searchView.initialSearchText, "")

        searchView.onSelect(entries[0])

        let code = try XCTUnwrap(presenter.completedOneTimeCode)
        XCTAssertEqual(code.count, 6)
        assertCleanedUp(coordinator)
    }

    func test_otcList_noMatches_presentsAllTOTPEntriesWithDomainPrefilled() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let totpEntry = KPEntry(
            title: "Example",
            url: "https://example.com",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            )
        )
        let passwordOnlyEntry = KPEntry(
            title: "No TOTP",
            username: "user",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: [totpEntry, passwordOnlyEntry], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView, "No matches should still present the full TOTP list")
        XCTAssertEqual(searchView.entries.map(\.title), ["Example"], "Only TOTP-capable entries belong in the OTC picker")
        XCTAssertEqual(searchView.initialSearchText, "github.com")

        searchView.onSelect(totpEntry)

        XCTAssertNotNil(presenter.completedOneTimeCode)
        assertCleanedUp(coordinator)
    }

    func test_otcList_noTOTPEntries_cancelsWithCredentialIdentityNotFound() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let passwordOnlyEntry = KPEntry(
            title: "No TOTP",
            username: "user",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: [passwordOnlyEntry], sessionKey: sessionKey)

        coordinator.presentOTCMatchesOrFinish()

        XCTAssertEqual(presenter.cancelledError?.code, .credentialIdentityNotFound)
        assertCleanedUp(coordinator)
    }

    func test_cleanup_runsOnPasskeyAssertionCompletion() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let privateKey = P256.Signing.PrivateKey()
        let entry = KPEntry(
            title: "Passkey Entry",
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt(pemEncode(privateKey), using: sessionKey)
        )

        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        try coordinator.completePasskeyRequest(
            with: entry,
            relyingPartyID: "example.com",
            clientDataHash: Data(repeating: 7, count: 32)
        )

        let credential = try XCTUnwrap(presenter.completedAssertion)
        XCTAssertEqual(credential.relyingParty, "example.com")
        assertCleanedUp(coordinator)
    }

    // MARK: - Record-identifier resolution in the fill paths (slice 02)

    func test_passwordFill_resolvesCurrentFormatIdentifier() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        // Target the SECOND entry: without identifier resolution the two
        // matching entries would present a picker, so a direct completion
        // with this entry proves the tagged identifier resolved it.
        coordinator.targetRecordIdentifier = CredentialRecordIdentifier(
            databaseID: UUID(),
            entryID: entries[1].id
        ).encoded

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential, "Tagged identifier should complete without a picker")
        XCTAssertEqual(credential.user, "worktocat")
        XCTAssertEqual(credential.password, "hunter3")
        XCTAssertNil(presenter.searchView, "A resolvable identifier must not fall back to the search view")
        assertCleanedUp(coordinator)
    }

    func test_passwordFill_resolvesLegacyIdentifier() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        // Pre-feature builds published bare entry UUIDs; those suggestions
        // must keep filling after the update.
        coordinator.targetRecordIdentifier = entries[1].id.uuidString

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential, "Legacy identifier should complete without a picker")
        XCTAssertEqual(credential.user, "worktocat")
        XCTAssertEqual(credential.password, "hunter3")
        XCTAssertNil(presenter.searchView)
        assertCleanedUp(coordinator)
    }

    func test_passwordFill_unrecognizedIdentifierFallsBackToInteractivePath() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        coordinator.targetRecordIdentifier = "v9:garbage"

        // An unrecognized identifier is unattributable, so the whole store is
        // scheduled for a clear before the interactive fallback.
        let storeCleared = expectation(description: "clearStore scheduled")
        CredentialIdentityStoreManager.clearObserver = { storeCleared.fulfill() }

        coordinator.presentPasswordMatchesOrFinish()

        await fulfillment(of: [storeCleared], timeout: 1)
        XCTAssertNil(presenter.completedCredential, "A stale identifier must never complete directly")
        let searchView = try XCTUnwrap(presenter.searchView, "The interactive matching fallback must present — never a dead tap")
        XCTAssertEqual(searchView.entries.count, 2)
    }

    func test_passwordFill_currentIdentifierForForeignEntryFallsBack() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        // A well-formed tagged identifier whose entry UUID is not in the
        // unlocked vault (e.g. another database's entry): matching is by
        // entry UUID within the resolved database only, so it falls back.
        coordinator.targetRecordIdentifier = CredentialRecordIdentifier(
            databaseID: UUID(),
            entryID: UUID()
        ).encoded

        coordinator.presentPasswordMatchesOrFinish()

        XCTAssertNil(presenter.completedCredential)
        let searchView = try XCTUnwrap(presenter.searchView, "A foreign-entry identifier must fall back to the matching/search path")
        XCTAssertEqual(searchView.entries.count, 2)
    }

    func test_passkeyLookup_resolvesTaggedRecordIdentifier() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        // Two passkey entries sharing relying party AND credential ID but
        // with different user handles: the fallback identity match would pick
        // the first, so an assertion carrying the second entry's user handle
        // proves `findEntry(byRecordIdentifier:)` resolved the tagged string.
        let firstKey = P256.Signing.PrivateKey()
        let secondKey = P256.Signing.PrivateKey()
        let firstHandle = Data("user-handle".utf8)
        let secondHandle = Data("user-handle-2".utf8)
        let firstEntry = try makePasskeyEntry(
            title: "Passkey One",
            userHandleBase64: firstHandle.base64EncodedString(),
            privateKey: firstKey,
            sessionKey: sessionKey
        )
        let secondEntry = try makePasskeyEntry(
            title: "Passkey Two",
            userHandleBase64: secondHandle.base64EncodedString(),
            privateKey: secondKey,
            sessionKey: sessionKey
        )

        seedUnlockedVaultState(coordinator, entries: [firstEntry, secondEntry], sessionKey: sessionKey)

        let request = makePasskeyRequest(
            recordIdentifier: CredentialRecordIdentifier(
                databaseID: UUID(),
                entryID: secondEntry.id
            ).encoded,
            userHandle: secondHandle
        )

        coordinator.completeInteractivePasskeyRequest(request)

        let credential = try XCTUnwrap(presenter.completedAssertion)
        XCTAssertEqual(credential.relyingParty, "example.com")
        XCTAssertEqual(
            credential.userHandle,
            secondHandle,
            "The tagged record identifier must select the second entry over the first ambient match"
        )
        assertCleanedUp(coordinator)
    }

    func test_otcPendingRequest_resolvesCurrentAndLegacyIdentifiers() async throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        // Current (tagged) identifier completes directly.
        let sessionKey = SymmetricKey(size: .bits256)
        let (taggedCoordinator, taggedPresenter) = makeCoordinator()
        let taggedEntries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]
        taggedCoordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(taggedCoordinator, entries: taggedEntries, sessionKey: sessionKey)
        taggedCoordinator.hasPendingOTCRequest = true
        taggedCoordinator.targetRecordIdentifier = CredentialRecordIdentifier(
            databaseID: UUID(),
            entryID: taggedEntries[1].id
        ).encoded

        taggedCoordinator.completeOTCRequestFromPending()

        let taggedCode = try XCTUnwrap(taggedPresenter.completedOneTimeCode, "Tagged identifier should complete the OTC request")
        XCTAssertEqual(taggedCode.count, 6)
        XCTAssertNotEqual(taggedCode, "------")
        assertCleanedUp(taggedCoordinator)

        // Legacy (bare-UUID) identifier completes directly.
        let (legacyCoordinator, legacyPresenter) = makeCoordinator()
        let legacyEntries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]
        legacyCoordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(legacyCoordinator, entries: legacyEntries, sessionKey: sessionKey)
        legacyCoordinator.hasPendingOTCRequest = true
        legacyCoordinator.targetRecordIdentifier = legacyEntries[1].id.uuidString

        legacyCoordinator.completeOTCRequestFromPending()

        let legacyCode = try XCTUnwrap(legacyPresenter.completedOneTimeCode, "Legacy identifier should complete the OTC request")
        XCTAssertEqual(legacyCode.count, 6)
        assertCleanedUp(legacyCoordinator)

        // Unrecognized identifier falls back to the interactive picker.
        let (staleCoordinator, stalePresenter) = makeCoordinator()
        let staleEntries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]
        staleCoordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(staleCoordinator, entries: staleEntries, sessionKey: sessionKey)
        staleCoordinator.hasPendingOTCRequest = true
        staleCoordinator.targetRecordIdentifier = "v9:garbage"

        let storeCleared = expectation(description: "clearStore scheduled for the unattributable identifier")
        CredentialIdentityStoreManager.clearObserver = { storeCleared.fulfill() }

        staleCoordinator.completeOTCRequestFromPending()

        await fulfillment(of: [storeCleared], timeout: 1)
        XCTAssertNil(stalePresenter.completedOneTimeCode, "A stale identifier must not complete directly")
        let picker = try XCTUnwrap(stalePresenter.searchView, "The OTC picker fallback must present")
        XCTAssertEqual(picker.entries.count, 2)
    }

    // MARK: - Interactive request-to-database resolution (slice 03)

    func test_resolution_currentIdentifierPinsOwningDatabaseNotActivePointer() throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        let databaseB = try makeRegisteredDatabase(named: "b.kdbx")
        DatabaseListStore.activeAutoFillDatabaseID = databaseA.id

        let identifier = CredentialRecordIdentifier(databaseID: databaseB.id, entryID: UUID()).encoded
        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: identifier))
        coordinator.presentationDidBecomeActive()

        XCTAssertNotNil(presenter.unlockPrompt, "The owning database's unlock prompt must be requested")
        XCTAssertEqual(
            coordinator.activeDatabaseReference?.id,
            databaseB.id,
            "The request must pin the identifier's owning database, not the active pointer"
        )
        XCTAssertEqual(coordinator.targetRecordIdentifier, identifier, "A resolvable identifier must be preserved for the post-unlock lookup")
    }

    func test_resolution_legacyIdentifierPinsDefaultDatabase() throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        try makeRegisteredDatabase(named: "b.kdbx")
        DatabaseListStore.activeAutoFillDatabaseID = databaseA.id

        let identifier = UUID().uuidString
        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: identifier))
        coordinator.presentationDidBecomeActive()

        XCTAssertNotNil(presenter.unlockPrompt)
        XCTAssertEqual(
            coordinator.activeDatabaseReference?.id,
            databaseA.id,
            "A legacy identifier carries no attribution and must pin the default database"
        )
        XCTAssertEqual(coordinator.targetRecordIdentifier, identifier, "Legacy identifiers still fill after unlock")
    }

    func test_resolution_unknownDatabaseRemovesItsIdentitiesAndFallsBackToDefault() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        DatabaseListStore.activeAutoFillDatabaseID = databaseA.id

        let unknownDatabaseID = UUID()
        let removalScheduled = expectation(description: "targeted removal scheduled for the unknown database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, _ in
            XCTAssertEqual(databaseID, unknownDatabaseID)
            removalScheduled.fulfill()
        }

        let identifier = CredentialRecordIdentifier(databaseID: unknownDatabaseID, entryID: UUID()).encoded
        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: identifier))
        coordinator.presentationDidBecomeActive()

        await fulfillment(of: [removalScheduled], timeout: 1)
        XCTAssertNil(coordinator.targetRecordIdentifier, "The stale per-entry target must be dropped so post-unlock lookup can't dead-end")
        XCTAssertEqual(coordinator.activeDatabaseReference?.id, databaseA.id, "The request degrades to the default database")
        XCTAssertNotNil(presenter.unlockPrompt, "Never a dead tap — the fallback unlock prompt must present")
    }

    func test_resolution_disabledDatabaseTreatedAsUnknown() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        let databaseB = try makeRegisteredDatabase(named: "b.kdbx", autoFillEnabled: false)
        DatabaseListStore.activeAutoFillDatabaseID = databaseA.id

        let removalScheduled = expectation(description: "targeted removal scheduled for the disabled database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, _ in
            XCTAssertEqual(databaseID, databaseB.id)
            removalScheduled.fulfill()
        }

        let identifier = CredentialRecordIdentifier(databaseID: databaseB.id, entryID: UUID()).encoded
        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: identifier))
        coordinator.presentationDidBecomeActive()

        await fulfillment(of: [removalScheduled], timeout: 1)
        XCTAssertNil(coordinator.targetRecordIdentifier)
        XCTAssertEqual(coordinator.activeDatabaseReference?.id, databaseA.id)
        XCTAssertNotNil(presenter.unlockPrompt)
    }

    func test_resolution_unrecognizedIdentifierClearsStoreAndFallsBack() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        DatabaseListStore.activeAutoFillDatabaseID = databaseA.id

        let storeCleared = expectation(description: "clearStore scheduled for the unattributable identifier")
        CredentialIdentityStoreManager.clearObserver = { storeCleared.fulfill() }

        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: "v9:garbage"))
        coordinator.presentationDidBecomeActive()

        await fulfillment(of: [storeCleared], timeout: 1)
        XCTAssertNil(coordinator.targetRecordIdentifier)
        XCTAssertEqual(coordinator.activeDatabaseReference?.id, databaseA.id)
        XCTAssertNotNil(presenter.unlockPrompt)
    }

    func test_resolution_staleIdentifierWithZeroEnabledDatabasesShowsEmptyState() async throws {
        let (coordinator, presenter) = makeCoordinator()

        let unknownDatabaseID = UUID()
        let removalScheduled = expectation(description: "targeted removal scheduled")
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in removalScheduled.fulfill() }

        let identifier = CredentialRecordIdentifier(databaseID: unknownDatabaseID, entryID: UUID()).encoded
        coordinator.prepareInterfaceToProvideCredential(for: makePasswordIdentity(recordIdentifier: identifier))
        coordinator.presentationDidBecomeActive()

        await fulfillment(of: [removalScheduled], timeout: 1)
        XCTAssertNil(presenter.unlockPrompt, "With no fallback database there is nothing to unlock")
        let emptyState = try XCTUnwrap(presenter.noEnabledDatabasesState, "The explanatory empty state must present instead")

        emptyState.onDismiss()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_manualListWithZeroEnabledDatabasesShowsEmptyState() throws {
        // Empty registry.
        let (emptyRegistryCoordinator, emptyRegistryPresenter) = makeCoordinator()
        emptyRegistryCoordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        emptyRegistryCoordinator.presentationDidBecomeActive()

        XCTAssertNil(emptyRegistryPresenter.unlockPrompt)
        XCTAssertNotNil(emptyRegistryPresenter.noEnabledDatabasesState, "An empty registry must present the empty state")

        // One registered but AutoFill-disabled database.
        let (disabledCoordinator, disabledPresenter) = makeCoordinator()
        let disabledReference = try makeRegisteredDatabase(named: "disabled.kdbx", autoFillEnabled: false)
        DatabaseListStore.markDatabaseOpened(id: disabledReference.id)

        disabledCoordinator.prepareCredentialList(for: [githubServiceIdentifier()])
        disabledCoordinator.presentationDidBecomeActive()

        XCTAssertNil(disabledPresenter.unlockPrompt)
        XCTAssertNotNil(disabledPresenter.noEnabledDatabasesState, "A disabled database is treated as nonexistent")
    }

    func test_presentationDidBecomeActive_pendingNoEnabledDatabasesFlag_presentsEmptyState() {
        let (coordinator, presenter) = makeCoordinator()
        // The save-prepare path defers the empty state until the shell is on
        // screen; `presentationDidBecomeActive` must consume the flag.
        coordinator.pendingNoEnabledDatabasesPresentation = true

        coordinator.presentationDidBecomeActive()

        XCTAssertNotNil(presenter.noEnabledDatabasesState)
        XCTAssertNil(presenter.unlockPrompt)
        XCTAssertFalse(coordinator.pendingNoEnabledDatabasesPresentation, "The deferral flag must be consumed")
    }

    // MARK: - Entry missing after successful unlock (slice 03)

    func test_passwordFill_missingEntryRemovesThatIdentityAndFallsBackToSearch() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        let missingIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        coordinator.targetRecordIdentifier = missingIdentifier

        let identityRemoved = expectation(description: "exactly the stale identity removed")
        CredentialIdentityStoreManager.removeIdentityObserver = { recordIdentifier in
            XCTAssertEqual(recordIdentifier, missingIdentifier)
            identityRemoved.fulfill()
        }

        coordinator.presentPasswordMatchesOrFinish()

        await fulfillment(of: [identityRemoved], timeout: 1)
        XCTAssertNil(presenter.completedCredential)
        let searchView = try XCTUnwrap(presenter.searchView, "The search fallback must present after the stale-identity removal")
        XCTAssertEqual(searchView.entries.count, 2)
    }

    func test_passwordFill_missingLegacyEntryClearsStore() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        coordinator.targetRecordIdentifier = UUID().uuidString

        let storeCleared = expectation(description: "unattributable legacy identifier clears the store")
        CredentialIdentityStoreManager.clearObserver = { storeCleared.fulfill() }

        coordinator.presentPasswordMatchesOrFinish()

        await fulfillment(of: [storeCleared], timeout: 1)
        XCTAssertNil(presenter.completedCredential)
        XCTAssertNotNil(presenter.searchView, "The search fallback still presents")
    }

    func test_passwordFill_expiredEntryIsNotTreatedAsMissing() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let expiredEntry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login",
            expires: true,
            expiryTime: .distantPast
        )

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [expiredEntry], sessionKey: sessionKey)
        coordinator.targetRecordIdentifier = CredentialRecordIdentifier(
            databaseID: UUID(),
            entryID: expiredEntry.id
        ).encoded

        CredentialIdentityStoreManager.removeIdentityObserver = { _ in
            XCTFail("An existing-but-expired entry must not have its identity removed")
        }
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("An existing-but-expired entry must not clear the store")
        }

        coordinator.presentPasswordMatchesOrFinish()

        await CredentialIdentityStoreManager.waitForPendingMutations()
        XCTAssertNil(presenter.completedCredential, "Expired entries are filtered from direct completion")
        let searchView = try XCTUnwrap(presenter.searchView, "The interactive fallback presents as before")
        XCTAssertEqual(searchView.entries.map(\.id), [expiredEntry.id])
    }

    func test_otcPending_missingEntryRemovesIdentityAndPresentsPicker() async throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        coordinator.hasPendingOTCRequest = true
        let missingIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        coordinator.targetRecordIdentifier = missingIdentifier

        let identityRemoved = expectation(description: "stale OTC identity removed")
        CredentialIdentityStoreManager.removeIdentityObserver = { recordIdentifier in
            XCTAssertEqual(recordIdentifier, missingIdentifier)
            identityRemoved.fulfill()
        }

        coordinator.completeOTCRequestFromPending()

        await fulfillment(of: [identityRemoved], timeout: 1)
        XCTAssertNil(presenter.completedOneTimeCode)
        let picker = try XCTUnwrap(presenter.searchView, "The OTC picker fallback must present")
        XCTAssertEqual(picker.entries.count, 2)
    }

    func test_interactivePasskey_missingEntryRemovesIdentityAndCancelsNotFound() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        // The unlocked vault holds no passkey entries at all, so the request's
        // identity cannot resolve by identifier or by ambient rp/credentialID.
        let passwordOnly = try makeTwoGitHubEntries(sessionKey: sessionKey)
        seedUnlockedVaultState(coordinator, entries: passwordOnly, sessionKey: sessionKey)

        let missingIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded
        let identityRemoved = expectation(description: "stale passkey identity removed")
        CredentialIdentityStoreManager.removeIdentityObserver = { recordIdentifier in
            XCTAssertEqual(recordIdentifier, missingIdentifier)
            identityRemoved.fulfill()
        }

        coordinator.completeInteractivePasskeyRequest(makePasskeyRequest(recordIdentifier: missingIdentifier))

        await fulfillment(of: [identityRemoved], timeout: 1)
        XCTAssertEqual(presenter.cancelledError?.code, .credentialIdentityNotFound)
        assertCleanedUp(coordinator)
    }

    func test_passkeyResolution_recordIdentifierStillResolvesEntry() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let privateKey = P256.Signing.PrivateKey()
        let entry = try makePasskeyEntry(privateKey: privateKey, sessionKey: sessionKey)

        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        let request = makePasskeyRequest(
            recordIdentifier: CredentialRecordIdentifier(databaseID: UUID(), entryID: entry.id).encoded
        )

        coordinator.completeInteractivePasskeyRequest(request)

        let credential = try XCTUnwrap(presenter.completedAssertion, "The tagged-identifier happy path must still complete")
        XCTAssertEqual(credential.relyingParty, "example.com")
        assertCleanedUp(coordinator)
    }

    // MARK: - Silent-path resolution (slice 03)

    // `BiometricService.isAvailable` is false under simulator tests, so the
    // silent paths can never complete a fill here; resolution is asserted via
    // the scheduled cleanup observers plus the `.userInteractionRequired`
    // cancellation (the system then relaunches the extension interactively).

    func test_silentFill_staleIdentifierCleansUpAndCancelsUserInteractionRequired() async throws {
        SettingsService.quickAutoFillEnabled = true

        let unknownDatabaseID = UUID()
        let (unknownCoordinator, unknownPresenter) = makeCoordinator()
        let removalScheduled = expectation(description: "targeted removal scheduled")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, _ in
            XCTAssertEqual(databaseID, unknownDatabaseID)
            removalScheduled.fulfill()
        }

        unknownCoordinator.provideCredentialWithoutUserInteraction(
            for: makePasswordIdentity(
                recordIdentifier: CredentialRecordIdentifier(databaseID: unknownDatabaseID, entryID: UUID()).encoded
            )
        )

        await fulfillment(of: [removalScheduled], timeout: 1)
        XCTAssertEqual(unknownPresenter.cancelledError?.code, .userInteractionRequired)
        assertCleanedUp(unknownCoordinator)

        CredentialIdentityStoreManager.removeDatabaseObserver = nil
        let (staleCoordinator, stalePresenter) = makeCoordinator()
        let storeCleared = expectation(description: "clearStore scheduled")
        CredentialIdentityStoreManager.clearObserver = { storeCleared.fulfill() }

        staleCoordinator.provideCredentialWithoutUserInteraction(
            for: makePasswordIdentity(recordIdentifier: "v9:garbage")
        )

        await fulfillment(of: [storeCleared], timeout: 1)
        XCTAssertEqual(stalePresenter.cancelledError?.code, .userInteractionRequired)
        assertCleanedUp(staleCoordinator)
    }

    func test_silentFill_zeroEnabledDatabasesCancelsUserInteractionRequired() async throws {
        SettingsService.quickAutoFillEnabled = true
        let (coordinator, presenter) = makeCoordinator()

        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in
            XCTFail("An identifier-less request with no databases schedules no targeted removal")
        }
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("An identifier-less request with no databases must not clear the store")
        }
        CredentialIdentityStoreManager.removeIdentityObserver = { _ in
            XCTFail("An identifier-less request with no databases must not remove identities")
        }

        coordinator.provideCredentialWithoutUserInteraction(
            for: makePasswordIdentity(recordIdentifier: nil)
        )

        XCTAssertEqual(presenter.cancelledError?.code, .userInteractionRequired)
        assertCleanedUp(coordinator)
    }

    // MARK: - Database switcher: presence and source list (slice 06)

    func test_searchView_carriesSwitcherWithTwoEnabledDatabases() throws {
        let scenario = try makePresentedTwoDatabaseSearch()

        let searchView = try XCTUnwrap(scenario.presenter.searchView)
        let switcher = try XCTUnwrap(searchView.databaseSwitcher, "Two enabled databases must offer the switcher")
        XCTAssertEqual(switcher.databases.map(\.id), [scenario.databaseA.id, scenario.databaseB.id])
        XCTAssertEqual(switcher.currentDatabaseID, scenario.databaseA.id, "The open database carries the checkmark")
    }

    func test_searchView_omitsSwitcherWithSingleEnabledDatabase() throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "only.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: try makeTwoGitHubEntries(sessionKey: sessionKey), sessionKey: sessionKey)
        coordinator.activeDatabaseReference = databaseA

        coordinator.presentPasswordMatchesOrFinish()

        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertNil(searchView.databaseSwitcher, "A lone enabled database has nothing to switch to")
    }

    /// The single-strict-match auto-complete is scoped to the ONE database the
    /// request resolved: with two enabled databases that each hold a single
    /// github.com entry, the open vault sees one match and fills it outright,
    /// so no picker — and therefore no switcher — is ever presented and the
    /// other database's entry is unreachable for that request. Pins the
    /// current behavior; changing it (e.g. always presenting the picker when
    /// another enabled database exists) should fail here first.
    func test_singleStrictMatch_autoCompletesWithoutOfferingTheOtherEnabledDatabase() throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "single-match-a.kdbx")
        try makeRegisteredDatabase(named: "single-match-b.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)
        let onlyMatchInVaultA = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [onlyMatchInVaultA], sessionKey: sessionKey)
        coordinator.activeDatabaseReference = databaseA

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(
            presenter.completedCredential,
            "A lone host-level match in the resolved database fills without a picker"
        )
        XCTAssertEqual(credential.user, "octocat")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertNil(
            presenter.searchView,
            "No picker is presented, so the second enabled database is unreachable for this request"
        )
        assertCleanedUp(coordinator)
    }

    func test_strictMatchWithAdditionalBroadMatch_presentsPicker() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(
                title: "GitHub",
                username: "octocat",
                password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
                url: "https://github.com/login"
            ),
            KPEntry(
                title: "github.com legacy",
                username: "legacy",
                password: try EncryptedValue.encrypt("hunter3", using: sessionKey),
                url: "https://unrelated.example"
            ),
        ]

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        XCTAssertNil(presenter.completedCredential, "A broad match must prevent zero-interaction completion")
        let searchView = try XCTUnwrap(presenter.searchView)
        XCTAssertEqual(searchView.entries.map(\.title), ["GitHub"])
        searchView.onCancel()
        assertCleanedUp(coordinator)
    }

    func test_searchView_switcherNeverListsDisabledDatabases() throws {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        try makeRegisteredDatabase(named: "b.kdbx", autoFillEnabled: false)
        let databaseC = try makeRegisteredDatabase(named: "c.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: try makeTwoGitHubEntries(sessionKey: sessionKey), sessionKey: sessionKey)
        coordinator.activeDatabaseReference = databaseA

        coordinator.presentPasswordMatchesOrFinish()

        let switcher = try XCTUnwrap(presenter.searchView?.databaseSwitcher)
        XCTAssertEqual(
            Set(switcher.databases.map(\.id)),
            [databaseA.id, databaseC.id],
            "Disabled databases never appear in the switcher's source list"
        )

        DatabaseListStore.setAutoFillEnabled(false, for: databaseC)
        presenter.searchView = nil
        coordinator.presentPasswordMatchesOrFinish()

        let representedSearchView = try XCTUnwrap(presenter.searchView)
        XCTAssertNil(representedSearchView.databaseSwitcher, "One enabled database left — the switcher disappears")
    }

    func test_byIdentityExpiredConfirmations_carryNoSwitcher() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        try makeRegisteredDatabase(named: "b.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)

        // OTC by-identity expired confirmation: single specific credential,
        // pending request already consumed — no switcher even though two
        // databases are enabled.
        let (otcCoordinator, otcPresenter) = makeCoordinator()
        let expiredTOTP = try makeTOTPEntry(title: "Expired TOTP", sessionKey: sessionKey, expired: true)
        otcCoordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(otcCoordinator, entries: [expiredTOTP], sessionKey: sessionKey)
        otcCoordinator.activeDatabaseReference = databaseA
        otcCoordinator.hasPendingOTCRequest = true
        otcCoordinator.targetRecordIdentifier = CredentialRecordIdentifier(
            databaseID: databaseA.id,
            entryID: expiredTOTP.id
        ).encoded

        otcCoordinator.completeOTCRequestFromPending()

        let otcConfirmation = try XCTUnwrap(otcPresenter.searchView, "The expired-entry confirmation must present")
        XCTAssertEqual(otcConfirmation.entries.map(\.id), [expiredTOTP.id])
        XCTAssertNil(otcConfirmation.databaseSwitcher, "By-identity expired confirmations carry no switcher")

        // Passkey by-identity expired confirmation: same contract.
        let (passkeyCoordinator, passkeyPresenter) = makeCoordinator()
        let privateKey = P256.Signing.PrivateKey()
        let expiredPasskey = try makePasskeyEntry(privateKey: privateKey, sessionKey: sessionKey, expired: true)
        seedUnlockedVaultState(passkeyCoordinator, entries: [expiredPasskey], sessionKey: sessionKey)
        passkeyCoordinator.activeDatabaseReference = databaseA

        passkeyCoordinator.completeInteractivePasskeyRequest(
            makePasskeyRequest(
                recordIdentifier: CredentialRecordIdentifier(
                    databaseID: databaseA.id,
                    entryID: expiredPasskey.id
                ).encoded
            )
        )

        let passkeyConfirmation = try XCTUnwrap(passkeyPresenter.searchView)
        XCTAssertEqual(passkeyConfirmation.entries.map(\.id), [expiredPasskey.id])
        XCTAssertNil(passkeyConfirmation.databaseSwitcher)
    }

    // MARK: - Database switcher: switch flow (slice 06)

    func test_switch_presentsUnlockPromptPinnedToTargetAndRetainsPreviousVault() throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        switcher.onSwitch(target, "typed")

        XCTAssertNotNil(scenario.presenter.unlockPrompt, "The switched-to database's unlock prompt must present")
        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseB.id)
        XCTAssertEqual(scenario.coordinator.pendingSwitchPreviousDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertEqual(scenario.coordinator.pendingSwitchSearchText, "typed")
        XCTAssertNotNil(scenario.coordinator.sessionKey, "The previous vault stays live while the switch unlock is pending")
        XCTAssertEqual(scenario.coordinator.parsedEntries.count, 2, "The previous vault's entries remain restorable")
    }

    func test_switch_toCurrentDatabaseIsIgnored() throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        scenario.presenter.unlockPrompt = nil

        scenario.coordinator.switchDatabase(to: scenario.databaseA, currentSearchText: "typed")

        XCTAssertNil(scenario.presenter.unlockPrompt, "Switching to the open database is a no-op")
        XCTAssertNil(scenario.coordinator.pendingSwitchSearchText)
        XCTAssertNil(scenario.coordinator.pendingSwitchPreviousDatabaseReference)
        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertNotNil(scenario.coordinator.sessionKey)
    }

    func test_switch_toDatabaseDisabledSinceListingRepresentsCurrentSearch() throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        // The main app disabled the target between building the switcher and
        // the tap (cross-process): the shell has already dismissed the search
        // view, so the coordinator must re-present rather than dead-end.
        DatabaseListStore.setAutoFillEnabled(false, for: scenario.databaseB)
        scenario.presenter.searchView = nil

        switcher.onSwitch(target, "")

        XCTAssertNil(scenario.presenter.unlockPrompt, "No unlock for a no-longer-eligible target")
        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertNil(scenario.coordinator.pendingSwitchPreviousDatabaseReference)
        XCTAssertNil(scenario.coordinator.pendingSwitchSearchText, "The stash is consumed by the re-presentation")
        let representedSearchView = try XCTUnwrap(scenario.presenter.searchView, "The current database's search re-presents")
        XCTAssertEqual(representedSearchView.entries.count, 2)
        XCTAssertNil(representedSearchView.databaseSwitcher, "Only one enabled database remains")
    }

    func test_switchUnlockSuccess_retargetsSessionAndDefault() async throws {
        // A service identifier matching nothing in either vault keeps both
        // databases' flows on the search view (no single-match auto-complete
        // against the fixture's real entries).
        let scenario = try makePresentedTwoDatabaseSearch(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: "no-such-service.example", type: .domain)
        )
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        // Give the switched-to database real KDBX bytes in the shared cache.
        let fixtureData = try Data(
            contentsOf: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        )
        try DatabaseListStore.cacheDatabaseCopy(fixtureData, for: scenario.databaseB)

        switcher.onSwitch(target, "git")
        let prompt = try XCTUnwrap(scenario.presenter.unlockPrompt)

        scenario.presenter.searchView = nil
        let searchRepresented = expectation(description: "the new database's search presented")
        scenario.presenter.onSearchViewPresented = { searchRepresented.fulfill() }
        scenario.presenter.onUnlockErrorPresented = {
            XCTFail("Unlocking the fixture must succeed: \(scenario.presenter.unlockError?.message ?? "unknown error")")
        }

        prompt.onSubmitPassword("testpassword123")
        await fulfillment(of: [searchRepresented], timeout: 60)

        let searchView = try XCTUnwrap(scenario.presenter.searchView)
        XCTAssertFalse(searchView.entries.isEmpty, "The re-presented search shows the new database's entries")
        XCTAssertFalse(
            searchView.entries.map(\.title).contains("GitHub Work"),
            "The previous database's seeded entries must have been replaced by the fixture's"
        )
        XCTAssertEqual(searchView.initialSearchText, "git", "The typed search text survives the switch")

        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseB.id)
        XCTAssertNil(scenario.coordinator.pendingSwitchPreviousDatabaseReference, "A successful unlock commits the switch")
        XCTAssertNil(scenario.coordinator.pendingSwitchSearchText)

        // Retarget contract: in-session save/passkey registration read
        // `activeDatabaseReference`, and the next launch's identifier-less
        // flows resolve `defaultAutoFillDatabase` — all now point at B.
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, scenario.databaseB.id)
        XCTAssertNotNil(
            DatabaseListStore.databases.first { $0.id == scenario.databaseB.id }?.lastOpenedAt,
            "The switched-to database records the unlock"
        )
        XCTAssertEqual(DatabaseListStore.defaultAutoFillDatabase?.id, scenario.databaseB.id)
    }

    func test_switchDuringOTCList_reRunsOTCPickerAfterUnlock() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "a.kdbx")
        let databaseB = try makeRegisteredDatabase(named: "b.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)
        let totpEntries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]

        coordinator.prepareOneTimeCodeCredentialList(for: [githubServiceIdentifier()])
        seedUnlockedVaultState(coordinator, entries: totpEntries, sessionKey: sessionKey)
        coordinator.activeDatabaseReference = databaseA

        coordinator.presentOTCMatchesOrFinish()
        let switcher = try XCTUnwrap(presenter.searchView?.databaseSwitcher, "The OTC picker offers the switcher")
        let target = try XCTUnwrap(switcher.databases.first { $0.id == databaseB.id })

        switcher.onSwitch(target, "gh")
        let prompt = try XCTUnwrap(presenter.unlockPrompt)
        presenter.searchView = nil

        prompt.onCancel()

        XCTAssertNil(presenter.cancelledError, "Cancelling a switch unlock must not cancel the request")
        let picker = try XCTUnwrap(presenter.searchView, "The OTC picker re-presents after the cancelled switch")
        XCTAssertEqual(
            picker.entries.map(\.title).sorted(),
            ["GitHub", "GitHub Work"],
            "The re-presented picker holds the TOTP entries again, not the password list"
        )
        XCTAssertEqual(picker.initialSearchText, "gh", "The typed text survives the cancelled switch")
        XCTAssertTrue(coordinator.hasPendingOTCListRequest, "The OTC list flag is retained until a completion path cleans up")
        XCTAssertEqual(coordinator.activeDatabaseReference?.id, databaseA.id)
    }

    func test_otcStaleFallback_reArmsListFlag() throws {
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw XCTSkip("One-time-code requests require iOS 18 / macOS 15")
        }

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let totpEntries = [
            try makeTOTPEntry(title: "GitHub", sessionKey: sessionKey),
            try makeTOTPEntry(title: "GitHub Work", sessionKey: sessionKey),
        ]

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: totpEntries, sessionKey: sessionKey)
        coordinator.hasPendingOTCRequest = true
        coordinator.targetRecordIdentifier = CredentialRecordIdentifier(databaseID: UUID(), entryID: UUID()).encoded

        coordinator.completeOTCRequestFromPending()

        XCTAssertNotNil(presenter.searchView, "The fallback picker must present")
        XCTAssertFalse(coordinator.hasPendingOTCRequest)
        XCTAssertTrue(
            coordinator.hasPendingOTCListRequest,
            "The by-identity request degrades into a list request so a switch can re-serve it"
        )
    }

    // No test for the parameters-driven passkey list flow:
    // `ASPasskeyCredentialRequestParameters` declares `init` as `NS_UNAVAILABLE`
    // (iOS 26.5 SDK), so it is not test-constructible. The shared `afterUnlock`
    // dispatch that would re-serve it is pinned by
    // `test_switchDuringOTCList_reRunsOTCPickerAfterUnlock` and
    // `test_switchCancel_restoresPreviousDatabaseAndRepresentsSearch`.

    // MARK: - Database switcher: cancel semantics

    func test_switchCancel_restoresPreviousDatabaseAndRepresentsSearch() throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        switcher.onSwitch(target, "typed")
        let prompt = try XCTUnwrap(scenario.presenter.unlockPrompt)
        scenario.presenter.searchView = nil

        prompt.onCancel()

        XCTAssertNil(scenario.presenter.cancelledError, "Cancelling a switch unlock must not cancel the request")
        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertNil(scenario.coordinator.pendingSwitchPreviousDatabaseReference)
        XCTAssertNil(scenario.coordinator.pendingSwitchSearchText, "The stash is consumed by the re-presentation")

        let searchView = try XCTUnwrap(scenario.presenter.searchView, "The previous database's search re-presents from retained state")
        XCTAssertEqual(searchView.entries.count, 2)
        XCTAssertEqual(searchView.initialSearchText, "typed")

        // The previous vault was never torn down: selecting still completes.
        searchView.onSelect(scenario.entries[0])
        let credential = try XCTUnwrap(scenario.presenter.completedCredential)
        XCTAssertEqual(credential.user, "octocat")
        XCTAssertEqual(credential.password, "hunter2")
        assertCleanedUp(scenario.coordinator)
    }

    func test_switchUnlockErrorCancel_restoresPreviousDatabase() async throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        switcher.onSwitch(target, "typed")
        let prompt = try XCTUnwrap(scenario.presenter.unlockPrompt)

        // The target has no cached KDBX bytes (its bookmarked file holds
        // placeholder bytes), so any password fails. This is also the
        // biometric-cancel-mid-switch shape: a cancelled biometric prompt
        // throws into the same showErrorAndRetry → error alert → Cancel path.
        let errorPresented = expectation(description: "unlock error presented")
        scenario.presenter.onUnlockErrorPresented = { errorPresented.fulfill() }
        prompt.onSubmitPassword("wrong-password")
        await fulfillment(of: [errorPresented], timeout: 10)

        scenario.presenter.searchView = nil
        let unlockError = try XCTUnwrap(scenario.presenter.unlockError)

        unlockError.onCancel()

        XCTAssertNil(scenario.presenter.cancelledError, "Cancelling a switch's failed unlock must not cancel the request")
        XCTAssertEqual(scenario.coordinator.activeDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertNil(scenario.coordinator.pendingSwitchPreviousDatabaseReference)
        XCTAssertNotNil(scenario.coordinator.sessionKey, "The previous vault survives the failed switch")

        let searchView = try XCTUnwrap(scenario.presenter.searchView)
        XCTAssertEqual(searchView.entries.count, 2)
        XCTAssertEqual(searchView.initialSearchText, "typed")
    }

    func test_switchUnlockErrorRetry_staysPinnedToTarget() async throws {
        let scenario = try makePresentedTwoDatabaseSearch()
        let switcher = try XCTUnwrap(scenario.presenter.searchView?.databaseSwitcher)
        let target = try XCTUnwrap(switcher.databases.first { $0.id == scenario.databaseB.id })

        switcher.onSwitch(target, "typed")
        let prompt = try XCTUnwrap(scenario.presenter.unlockPrompt)

        let errorPresented = expectation(description: "unlock error presented")
        scenario.presenter.onUnlockErrorPresented = { errorPresented.fulfill() }
        prompt.onSubmitPassword("wrong-password")
        await fulfillment(of: [errorPresented], timeout: 10)

        scenario.presenter.unlockPrompt = nil
        let unlockError = try XCTUnwrap(scenario.presenter.unlockError)

        unlockError.onRetry()

        XCTAssertNotNil(scenario.presenter.unlockPrompt, "Retry re-presents the unlock prompt")
        XCTAssertEqual(
            scenario.coordinator.activeDatabaseReference?.id,
            scenario.databaseB.id,
            "The retry loop keeps targeting the switched-to database; only Cancel restores"
        )
        XCTAssertEqual(scenario.coordinator.pendingSwitchPreviousDatabaseReference?.id, scenario.databaseA.id)
        XCTAssertEqual(scenario.coordinator.pendingSwitchSearchText, "typed", "The stash is untouched until a search presents")
    }

    // MARK: - Copy verification code on AutoFill (issue #23)

    #if os(iOS)

    func test_copyTOTPOnFill_enabledCopiesCurrentCodeAndStillCompletesFill() throws {
        SettingsService.autoFillCopyTOTP = true
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = try makeGitHubEntryWithTOTP(sessionKey: sessionKey)
        var copiedValues: [String] = []
        coordinator.copyToClipboard = { copiedValues.append($0) }

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        // The code is time-based, so bracket the fill with the codes valid on
        // either side of it; a period rollover mid-test then still matches.
        let totpConfig = try XCTUnwrap(entry.totpConfig)
        let codeBefore = TOTPGenerator.generateCode(config: totpConfig, sessionKey: sessionKey)
        coordinator.presentPasswordMatchesOrFinish()
        let codeAfter = TOTPGenerator.generateCode(config: totpConfig, sessionKey: sessionKey)

        let credential = try XCTUnwrap(presenter.completedCredential, "The password fill must still complete")
        XCTAssertEqual(credential.user, "octocat")
        XCTAssertEqual(credential.password, "hunter2")

        XCTAssertEqual(copiedValues.count, 1, "Exactly one clipboard write per fill")
        let copiedCode = try XCTUnwrap(copiedValues.first)
        XCTAssertEqual(copiedCode.count, totpConfig.digits, "Copied code must have the configured digit count")
        XCTAssertTrue(copiedCode.allSatisfy(\.isNumber), "Copied code must be all digits, got \(copiedCode)")
        XCTAssertTrue(
            [codeBefore, codeAfter].contains(copiedCode),
            "Copied code must be the entry's current TOTP code"
        )
        assertCleanedUp(coordinator)
    }

    func test_copyTOTPOnFill_disabledByDefaultCopiesNothing() throws {
        // No explicit write: the setting must be off out of the box.
        XCTAssertFalse(SettingsService.autoFillCopyTOTP, "Copy-on-AutoFill must default to off")

        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = try makeGitHubEntryWithTOTP(sessionKey: sessionKey)
        var copiedValues: [String] = []
        coordinator.copyToClipboard = { copiedValues.append($0) }

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        XCTAssertNotNil(presenter.completedCredential)
        XCTAssertTrue(copiedValues.isEmpty, "An opted-out fill must never touch the clipboard")
        assertCleanedUp(coordinator)
    }

    func test_copyTOTPOnFill_enabledButEntryHasNoTOTPCopiesNothing() throws {
        SettingsService.autoFillCopyTOTP = true
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let entry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )
        var copiedValues: [String] = []
        coordinator.copyToClipboard = { copiedValues.append($0) }

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential, "A code-less entry must still fill")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertTrue(copiedValues.isEmpty, "An entry without a verification code has nothing to copy")
        assertCleanedUp(coordinator)
    }

    func test_copyTOTPOnFill_ungeneratableCodeIsSkippedWithoutFailingTheFill() throws {
        SettingsService.autoFillCopyTOTP = true
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        // Secret sealed with a foreign key: generation yields the "------"
        // sentinel, which must be swallowed rather than pasted or thrown.
        let entry = try makeGitHubEntryWithTOTP(
            sessionKey: sessionKey,
            secretSealingKey: SymmetricKey(size: .bits256)
        )
        var copiedValues: [String] = []
        coordinator.copyToClipboard = { copiedValues.append($0) }

        coordinator.serviceIdentifiers = [githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: [entry], sessionKey: sessionKey)

        coordinator.presentPasswordMatchesOrFinish()

        let credential = try XCTUnwrap(presenter.completedCredential, "A failed code generation must not fail the fill")
        XCTAssertEqual(credential.password, "hunter2")
        XCTAssertTrue(copiedValues.isEmpty, "The '------' sentinel must never reach the clipboard")
        assertCleanedUp(coordinator)
    }

    // MARK: - Silent-path escalation for copy-on-AutoFill (issue #23)

    // `BiometricService.isAvailable` is false under simulator tests, so
    // `provideCredentialWithoutUserInteraction` always short-circuits to
    // `.userInteractionRequired` before it can reach a fill — the silent path
    // cannot distinguish the escalation from that short-circuit here. The
    // escalation decision itself is `shouldCopyTOTPCode(for:)`, which the
    // silent path consults at both of its completion sites, so it is asserted
    // directly instead.

    func test_shouldCopyTOTPCode_trueOnlyWhenOptedInAndEntryHasCode() throws {
        let (coordinator, _) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let totpEntry = try makeGitHubEntryWithTOTP(sessionKey: sessionKey)
        let plainEntry = KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login"
        )

        SettingsService.autoFillCopyTOTP = false
        XCTAssertFalse(coordinator.shouldCopyTOTPCode(for: totpEntry), "Opted out: no copy, no escalation")
        XCTAssertFalse(coordinator.shouldCopyTOTPCode(for: plainEntry))

        SettingsService.autoFillCopyTOTP = true
        XCTAssertTrue(coordinator.shouldCopyTOTPCode(for: totpEntry), "Opted in with a code: copy and escalate")
        XCTAssertFalse(
            coordinator.shouldCopyTOTPCode(for: plainEntry),
            "A code-less entry keeps the fully silent QuickType path"
        )
    }

    func test_silentFill_optedInStillRequiresInteractionUnderUnavailableBiometrics() async throws {
        SettingsService.quickAutoFillEnabled = true
        SettingsService.autoFillCopyTOTP = true
        let (coordinator, presenter) = makeCoordinator()

        coordinator.provideCredentialWithoutUserInteraction(
            for: makePasswordIdentity(recordIdentifier: nil)
        )

        XCTAssertEqual(presenter.cancelledError?.code, .userInteractionRequired)
        XCTAssertNil(presenter.completedCredential, "The silent path must never fill without escalating first")
        assertCleanedUp(coordinator)
    }

    /// A github.com password entry that also carries a verification code, so a
    /// single-match fill exercises the copy alongside the credential handoff.
    /// `secretSealingKey` defaults to the session key; passing a foreign key
    /// makes the code ungeneratable.
    private func makeGitHubEntryWithTOTP(
        sessionKey: SymmetricKey,
        secretSealingKey: SymmetricKey? = nil
    ) throws -> KPEntry {
        KPEntry(
            title: "GitHub",
            username: "octocat",
            password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
            url: "https://github.com/login",
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: secretSealingKey ?? sessionKey)
            )
        )
    }

    #endif

    // MARK: - Helpers

    private func makeCoordinator() -> (CredentialProviderCoordinator, CredentialProviderPresentingSpy) {
        let presenter = CredentialProviderPresentingSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)
        return (coordinator, presenter)
    }

    private func githubServiceIdentifier() -> ASCredentialServiceIdentifier {
        ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)
    }

    /// Registers an AutoFill-enabled database and points the active pointer
    /// at it so identifier-less interactive flows resolve a default database.
    /// Since slice 03 an empty registry presents the no-enabled-databases
    /// empty state instead of the unlock prompt, so cleanup-path tests that
    /// drive the unlock prompt must seed a resolvable default first.
    /// (`defaultAutoFillDatabase` requires the reference to be *registered*;
    /// the pointer alone is not enough, and registration alone is not enough
    /// either because a never-opened reference has `lastOpenedAt == nil`.)
    @discardableResult
    private func seedResolvableDefaultDatabase() throws -> DatabaseReference {
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "default.kdbx")
        )
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id
        return reference
    }

    private func makeTemporaryFileURL(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("fixture".utf8).write(to: url)
        return url
    }

    /// Registers an AutoFill-participating database in the shared registry.
    /// The bookmarked file holds placeholder bytes, so unlocking it fails —
    /// resolution/switcher tests that need a real unlock write fixture bytes
    /// to `DatabaseListStore.cacheLocation(for:)` separately.
    @discardableResult
    private func makeRegisteredDatabase(
        named name: String,
        autoFillEnabled: Bool = true
    ) throws -> DatabaseReference {
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: name),
            autoFillEnabled: autoFillEnabled
        )
        DatabaseListStore.update(reference)
        return reference
    }

    private func makePasswordIdentity(recordIdentifier: String?) -> ASPasswordCredentialIdentity {
        ASPasswordCredentialIdentity(
            serviceIdentifier: githubServiceIdentifier(),
            user: "octocat",
            recordIdentifier: recordIdentifier
        )
    }

    private struct SwitcherScenario {
        let coordinator: CredentialProviderCoordinator
        let presenter: CredentialProviderPresentingSpy
        let databaseA: DatabaseReference
        let databaseB: DatabaseReference
        let entries: [KPEntry]
    }

    /// Registers two AutoFill-enabled databases, seeds an unlocked vault
    /// pinned to the first, and presents the password search view — the
    /// starting position of every switcher-driven test. Database A's vault
    /// holds the two GitHub entries; database B's bookmarked file holds
    /// placeholder bytes, so its unlock fails unless the test writes fixture
    /// bytes to its shared cache first.
    private func makePresentedTwoDatabaseSearch(
        serviceIdentifier: ASCredentialServiceIdentifier? = nil
    ) throws -> SwitcherScenario {
        let (coordinator, presenter) = makeCoordinator()
        let databaseA = try makeRegisteredDatabase(named: "switch-a.kdbx")
        let databaseB = try makeRegisteredDatabase(named: "switch-b.kdbx")
        let sessionKey = SymmetricKey(size: .bits256)
        let entries = try makeTwoGitHubEntries(sessionKey: sessionKey)

        coordinator.serviceIdentifiers = [serviceIdentifier ?? githubServiceIdentifier()]
        seedUnlockedVaultState(coordinator, entries: entries, sessionKey: sessionKey)
        coordinator.activeDatabaseReference = databaseA

        coordinator.presentPasswordMatchesOrFinish()

        return SwitcherScenario(
            coordinator: coordinator,
            presenter: presenter,
            databaseA: databaseA,
            databaseB: databaseB,
            entries: entries
        )
    }

    /// Two password entries matching the github.com service identifier —
    /// enough matches that the interactive path presents a picker instead of
    /// auto-completing, so identifier-driven completions are unambiguous.
    private func makeTwoGitHubEntries(sessionKey: SymmetricKey) throws -> [KPEntry] {
        [
            KPEntry(
                title: "GitHub",
                username: "octocat",
                password: try EncryptedValue.encrypt("hunter2", using: sessionKey),
                url: "https://github.com/login"
            ),
            KPEntry(
                title: "GitHub Work",
                username: "worktocat",
                password: try EncryptedValue.encrypt("hunter3", using: sessionKey),
                url: "https://github.com/enterprise"
            ),
        ]
    }

    private func makeTOTPEntry(
        title: String,
        url: String = "https://github.com/login",
        sessionKey: SymmetricKey,
        expired: Bool = false
    ) throws -> KPEntry {
        KPEntry(
            title: title,
            url: url,
            totpConfig: TOTPConfig(
                secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: sessionKey)
            ),
            expires: expired,
            expiryTime: expired ? .distantPast : nil
        )
    }

    /// A passkey entry for relying party `example.com` whose credential ID is
    /// the base64 of "test-credential-id" (shared across entries so identity
    /// lookups can be disambiguated purely by record identifier/user handle).
    private func makePasskeyEntry(
        title: String = "Passkey Entry",
        userHandleBase64: String = "dXNlci1oYW5kbGU",
        privateKey: P256.Signing.PrivateKey,
        sessionKey: SymmetricKey,
        expired: Bool = false
    ) throws -> KPEntry {
        KPEntry(
            title: title,
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: userHandleBase64,
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt(pemEncode(privateKey), using: sessionKey),
            expires: expired,
            expiryTime: expired ? .distantPast : nil
        )
    }

    private func makePasskeyRequest(
        recordIdentifier: String?,
        credentialID: Data = Data("test-credential-id".utf8),
        userHandle: Data = Data("user-handle".utf8)
    ) -> ASPasskeyCredentialRequest {
        let identity = ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: "example.com",
            userName: "alice@example.com",
            credentialID: credentialID,
            userHandle: userHandle,
            recordIdentifier: recordIdentifier
        )
        return ASPasskeyCredentialRequest(
            credentialIdentity: identity,
            clientDataHash: Data(repeating: 7, count: 32),
            userVerificationPreference: .preferred,
            supportedAlgorithms: [.ES256]
        )
    }

    /// Seed the coordinator with state equivalent to an unlocked vault so that
    /// teardown is observable.
    private func seedUnlockedVaultState(
        _ coordinator: CredentialProviderCoordinator,
        entries: [KPEntry] = [],
        sessionKey: SymmetricKey = SymmetricKey(size: .bits256)
    ) {
        coordinator.parsedEntries = entries
        coordinator.parsedRootGroup = KPGroup(name: "Root")
        coordinator.parsedMeta = KPMeta()
        coordinator.sessionKey = sessionKey
        coordinator.compositeKey = Data("composite-key".utf8)
        coordinator.openTimeSHA512 = Data("open-sha".utf8)
    }

    private func assertCleanedUp(
        _ coordinator: CredentialProviderCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(coordinator.sessionKey, "session key must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.compositeKey, "composite key must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.openTimeSHA512, "open-time hash must be cleared", file: file, line: line)
        XCTAssertTrue(coordinator.parsedEntries.isEmpty, "parsed entries must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedRootGroup, "parsed root group must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedMeta, "parsed meta must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.parsedFormatVersion, "parsed format version must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.activeDatabaseReference, "active database reference must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.targetRecordIdentifier, "target record identifier must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRequest, "pending passkey request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRequestParameters, "pending passkey parameters must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationRequest, "pending passkey registration request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationFailureMessage, "pending passkey registration failure must be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.hasPendingOTCRequest, "pending OTC flag must be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.hasPendingOTCListRequest, "pending OTC list flag must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingReadOnlyCancellationMessage, "pending read-only message must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingSavePasswordRequestStorage, "pending save request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingGeneratePasswordsRequestStorage, "pending generate request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingSwitchPreviousDatabaseReference, "pending switch reference must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingSwitchSearchText, "pending switch search text must be cleared", file: file, line: line)
    }

    /// Encode a P256 private key as PKCS#8 PEM (same shape the passkey
    /// importer produces).
    private func pemEncode(_ key: P256.Signing.PrivateKey) -> String {
        let derData = key.derRepresentation
        let base64 = derData.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"
    }
}
