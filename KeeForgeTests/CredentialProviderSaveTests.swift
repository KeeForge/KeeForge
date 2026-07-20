import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CredentialProviderSaveTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        resetCredentialIdentityStoreSeams()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        resetCredentialIdentityStoreSeams()
        try await super.tearDown()
    }

    private func resetCredentialIdentityStoreSeams() {
        CredentialIdentityStoreManager.populateObserver = nil
        CredentialIdentityStoreManager.clearObserver = nil
        CredentialIdentityStoreManager.removeDatabaseObserver = nil
        CredentialIdentityStoreManager.removeIdentityObserver = nil
        CredentialIdentityStoreManager.storeProviderOverride = nil
    }

    func test_prepareDraft_usesPrefilledTitleUsernameAndProvidedPassword() {
        let serviceIdentifier = ASCredentialServiceIdentifier(
            identifier: "https://accounts.example.com/sign-in",
            type: .URL
        )

        let draft = AutoFillSaveCoordinator.initialDraft(
            for: serviceIdentifier,
            username: "alex",
            password: " supplied-secret "
        )

        XCTAssertEqual(draft.title, "accounts.example.com")
        XCTAssertEqual(draft.username, "alex")
        XCTAssertEqual(draft.password, " supplied-secret ")
        XCTAssertEqual(draft.url, "https://accounts.example.com/sign-in")
    }

    func test_saveNewEntry_localSource_writesCacheAndCallsCompleteRequest_doesNotEnqueue() async throws {
        let reference = makeLocalReference()
        let sessionKey = SymmetricKey(size: .bits256)
        let visibleRoot = KPGroup(name: "MyDatabase")
        let root = KPGroup(name: "Root", groups: [visibleRoot])
        let recorder = SaveRecorder()

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(
                title: "Example",
                username: "alex",
                password: "secret",
                url: "https://example.com"
            ),
            reference: reference,
            rootGroup: root,
            meta: KPMeta(),
            sessionKey: sessionKey,
            compositeKey: Data("composite-key".utf8),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(recorder: recorder)
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected save to succeed")
        }

        XCTAssertFalse(outcome.enqueuedPendingUpload)
        XCTAssertEqual(outcome.savedRootGroup.allEntries.count, 1)
        XCTAssertEqual(outcome.savedRootGroup.allEntries.first?.title, "Example")
        XCTAssertEqual(outcome.savedRootGroup.allEntries.first?.username, "alex")
        XCTAssertTrue(outcome.savedRootGroup.entries.isEmpty, "Entry should not be on the synthetic root")
        XCTAssertEqual(outcome.savedRootGroup.groups.first?.entries.count, 1, "Entry should be in the visible root group")
        XCTAssertEqual(recorder.saveCalls.count, 1)
        XCTAssertTrue(recorder.enqueuedMarkers.isEmpty)
        XCTAssertEqual(recorder.populatedEntryTitles, [["Example"]])
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
    }

    func test_saveNewEntry_twofishLocalSource_preservesCipherInCachedBytes() async throws {
        let loaded = try KDBXCompatibilitySupport.load(
            .syntheticTwofish,
            bundle: Bundle(for: Self.self)
        )
        let reference = makeLocalReference()
        try DatabaseListStore.cacheDatabaseCopy(loaded.sourceData, for: reference)
        let environment = AutoFillSaveCoordinator.Environment(
            generatePassword: { "generated-password" },
            saveDraft: { draft, reference, compositeKey, openTimeSHA512 in
                switch try await LocalDatabaseSaver.save(
                    draft: draft,
                    reference: reference,
                    compositeKey: compositeKey,
                    openTimeSHA512: openTimeSHA512
                ) {
                case .saved(let newSHA512):
                    return .saved(
                        AutoFillSaveCoordinator.SaveOutcome(
                            savedRootGroup: draft.rootGroup,
                            newSHA512: newSHA512,
                            enqueuedPendingUpload: false
                        )
                    )
                case .conflict:
                    return .conflict
                }
            },
            relativePathForURL: { _ in "unused" },
            enqueuePendingUpload: { _ in },
            populateCredentialStore: { _, _ in },
            now: { .now }
        )

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(
                title: "Twofish AutoFill Entry",
                username: "autofill-user",
                password: "autofill-secret",
                url: "https://twofish.example.com"
            ),
            reference: reference,
            rootGroup: loaded.rootGroup,
            meta: loaded.meta,
            sessionKey: loaded.sessionKey,
            compositeKey: loaded.compositeKey,
            openTimeSHA512: KDBXCrypto.sha512(loaded.sourceData),
            environment: environment
        )

        guard case .saved = result else {
            return XCTFail("Expected Twofish AutoFill save to succeed")
        }
        let cachedData = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: cachedData,
            compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Twofish AutoFill Entry" })
    }

    func test_saveNewEntry_cloudSource_writesCacheAndEnqueuesMarker_thenCallsCompleteRequest() async throws {
        let reference = makeCloudReference(rev: "rev-9")
        let sessionKey = SymmetricKey(size: .bits256)
        let recorder = SaveRecorder()
        let expectedCacheURL = DatabaseListStore.cacheLocation(for: reference)

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(
                title: "Dropbox Entry",
                username: "cloud-user",
                password: "secret",
                url: "https://dropbox.example.com"
            ),
            reference: reference,
            rootGroup: KPGroup(name: "Root", groups: [KPGroup(name: "MyDatabase")]),
            meta: KPMeta(),
            sessionKey: sessionKey,
            compositeKey: Data("composite-key".utf8),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(
                recorder: recorder,
                relativePathForURL: { url in
                    recorder.relativePathInputs.append(url)
                    return "cloud-cache/\(reference.id.uuidString).kdbx"
                }
            )
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected save to succeed")
        }

        XCTAssertTrue(outcome.enqueuedPendingUpload)
        XCTAssertEqual(recorder.relativePathInputs, [expectedCacheURL])
        XCTAssertEqual(recorder.enqueuedMarkers.count, 1)
        XCTAssertEqual(recorder.enqueuedMarkers.first?.databaseId, reference.id)
        XCTAssertEqual(recorder.enqueuedMarkers.first?.encryptedBytesCacheURL, "cloud-cache/\(reference.id.uuidString).kdbx")
        XCTAssertEqual(recorder.enqueuedMarkers.first?.expectedRev, "rev-9")
        XCTAssertEqual(recorder.enqueuedMarkers.first?.openTimeSHA512, Data("new-sha".utf8))
        XCTAssertNil(recorder.enqueuedMarkers.first?.lastSyncError)
        XCTAssertEqual(recorder.populatedEntryTitles, [["Dropbox Entry"]])
    }

    func test_activeAutoFillDatabase_readOnly_blocksCreation() {
        let reference = makeLocalReference(isReadOnly: true)
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id

        let active = DatabaseListStore.activeAutoFillDatabase
        XCTAssertNotNil(active)
        XCTAssertTrue(active?.isReadOnly == true)
    }

    func test_activeAutoFillDatabase_readOnlyCloud_blocksCreation() {
        let reference = makeCloudReference(rev: "rev-1", isReadOnly: true)
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id

        let active = DatabaseListStore.activeAutoFillDatabase
        XCTAssertNotNil(active)
        XCTAssertTrue(active?.isReadOnly == true)
    }

    func test_saveNewEntry_conflict_doesNotEnqueueOrPopulate() async throws {
        let reference = makeCloudReference(rev: "rev-2")
        let sessionKey = SymmetricKey(size: .bits256)
        let recorder = SaveRecorder()

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(
                title: "Conflict",
                username: "alex",
                password: "secret",
                url: "https://example.com"
            ),
            reference: reference,
            rootGroup: KPGroup(name: "Root", groups: [KPGroup(name: "MyDatabase")]),
            meta: KPMeta(),
            sessionKey: sessionKey,
            compositeKey: Data("composite-key".utf8),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(
                recorder: recorder,
                saveDraft: { _, _, _, _ in
                    .conflict
                }
            )
        )

        guard case .conflict = result else {
            return XCTFail("Expected save conflict")
        }

        XCTAssertTrue(recorder.enqueuedMarkers.isEmpty)
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func test_saveNewEntry_autoFillDisabledReference_doesNotSetActiveOrPopulate() async throws {
        let reference = makeLocalReference(autoFillEnabled: false)
        let sessionKey = SymmetricKey(size: .bits256)
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "MyDatabase")])
        let recorder = SaveRecorder()

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(
                title: "Disabled Entry",
                username: "alex",
                password: "secret",
                url: "https://example.com"
            ),
            reference: reference,
            rootGroup: root,
            meta: KPMeta(),
            sessionKey: sessionKey,
            compositeKey: Data("composite-key".utf8),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(recorder: recorder)
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected save to succeed even with AutoFill disabled")
        }

        XCTAssertEqual(outcome.savedRootGroup.allEntries.count, 1)
        XCTAssertEqual(outcome.savedRootGroup.allEntries.first?.title, "Disabled Entry")
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertTrue(recorder.populatedDatabaseIDs.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    // MARK: - Save-prepare default database selection (slice 03)

    func test_defaultDatabaseSelectionForSave_prepareInterfacePinsEnabledDatabaseOverDisabledOpenedLater() throws {
        guard #available(iOS 26.2, *) else {
            throw XCTSkip("ASSavePasswordRequest requires iOS 26.2")
        }

        let enabled = makeLocalReference()
        let disabled = makeLocalReference(autoFillEnabled: false)
        DatabaseListStore.update(enabled)
        DatabaseListStore.update(disabled)
        DatabaseListStore.markDatabaseOpened(id: enabled.id, at: Date(timeIntervalSince1970: 1_000))
        DatabaseListStore.markDatabaseOpened(id: disabled.id, at: Date(timeIntervalSince1970: 2_000))
        // Clear the pointer `markDatabaseOpened` just set so the resolution
        // exercises the most-recently-opened-enabled fallback, proving the
        // disabled-but-opened-later database is skipped rather than merely
        // outranked by the pointer.
        DatabaseListStore.activeAutoFillDatabaseID = nil

        let presenter = SavePresenterSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)

        coordinator.prepareInterface(for: makeSavePasswordRequest())

        XCTAssertEqual(coordinator.activeDatabaseReference?.id, enabled.id)
        XCTAssertTrue(coordinator.pendingUnlock)
        XCTAssertFalse(coordinator.pendingNoEnabledDatabasesPresentation)
        XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)
    }

    func test_defaultDatabaseSelectionForSave_zeroEnabledDatabases_defersEmptyStateWithoutCancelling() throws {
        guard #available(iOS 26.2, *) else {
            throw XCTSkip("ASSavePasswordRequest requires iOS 26.2")
        }

        let disabled = makeLocalReference(autoFillEnabled: false)
        DatabaseListStore.update(disabled)
        DatabaseListStore.markDatabaseOpened(id: disabled.id, at: Date(timeIntervalSince1970: 1_000))

        let presenter = SavePresenterSpy()
        let coordinator = CredentialProviderCoordinator(presenter: presenter)

        coordinator.prepareInterface(for: makeSavePasswordRequest())

        XCTAssertFalse(coordinator.pendingUnlock)
        XCTAssertTrue(coordinator.pendingNoEnabledDatabasesPresentation)
        XCTAssertNil(coordinator.activeDatabaseReference)
        XCTAssertTrue(
            presenter.cancelledErrorCodes.isEmpty,
            "Zero enabled databases must defer the empty state, not cancel with .failed"
        )
    }

    @available(iOS 26.2, *)
    private func makeSavePasswordRequest() -> ASSavePasswordRequest {
        ASSavePasswordRequest(
            serviceIdentifier: ASCredentialServiceIdentifier(
                identifier: "https://accounts.example.com/sign-in",
                type: .URL
            ),
            credential: ASPasswordCredential(user: "alex", password: "secret"),
            sessionID: "session-1",
            event: .userInitiated
        )
    }

    private func makeEnvironment(
        recorder: SaveRecorder,
        saveDraft: (@Sendable (DatabaseDraft, DatabaseReference, Data, Data) async throws -> AutoFillSaveCoordinator.SaveResult)? = nil,
        relativePathForURL: (@Sendable (URL) throws -> String)? = nil
    ) -> AutoFillSaveCoordinator.Environment {
        AutoFillSaveCoordinator.Environment(
            generatePassword: {
                "generated-password"
            },
            saveDraft: saveDraft ?? { draft, reference, compositeKey, openTimeSHA512 in
                recorder.saveCalls.append(
                    SaveRecorder.SaveCall(
                        referenceID: reference.id,
                        compositeKey: compositeKey,
                        openTimeSHA512: openTimeSHA512,
                        entryTitles: draft.rootGroup.allEntries.map(\.title)
                    )
                )
                return .saved(
                    AutoFillSaveCoordinator.SaveOutcome(
                        savedRootGroup: draft.rootGroup,
                        newSHA512: Data("new-sha".utf8),
                        enqueuedPendingUpload: false
                    )
                )
            },
            relativePathForURL: relativePathForURL ?? { _ in
                "cloud-cache/db.kdbx"
            },
            enqueuePendingUpload: { marker in
                recorder.enqueuedMarkers.append(marker)
            },
            populateCredentialStore: { databaseID, entries in
                recorder.populatedDatabaseIDs.append(databaseID)
                recorder.populatedEntryTitles.append(entries.map(\.title).sorted())
            },
            now: {
                Date(timeIntervalSince1970: 2_000)
            }
        )
    }

    private func makeLocalReference(
        id: UUID = UUID(),
        isReadOnly: Bool = false,
        autoFillEnabled: Bool = true
    ) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "local.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: isReadOnly,
            autoFillEnabled: autoFillEnabled
        )
    }

    private func makeCloudReference(
        id: UUID = UUID(),
        rev: String?,
        isReadOnly: Bool = false,
        autoFillEnabled: Bool = true
    ) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "cloud.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: isReadOnly,
            autoFillEnabled: autoFillEnabled,
            editsAcknowledgedAt: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/cloud.kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: rev,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }

    private final class SaveRecorder: @unchecked Sendable {
        struct SaveCall: Sendable {
            let referenceID: UUID
            let compositeKey: Data
            let openTimeSHA512: Data
            let entryTitles: [String]
        }

        var saveCalls: [SaveCall] = []
        var enqueuedMarkers: [PendingUploadQueue.Marker] = []
        var populatedEntryTitles: [[String]] = []
        var populatedDatabaseIDs: [UUID] = []
        var relativePathInputs: [URL] = []
    }

    /// Minimal `CredentialProviderPresenting` conformance for the save-prepare
    /// tests: `prepareInterface(for: ASSavePasswordRequest)` only mutates
    /// coordinator state, so the spy just records that no request cancellation
    /// (the pre-slice-03 `.failed` behavior) sneaks back in.
    @MainActor
    private final class SavePresenterSpy: CredentialProviderPresenting {
        var isDisplayingContent = false
        private(set) var cancelledErrorCodes: [ASExtensionError.Code] = []

        func presentSearchView(
            entries: [KPEntry],
            initialSearchText: String,
            databaseSwitcher: CredentialProviderDatabaseSwitcherContext?,
            onSelect: @escaping (KPEntry) -> Void,
            onCancel: @escaping () -> Void
        ) {}

        func presentEntryCreator(
            initialDraft: EntryDraftPayload,
            onSave: @escaping @Sendable (EntryDraftPayload) async -> CredentialProviderEntrySaveOutcome,
            onCancel: @escaping () -> Void
        ) {}

        func presentNoEnabledDatabasesState(onDismiss: @escaping () -> Void) {}

        func presentUnlockPrompt(
            biometricOptionTitle: String?,
            onSubmitPassword: @escaping (String?) -> Void,
            onChooseBiometrics: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {}

        func presentUnlockError(
            message: String,
            onRetry: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {}

        func presentReadOnlyNotice(
            message: String,
            onAcknowledge: @escaping () -> Void
        ) {}

        func presentGeneratedPassword(
            _ password: String,
            onUse: @escaping () -> Void,
            onRegenerate: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {}

        func completeRequest(withSelectedCredential credential: ASPasswordCredential) {}
        func completeAssertionRequest(using credential: ASPasskeyAssertionCredential) {}
        func completeOneTimeCodeRequest(code: String) {}
        func completeSavePasswordRequest() {}
        func completeGeneratePasswordRequest(passwords: [String]) {}

        func cancelRequest(withError error: ASExtensionError) {
            cancelledErrorCodes.append(error.code)
        }
    }
}
