// Passkey-registration flow tests for `CredentialProviderCoordinator`.
// The whole flow is iOS-only (the macOS shell answers registration requests
// with `.userCanceled` before the coordinator is involved — covered by
// CredentialProviderShellMacTests), so every test here is gated to iOS.
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CredentialProviderRegistrationTests: XCTestCase {
#if os(iOS)
    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    // MARK: - Prepare

    func test_prepare_pinsDefaultDatabaseAndDefersUnlock() throws {
        let (coordinator, presenter) = makeCoordinator()
        let reference = try seedResolvableDefaultDatabase()

        coordinator.prepareInterface(forPasskeyRegistration: makeRegistrationRequest())

        XCTAssertNotNil(coordinator.pendingPasskeyRegistrationRequest)
        XCTAssertEqual(coordinator.activeDatabaseReference?.id, reference.id)
        XCTAssertTrue(coordinator.pendingUnlock)
        XCTAssertFalse(coordinator.pendingNoEnabledDatabasesPresentation)
        XCTAssertNil(coordinator.pendingReadOnlyCancellationMessage)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationFailureMessage)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)
    }

    func test_prepare_wrongRequestType_cancelsFailed() {
        let (coordinator, presenter) = makeCoordinator()

        let passwordRequest = ASPasswordCredentialRequest(
            credentialIdentity: ASPasswordCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: "example.com", type: .domain),
                user: "alice",
                recordIdentifier: nil
            )
        )

        coordinator.prepareInterface(forPasskeyRegistration: passwordRequest)

        XCTAssertEqual(presenter.cancelledError?.code, .failed)
        assertCleanedUp(coordinator)
    }

    func test_prepare_emptyUserNameOrUserHandle_cancelsFailed() {
        for request in [
            makeRegistrationRequest(userName: ""),
            makeRegistrationRequest(userHandle: Data()),
        ] {
            let (coordinator, presenter) = makeCoordinator()

            coordinator.prepareInterface(forPasskeyRegistration: request)

            XCTAssertEqual(presenter.cancelledError?.code, .failed)
            assertCleanedUp(coordinator)
        }
    }

    func test_prepare_nonES256_presentsDeferredFailure_thenCancelsFailed() throws {
        let (coordinator, presenter) = makeCoordinator()
        try seedResolvableDefaultDatabase()

        coordinator.prepareInterface(
            forPasskeyRegistration: makeRegistrationRequest(supportedAlgorithms: [])
        )

        XCTAssertNotNil(coordinator.pendingPasskeyRegistrationFailureMessage)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationRequest)
        XCTAssertFalse(coordinator.pendingUnlock)
        XCTAssertTrue(
            presenter.cancelledErrorCodes.isEmpty,
            "The failure must be shown to the user before the request is cancelled"
        )

        presenter.isPresentationActive = true
        coordinator.presentationDidBecomeActive()

        let failure = try XCTUnwrap(presenter.passkeyRegistrationFailure)
        XCTAssertFalse(failure.message.isEmpty)

        failure.onAcknowledge()

        XCTAssertEqual(presenter.cancelledError?.code, .failed)
        assertCleanedUp(coordinator)
    }

    func test_prepare_noEnabledDatabases_presentsDeferredEmptyState_thenCancelsUserCanceled() throws {
        let (coordinator, presenter) = makeCoordinator()

        coordinator.prepareInterface(forPasskeyRegistration: makeRegistrationRequest())

        XCTAssertTrue(coordinator.pendingNoEnabledDatabasesPresentation)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationRequest)
        XCTAssertFalse(coordinator.pendingUnlock)
        XCTAssertTrue(
            presenter.cancelledErrorCodes.isEmpty,
            "Zero enabled databases must defer the empty state, not cancel with .failed"
        )

        presenter.isPresentationActive = true
        coordinator.presentationDidBecomeActive()

        let emptyState = try XCTUnwrap(presenter.noEnabledDatabasesState)
        emptyState.onDismiss()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_prepare_readOnlyDatabase_presentsDeferredReadOnlyNotice_thenCancelsUserCanceled() throws {
        let (coordinator, presenter) = makeCoordinator()
        var reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "readonly.kdbx")
        )
        reference.isReadOnly = true
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id

        coordinator.prepareInterface(forPasskeyRegistration: makeRegistrationRequest())

        XCTAssertNotNil(coordinator.pendingReadOnlyCancellationMessage)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationRequest)
        XCTAssertFalse(coordinator.pendingUnlock)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)

        presenter.isPresentationActive = true
        coordinator.presentationDidBecomeActive()

        let notice = try XCTUnwrap(presenter.readOnlyNotice)
        notice.onAcknowledge()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    // MARK: - Post-unlock

    func test_afterUnlock_kdbx31_presentsReadOnlyNoticeAndCancels() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)
        coordinator.parsedFormatVersion = .kdbx3_1
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())

        let notice = try XCTUnwrap(presenter.readOnlyNotice)
        XCTAssertNil(presenter.passkeyCreator, "A KDBX 3.1 vault must not offer the creator")

        notice.onAcknowledge()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_afterUnlock_excludedCredentialMatch_cancelsMatchedExcludedCredential() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let existingEntry = try makePasskeyEntry(
            privateKey: P256.Signing.PrivateKey(),
            sessionKey: sessionKey
        )
        seedUnlockedVaultState(coordinator, entries: [existingEntry], sessionKey: sessionKey)
        coordinator.excludedCredentialIDs = { _ in [Data("test-credential-id".utf8)] }
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())

        XCTAssertEqual(presenter.cancelledError?.code, .matchedExcludedCredential)
        XCTAssertNil(presenter.passkeyCreator)
        assertCleanedUp(coordinator)
    }

    func test_afterUnlock_excludedCredentialNonMatch_presentsCreator() throws {
        let (coordinator, presenter) = makeCoordinator()
        let sessionKey = SymmetricKey(size: .bits256)
        let existingEntry = try makePasskeyEntry(
            privateKey: P256.Signing.PrivateKey(),
            sessionKey: sessionKey
        )
        seedUnlockedVaultState(coordinator, entries: [existingEntry], sessionKey: sessionKey)
        coordinator.excludedCredentialIDs = { _ in [Data("some-other-credential-id".utf8)] }
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())

        XCTAssertNotNil(presenter.passkeyCreator)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)
    }

    func test_afterUnlock_presentsCreatorWithRequestContext() throws {
        let (coordinator, presenter) = makeCoordinator()
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "target.kdbx"),
            nickname: "Personal Vault"
        )
        seedUnlockedVaultState(coordinator)
        coordinator.activeDatabaseReference = reference
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())

        let creator = try XCTUnwrap(presenter.passkeyCreator)
        XCTAssertEqual(creator.context.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(creator.context.userName, "alice@example.com")
        XCTAssertEqual(creator.context.databaseName, "Personal Vault")
        XCTAssertEqual(creator.context.initialTitle, "example.com")
    }

    func test_creatorCancel_cancelsUserCanceled() throws {
        let (coordinator, presenter) = makeCoordinator()
        seedUnlockedVaultState(coordinator)
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())
        let creator = try XCTUnwrap(presenter.passkeyCreator)

        creator.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    // MARK: - Save

    func test_save_happyPath_savesEntryThenCompletesRegistration() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "target.kdbx")
        )
        let sessionKey = SymmetricKey(size: .bits256)
        seedUnlockedVaultState(coordinator, sessionKey: sessionKey)
        coordinator.activeDatabaseReference = reference
        let recorder = Recorder()
        coordinator.passkeySaveEnvironment = makeRecordingEnvironment(recorder)
        presenter.onCompleteRegistrationRequest = { _ in
            recorder.events.append("completeRegistration")
        }
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())
        let creator = try XCTUnwrap(presenter.passkeyCreator)

        let outcome = await creator.onSave("My Passkey")

        guard case .completed = outcome else {
            return XCTFail("Expected the save to complete, got \(outcome)")
        }

        // Save-first ordering: the entry is persisted (and the identity store
        // repopulated) BEFORE the credential is handed to the system.
        XCTAssertEqual(recorder.events, ["saveDraft", "populate", "completeRegistration"])
        XCTAssertEqual(recorder.populatedEntryTitles, [["My Passkey"]])

        // The saved entry carries the KPEX passkey fields, with the secret
        // ones protected and the PEM diverted into the sealed private key.
        let entry = try XCTUnwrap(recorder.savedRootGroups.first?.allEntries.first)
        XCTAssertEqual(entry.title, "My Passkey")
        XCTAssertEqual(entry.username, "alice@example.com")
        XCTAssertEqual(entry.url, "https://example.com")
        XCTAssertEqual(entry.customFields[PasskeyCredential.relyingPartyKey], "example.com")
        XCTAssertEqual(entry.customFields[PasskeyCredential.usernameKey], "alice@example.com")
        XCTAssertEqual(
            entry.customFields[PasskeyCredential.userHandleKey],
            base64URLEncode(Data("user-handle".utf8))
        )
        let storedCredentialIDField = try XCTUnwrap(entry.customFields[PasskeyCredential.credentialIDKey])
        XCTAssertNil(
            entry.customFields[PasskeyCredential.privateKeyPEMKey],
            "The PEM must be diverted out of the stored custom fields"
        )
        XCTAssertNotNil(entry.passkeyPrivateKey)
        XCTAssertEqual(
            entry.protectedStringKeys,
            [
                PasskeyCredential.credentialIDKey,
                PasskeyCredential.privateKeyPEMKey,
                PasskeyCredential.userHandleKey,
            ]
        )

        // The entry round-trips as a usable passkey credential whose PEM
        // parses into a P-256 signing key.
        let storedPasskey = try XCTUnwrap(entry.passkeyCredential)
        let storedPrivateKey = try PasskeyCrypto.privateKey(
            fromPEM: storedPasskey.privateKeyPEM(using: sessionKey)
        )

        // The completed registration credential matches the stored entry.
        let credential = try XCTUnwrap(presenter.completedRegistration)
        XCTAssertEqual(credential.relyingParty, "example.com")
        XCTAssertEqual(credential.clientDataHash, Data(repeating: 7, count: 32))
        let storedCredentialID = try XCTUnwrap(base64URLDecode(storedCredentialIDField))
        XCTAssertEqual(storedCredentialID.count, 32)
        XCTAssertEqual(credential.credentialID, storedCredentialID)

        // The attestation object embeds authenticator data for the relying
        // party: rpIdHash, our credential ID, and the stored key's public
        // coordinates.
        let rpIdHash = Data(SHA256.hash(data: Data("example.com".utf8)))
        XCTAssertNotNil(credential.attestationObject.range(of: rpIdHash))
        XCTAssertNotNil(credential.attestationObject.range(of: storedCredentialID))
        let publicKeyX = Data(storedPrivateKey.publicKey.x963Representation.dropFirst(1).prefix(32))
        XCTAssertNotNil(credential.attestationObject.range(of: publicKeyX))

        assertCleanedUp(coordinator)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)
    }

    func test_save_conflict_returnsWarningAndCancelOutcome() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "target.kdbx")
        )
        seedUnlockedVaultState(coordinator)
        coordinator.activeDatabaseReference = reference
        let recorder = Recorder()
        coordinator.passkeySaveEnvironment = makeRecordingEnvironment(
            recorder,
            saveDraft: { [recorder] _, _, _, _ in
                recorder.events.append("saveDraft")
                return .conflict
            }
        )
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())
        let creator = try XCTUnwrap(presenter.passkeyCreator)

        let outcome = await creator.onSave("My Passkey")

        guard case .showWarningAndCancel(let message) = outcome else {
            return XCTFail("Expected the conflict warning, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(presenter.completedRegistration, "A conflicted save must not complete the registration")
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)

        // The creator's warning alert cancels on dismissal.
        creator.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    func test_save_error_returnsErrorOutcome_withoutCompleting() async throws {
        let (coordinator, presenter) = makeCoordinator()
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "target.kdbx")
        )
        seedUnlockedVaultState(coordinator)
        coordinator.activeDatabaseReference = reference
        let recorder = Recorder()
        coordinator.passkeySaveEnvironment = makeRecordingEnvironment(
            recorder,
            saveDraft: { _, _, _, _ in
                throw SaveError.databaseLocationUnavailable
            }
        )
        coordinator.pendingPasskeyRegistrationRequest = makeRegistrationRequest()

        XCTAssertTrue(coordinator.handlePendingPasskeyRegistrationIfNeeded())
        let creator = try XCTUnwrap(presenter.passkeyCreator)

        let outcome = await creator.onSave("My Passkey")

        guard case .showError = outcome else {
            return XCTFail("Expected the error outcome, got \(outcome)")
        }
        XCTAssertNil(presenter.completedRegistration)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty, "The user decides via the alert; nothing auto-cancels")

        // Dismissing the sheet afterwards cancels and cleans up.
        creator.onCancel()

        XCTAssertEqual(presenter.cancelledError?.code, .userCanceled)
        assertCleanedUp(coordinator)
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (CredentialProviderCoordinator, CredentialProviderPresentingSpy) {
        let presenter = CredentialProviderPresentingSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)
        return (coordinator, presenter)
    }

    private func makeRegistrationRequest(
        supportedAlgorithms: [ASCOSEAlgorithmIdentifier] = [.ES256],
        userName: String = "alice@example.com",
        userHandle: Data = Data("user-handle".utf8)
    ) -> ASPasskeyCredentialRequest {
        let identity = ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: "example.com",
            userName: userName,
            credentialID: Data(),
            userHandle: userHandle,
            recordIdentifier: nil
        )
        return ASPasskeyCredentialRequest(
            credentialIdentity: identity,
            clientDataHash: Data(repeating: 7, count: 32),
            userVerificationPreference: .preferred,
            supportedAlgorithms: supportedAlgorithms
        )
    }

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

    /// An existing passkey entry for relying party `example.com` whose
    /// credential ID is the base64url of "test-credential-id".
    private func makePasskeyEntry(
        privateKey: P256.Signing.PrivateKey,
        sessionKey: SymmetricKey
    ) throws -> KPEntry {
        KPEntry(
            title: "Existing Passkey",
            url: "https://example.com",
            customFields: [
                PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
                PasskeyCredential.relyingPartyKey: "example.com",
                PasskeyCredential.usernameKey: "alice@example.com",
                PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
            ],
            passkeyPrivateKey: try EncryptedValue.encrypt(privateKey.pemRepresentation, using: sessionKey)
        )
    }

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
        XCTAssertNil(coordinator.pendingPasskeyRegistrationRequest, "pending registration request must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingPasskeyRegistrationFailureMessage, "pending registration failure must be cleared", file: file, line: line)
        XCTAssertNil(coordinator.pendingReadOnlyCancellationMessage, "pending read-only message must be cleared", file: file, line: line)
        XCTAssertFalse(coordinator.pendingNoEnabledDatabasesPresentation, "pending empty state must be cleared", file: file, line: line)
    }

    private final class Recorder: @unchecked Sendable {
        var events: [String] = []
        var savedRootGroups: [KPGroup] = []
        var populatedEntryTitles: [[String]] = []
    }

    private func makeRecordingEnvironment(
        _ recorder: Recorder,
        saveDraft: (@Sendable (DatabaseDraft, DatabaseReference, Data, Data) async throws -> AutoFillSaveCoordinator.SaveResult)? = nil
    ) -> AutoFillSaveCoordinator.Environment {
        AutoFillSaveCoordinator.Environment(
            generatePassword: { "unused" },
            saveDraft: saveDraft ?? { [recorder] draft, _, _, _ in
                recorder.events.append("saveDraft")
                recorder.savedRootGroups.append(draft.rootGroup)
                return .saved(
                    AutoFillSaveCoordinator.SaveOutcome(
                        savedRootGroup: draft.rootGroup,
                        newSHA512: Data("new-sha".utf8),
                        enqueuedPendingUpload: false
                    )
                )
            },
            relativePathForURL: { _ in "unused" },
            enqueuePendingUpload: { marker in
                PendingUploadQueue.StoredMarker(
                    id: UUID(),
                    fileURL: URL(fileURLWithPath: "/tmp/unused.json"),
                    marker: marker
                )
            },
            finalizePendingUpload: { _ in },
            dropPendingUpload: { _ in },
            dropSupersededPendingUploads: { _, _, _ in },
            notifyPendingUploadEnqueued: {},
            resolveReference: { _ in nil },
            populateCredentialStore: { [recorder] _, entries in
                recorder.events.append("populate")
                recorder.populatedEntryTitles.append(entries.map(\.title))
            },
            now: { .now }
        )
    }
#endif
}
