import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class CredentialProviderSaveTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CredentialIdentityStoreManager.populateObserver = nil
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CredentialIdentityStoreManager.populateObserver = nil
        try await super.tearDown()
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
        let root = KPGroup(name: "Root")
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
        XCTAssertEqual(recorder.saveCalls.count, 1)
        XCTAssertTrue(recorder.enqueuedMarkers.isEmpty)
        XCTAssertEqual(recorder.populatedEntryTitles, [["Example"]])
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
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
            rootGroup: KPGroup(name: "Root"),
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
        XCTAssertEqual(recorder.enqueuedMarkers.first?.openTimeSHA512, Data("open-sha".utf8))
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
            rootGroup: KPGroup(name: "Root"),
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
            populateCredentialStore: { entries in
                recorder.populatedEntryTitles.append(entries.map(\.title).sorted())
            },
            now: {
                Date(timeIntervalSince1970: 2_000)
            }
        )
    }

    private func makeLocalReference(id: UUID = UUID(), isReadOnly: Bool = false) -> DatabaseReference {
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
            isReadOnly: isReadOnly
        )
    }

    private func makeCloudReference(id: UUID = UUID(), rev: String?, isReadOnly: Bool = false) -> DatabaseReference {
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
        var relativePathInputs: [URL] = []
    }
}
