import AuthenticationServices
import CryptoKit
import XCTest
import KDBXKit
@testable import KeeForge

@MainActor
final class CredentialProviderSaveTests: XCTestCase {
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
        XCTAssertEqual(draft.url, "https://accounts.example.com", "Only the site is saved, never the page path or query")
    }

    /// A fill resolves `{REF:…}` in an entry's URL and title, so the website
    /// or app must not be able to plant one there.
    func test_prepareDraft_fieldReferenceInPageURL_isNotSaved() {
        let serviceIdentifier = ASCredentialServiceIdentifier(
            identifier: "https://evil.example:8443/login?next={REF:P@T:Bank}#{REF:U@T:Bank}",
            type: .URL
        )

        let draft = AutoFillSaveCoordinator.initialDraft(for: serviceIdentifier, username: "alex", password: "secret")

        // Whether raw braces parse depends on the OS's URL parser.
        XCTAssertTrue(["https://evil.example:8443", ""].contains(draft.url), draft.url)
        XCTAssertFalse(FieldReferenceResolver.containsReference(draft.title), draft.title)
    }

    func test_prepareDraft_fieldReferenceInAppDisplayName_leavesTitleEmpty() throws {
        guard #available(iOS 26.2, macOS 26.2, *) else {
            throw XCTSkip("App service identifiers require iOS 26.2 / macOS 26.2")
        }
        let serviceIdentifier = ASCredentialServiceIdentifier(
            identifier: "A1B2C3D4E5.com.evil.app",
            type: .app,
            displayName: "{REF:P@T:Bank}"
        )

        let draft = AutoFillSaveCoordinator.initialDraft(for: serviceIdentifier, username: "", password: "secret")

        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.url, "")
    }

    func test_prepareDraft_appIdentifier_usesDisplayNameAndNoURL() throws {
        guard #available(iOS 26.2, macOS 26.2, *) else {
            throw XCTSkip("App service identifiers require iOS 26.2 / macOS 26.2")
        }
        let serviceIdentifier = ASCredentialServiceIdentifier(
            identifier: "A1B2C3D4E5.com.mybank.app",
            type: .app,
            displayName: "MyBank"
        )

        let draft = AutoFillSaveCoordinator.initialDraft(
            for: serviceIdentifier,
            username: "alex",
            password: "supplied-secret"
        )

        XCTAssertEqual(draft.title, "MyBank")
        XCTAssertEqual(draft.username, "alex")
        XCTAssertEqual(draft.password, "supplied-secret")
        XCTAssertEqual(draft.url, "")
    }

    func test_saveNewEntry_committedWarningPreservesInstalledResultWithoutPublishingIdentities() async throws {
        let recorder = SaveRecorder()
        let root = KPGroup(name: "Root", groups: [KPGroup(name: "Database")])
        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(title: "Committed", username: "user", password: "secret"),
            reference: makeLocalReference(), rootGroup: root, meta: KPMeta(), sessionKey: SymmetricKey(size: .bits256),
            compositeKey: SymmetricKey(size: .bits256), openTimeSHA512: Data("baseline".utf8),
            environment: makeEnvironment(recorder: recorder, saveDraft: { draft, _, _, _ in
                .committedWithoutConfirmedDurability(.init(savedRootGroup: draft.rootGroup,
                    newSHA512: Data("installed".utf8), enqueuedPendingUpload: false, warningScope: .sharedCopy))
            }))
        guard case .committedWithoutConfirmedDurability(let outcome) = result else { return XCTFail("Expected committed warning") }
        XCTAssertEqual(outcome.newSHA512, Data("installed".utf8))
        XCTAssertEqual(outcome.savedRootGroup.allEntries.map(\.title), ["Committed"])
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func test_saveNewEntry_localSource_createsDraftAndPublishesIdentitiesWithoutEnqueuing() async throws {
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
            compositeKey: SymmetricKey(data: Data("composite-key".utf8)),
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
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: reference.id).isEmpty)
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
                    openTimeSHA512: openTimeSHA512,
                    kdfPolicy: .autoFillExtension
                ) {
                case .saved(let newSHA512, _, _):
                    return .saved(
                        AutoFillSaveCoordinator.SaveOutcome(
                            savedRootGroup: draft.rootGroup,
                            newSHA512: newSHA512,
                            enqueuedPendingUpload: false
                        )
                    )
                case .committedWithoutConfirmedDurability(let sha, _, _, let scope):
                    return .committedWithoutConfirmedDurability(.init(savedRootGroup: draft.rootGroup,
                        newSHA512: sha, enqueuedPendingUpload: false, warningScope: scope))
                case .indeterminate(let scope): return .indeterminate(scope)
                case .conflict:
                    return .conflict
                }
            },
            populateCredentialStore: { _, _ in }
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
            openTimeSHA512: FileDigest.sha512(loaded.sourceData),
            environment: environment
        )

        guard case .saved = result else {
            return XCTFail("Expected Twofish AutoFill save to succeed")
        }
        let cachedData = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: cachedData,
            compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey,
            kdfPolicy: .autoFillExtension
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXOuterCipher.twofish256CBC.uuid)
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Twofish AutoFill Entry" })
    }

    func test_saveNewEntry_cloudSource_preparesImmutableJournalBeforeReplacementAndPublishesAfter() async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let recorder = SaveRecorder()
        let probe = CloudSaveProbe()
        let sourceData = loaded.sourceData
        var local = LocalDatabaseSaver.Environment.autoFillExtension
        let replace = local.replaceFileAtomically
        local.replaceFileAtomically = { data, url, sha, authorization in
            let prepared = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertEqual(prepared.marker.isPayloadFinalized, false)
            XCTAssertEqual(prepared.marker.openTimeSHA512, FileDigest.sha512(sourceData))
            XCTAssertEqual(prepared.marker.intendedPayloadSHA512, FileDigest.sha512(data))
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(prepared), data)
            XCTAssertEqual(try Data(contentsOf: url), sourceData)
            XCTAssertEqual(sha, FileDigest.sha512(sourceData))
            probe.record(prepared: prepared, ciphertext: data)
            return try replace(data, url, sha, authorization)
        }
        let outcome = try await saveCloudEntry(to: reference, loaded: loaded, source: loaded.sourceData,
            title: "Dropbox Entry", environment: makeLiveCloudEnvironment(local: local, recorder: recorder))
        guard case .saved(let saved) = outcome else { return XCTFail("Expected durable local save") }
        let installed = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        let finalized = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertTrue(saved.enqueuedPendingUpload)
        XCTAssertEqual(saved.newSHA512, FileDigest.sha512(installed))
        XCTAssertEqual(probe.snapshot.ciphertexts, [installed])
        XCTAssertEqual(probe.snapshot.prepared.map(\.id), [finalized.id])
        XCTAssertEqual(finalized.marker.openTimeSHA512, saved.newSHA512)
        XCTAssertEqual(finalized.marker.intendedPayloadSHA512, saved.newSHA512)
        XCTAssertEqual(finalized.marker.expectedRev, "rev-9")
        XCTAssertEqual(finalized.marker.baseRev, "rev-9")
        XCTAssertEqual(finalized.marker.isPayloadFinalized, true)
        XCTAssertFalse(finalized.marker.isConflicted)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(finalized), installed)
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }?.cloudSyncMetadata?.localHeadOperationID, finalized.id)
        XCTAssertEqual(DatabaseListStore.recentBackups(for: reference).compactMap { try? Data(contentsOf: $0) }, [loaded.sourceData])
        XCTAssertEqual(recorder.saveCalls.count, 1)
        XCTAssertEqual(recorder.saveCalls.first?.openTimeSHA512, FileDigest.sha512(sourceData))
        XCTAssertEqual(recorder.saveCalls.first?.compositeKey.withUnsafeBytes { Data($0) }, loaded.compositeKey.withUnsafeBytes { Data($0) })
        XCTAssertEqual(recorder.populatedEntryTitles.count, 1)
        XCTAssertTrue(recorder.populatedEntryTitles.first?.contains("Dropbox Entry") == true)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: installed, compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey, kdfPolicy: .autoFillExtension)
        XCTAssertTrue(parsed.rootGroup.allEntries.contains { $0.title == "Dropbox Entry" && $0.username == "cloud-user" })
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
    }

    func test_saveNewEntry_cloudSource_provenPreReplacementFailure_retiresOnlyItsOwnJournal() async throws {
        try await assertCloudPreReplacementFailure(withEarlierSave: false)
    }

    func test_saveNewEntry_cloudSource_provenPreReplacementFailure_keepsTheEarlierSavesMarker() async throws {
        try await assertCloudPreReplacementFailure(withEarlierSave: true)
    }

    func test_saveNewEntry_cloudSource_saved_preservesEarlierCiphertextAndLinksItsDescendant() async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let recorder = SaveRecorder()
        let environment = makeLiveCloudEnvironment(local: .autoFillExtension, recorder: recorder)
        guard case .saved = try await saveCloudEntry(to: reference, loaded: loaded, source: loaded.sourceData,
            title: "First Save", environment: environment) else { return XCTFail("Expected first save") }
        let earlier = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        let earlierBytes = try PendingUploadQueue.readImmutablePayload(earlier)
        guard case .saved(let saved) = try await saveCloudEntry(to: reference, loaded: loaded, source: earlierBytes,
            title: "Second Save", environment: environment) else { return XCTFail("Expected descendant save") }
        let markers = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.first { $0.id == earlier.id }?.marker, earlier.marker)
        let descendant = try XCTUnwrap(markers.first { $0.id != earlier.id })
        XCTAssertEqual(descendant.marker.predecessorOperationID, earlier.id)
        XCTAssertEqual(descendant.marker.predecessorSHA512, FileDigest.sha512(earlierBytes))
        XCTAssertEqual(descendant.marker.openTimeSHA512, saved.newSHA512)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(earlier), earlierBytes)
        let current = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(descendant), current)
        XCTAssertEqual(FileDigest.sha512(current), saved.newSHA512)
        XCTAssertTrue(saved.savedRootGroup.allEntries.contains { $0.title == "First Save" })
        XCTAssertTrue(saved.savedRootGroup.allEntries.contains { $0.title == "Second Save" })
        XCTAssertEqual(recorder.saveCalls.count, 2)
    }

    func test_saveNewEntry_cloudSource_finalizeLosingCASRace_reusesTheDurableJournal() async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let recorder = SaveRecorder()
        let probe = CloudSaveProbe()
        var local = LocalDatabaseSaver.Environment.autoFillExtension
        let replace = local.replaceFileAtomically
        local.replaceFileAtomically = { bytes, url, sha, authorization in
            let prepared = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            let raced = try PendingUploadQueue.markConflicted(prepared)
            XCTAssertGreaterThan(raced.marker.generation, prepared.marker.generation)
            probe.record(prepared: raced, ciphertext: bytes)
            return try replace(bytes, url, sha, authorization)
        }
        guard case .saved(let saved) = try await saveCloudEntry(to: reference, loaded: loaded, source: loaded.sourceData,
            title: "Raced", environment: makeLiveCloudEnvironment(local: local, recorder: recorder)) else { return XCTFail("Expected save") }
        let remaining = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(remaining.count, 1)
        let finalized = try XCTUnwrap(remaining.first)
        XCTAssertEqual(finalized.id, probe.snapshot.prepared.first?.id)
        XCTAssertGreaterThan(finalized.marker.generation, try XCTUnwrap(probe.snapshot.prepared.first?.marker.generation))
        XCTAssertFalse(finalized.marker.isConflicted)
        XCTAssertEqual(finalized.marker.isPayloadFinalized, true)
        XCTAssertEqual(finalized.marker.expectedRev, "rev-9")
        XCTAssertEqual(finalized.marker.baseRev, "rev-9")
        XCTAssertEqual(finalized.marker.openTimeSHA512, saved.newSHA512)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(finalized), try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)))
        XCTAssertEqual(probe.snapshot.ciphertexts.count, 1)
        XCTAssertEqual(recorder.saveCalls.count, 1)
    }

    func test_saveNewEntry_cloudSource_indeterminateReplacementKeepsEarlierAndNewSourcesForRecovery() async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let recorder = SaveRecorder()
        guard case .saved = try await saveCloudEntry(to: reference, loaded: loaded, source: loaded.sourceData,
            title: "First Save", environment: makeLiveCloudEnvironment(local: .autoFillExtension, recorder: recorder)) else { return XCTFail("Expected first save") }
        let earlier = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        let earlierBytes = try PendingUploadQueue.readImmutablePayload(earlier)
        recorder.populatedEntryTitles = []
        DatabaseListStore.activeAutoFillDatabaseID = nil
        var local = LocalDatabaseSaver.Environment.autoFillExtension
        let replace = local.replaceFileAtomically
        let probe = CloudSaveProbe()
        local.replaceFileAtomically = { bytes, url, sha, authorization in
            let outcome = try replace(bytes, url, sha, authorization)
            guard case .replaced = outcome else { return outcome }
            let prepared = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first { $0.id != earlier.id })
            probe.record(prepared: prepared, ciphertext: bytes)
            return .indeterminate
        }
        let result = try await saveCloudEntry(to: reference, loaded: loaded, source: earlierBytes, title: "Interrupted",
            environment: makeLiveCloudEnvironment(local: local, recorder: recorder))
        guard case .indeterminate(.sharedCopy) = result else { return XCTFail("An unknown replacement cannot publish success") }
        let intended = try XCTUnwrap(probe.snapshot.ciphertexts.first)
        let markers = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.first { $0.id == earlier.id }?.marker, earlier.marker)
        let prepared = try XCTUnwrap(markers.first { $0.id != earlier.id })
        XCTAssertEqual(prepared.marker.isPayloadFinalized, false)
        XCTAssertEqual(prepared.marker.predecessorOperationID, earlier.id)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(prepared), intended)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(earlier), earlierBytes)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), intended)
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
        try PendingUploadQueue.withCommitLock(for: reference.id) { try PendingUploadQueue.recoverLocalCommits(for: reference.id) }
        let recovered = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first { $0.id == prepared.id })
        XCTAssertEqual(recovered.marker.isPayloadFinalized, true)
        XCTAssertEqual(recovered.marker.openTimeSHA512, FileDigest.sha512(intended))
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }?.cloudSyncMetadata?.localHeadOperationID, prepared.id)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(recovered), intended)
        XCTAssertEqual(recorder.saveCalls.count, 2, "Recovery must not encrypt or save the draft again")
    }

    private func assertCloudPreReplacementFailure(withEarlierSave: Bool) async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let recorder = SaveRecorder()
        var base = loaded.sourceData
        var earlier: PendingUploadQueue.StoredMarker?
        if withEarlierSave {
            guard case .saved = try await saveCloudEntry(to: reference, loaded: loaded, source: base, title: "First Save",
                environment: makeLiveCloudEnvironment(local: .autoFillExtension, recorder: recorder)) else { return XCTFail("Expected first save") }
            earlier = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            base = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        }
        recorder.populatedEntryTitles = []
        DatabaseListStore.activeAutoFillDatabaseID = nil
        let probe = CloudSaveProbe()
        var local = LocalDatabaseSaver.Environment.autoFillExtension
        local.replaceFileAtomically = { bytes, _, _, _ in
            let prepared = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).last)
            probe.record(prepared: prepared, ciphertext: bytes)
            throw LocalSaveBeforeReplacementFailure(underlying: SaveError.databaseLocationUnavailable)
        }
        do {
            _ = try await saveCloudEntry(to: reference, loaded: loaded, source: base, title: "Failing",
                environment: makeLiveCloudEnvironment(local: local, recorder: recorder))
            XCTFail("Expected pre-replacement error")
        } catch {
            XCTAssertEqual((error as? LocalSaveBeforeReplacementFailure)?.underlying as? SaveError, .databaseLocationUnavailable)
        }
        XCTAssertEqual(probe.snapshot.ciphertexts.count, 1)
        let remaining = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(remaining.map(\.id), earlier.map { [$0.id] } ?? [])
        if let earlier {
            XCTAssertEqual(remaining.first?.marker, earlier.marker)
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(earlier), base)
        }
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), base)
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    private func registerCloud(_ loaded: KDBXCompatibilitySupport.LoadedFixture) throws -> DatabaseReference {
        let reference = makeCloudReference(rev: "rev-9")
        DatabaseListStore.update(reference)
        try DatabaseListStore.cacheDatabaseCopy(loaded.sourceData, for: reference)
        return reference
    }

    private func saveCloudEntry(to reference: DatabaseReference, loaded: KDBXCompatibilitySupport.LoadedFixture,
        source: Data, title: String, environment: AutoFillSaveCoordinator.Environment) async throws -> AutoFillSaveCoordinator.SaveResult {
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: source, compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey, kdfPolicy: .autoFillExtension)
        return try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(title: title, username: "cloud-user", password: "secret", url: "https://example.com"),
            reference: reference, rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: loaded.sessionKey,
            compositeKey: loaded.compositeKey, openTimeSHA512: FileDigest.sha512(source), environment: environment)
    }

    private func makeLiveCloudEnvironment(local: LocalDatabaseSaver.Environment, recorder: SaveRecorder) -> AutoFillSaveCoordinator.Environment {
        var environment = AutoFillSaveCoordinator.Environment.live
        environment.populateCredentialStore = { databaseID, entries in
            recorder.populatedDatabaseIDs.append(databaseID)
            recorder.populatedEntryTitles.append(entries.map(\.title).sorted())
        }
        environment.saveDraft = { draft, reference, key, sha in
            recorder.saveCalls.append(.init(referenceID: reference.id, compositeKey: key,
                openTimeSHA512: sha, entryTitles: draft.rootGroup.allEntries.map(\.title)))
            switch try await LocalDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: sha, kdfPolicy: .autoFillExtension, environment: local) {
            case .saved(let newSHA, _, _):
                return .saved(.init(savedRootGroup: draft.rootGroup, newSHA512: newSHA, enqueuedPendingUpload: true))
            case .committedWithoutConfirmedDurability(let newSHA, _, _, let scope):
                return .committedWithoutConfirmedDurability(.init(savedRootGroup: draft.rootGroup,
                    newSHA512: newSHA, enqueuedPendingUpload: true, warningScope: scope))
            case .indeterminate(let scope): return .indeterminate(scope)
            case .conflict: return .conflict
            }
        }
        return environment
    }

    private final class CloudSaveProbe: @unchecked Sendable {
        struct Snapshot {
            var prepared: [PendingUploadQueue.StoredMarker] = []
            var ciphertexts: [Data] = []
        }
        private let lock = NSLock()
        private var storage = Snapshot()
        var snapshot: Snapshot { lock.withLock { storage } }
        func record(prepared: PendingUploadQueue.StoredMarker, ciphertext: Data) {
            lock.withLock { storage.prepared.append(prepared); storage.ciphertexts.append(ciphertext) }
        }
    }

    func test_activeAutoFillDatabase_retainsLocalReadOnlyFlag() {
        let reference = makeLocalReference(isReadOnly: true)
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id

        let active = DatabaseListStore.activeAutoFillDatabase
        XCTAssertNotNil(active)
        XCTAssertTrue(active?.isReadOnly == true)
    }

    func test_activeAutoFillDatabase_retainsCloudReadOnlyFlag() {
        let reference = makeCloudReference(rev: "rev-1", isReadOnly: true)
        DatabaseListStore.update(reference)
        DatabaseListStore.activeAutoFillDatabaseID = reference.id

        let active = DatabaseListStore.activeAutoFillDatabase
        XCTAssertNotNil(active)
        XCTAssertTrue(active?.isReadOnly == true)
    }

    func test_saveNewEntry_conflict_keepsConcurrentCacheAndDoesNotPublishIdentities() async throws {
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: Bundle(for: Self.self))
        let reference = try registerCloud(loaded)
        let concurrent = Data("concurrent-ciphertext".utf8)
        try concurrent.write(to: DatabaseListStore.cacheLocation(for: reference), options: .atomic)
        let recorder = SaveRecorder()
        let result = try await saveCloudEntry(to: reference, loaded: loaded, source: loaded.sourceData, title: "Conflict",
            environment: makeLiveCloudEnvironment(local: .autoFillExtension, recorder: recorder))
        guard case .conflict = result else { return XCTFail("Expected optimistic concurrency conflict") }
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), concurrent)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
        XCTAssertTrue(recorder.populatedEntryTitles.isEmpty)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
        XCTAssertEqual(recorder.saveCalls.count, 1)
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
            compositeKey: SymmetricKey(data: Data("composite-key".utf8)),
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

    // MARK: - Destination group

    func test_destinationGroup_unconfigured_isTheTopLevelGroup() {
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [KPGroup(name: "General")])
        let root = KPGroup(name: "Root", groups: [topLevelGroup])

        let destination = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: nil)

        XCTAssertEqual(destination.id, topLevelGroup.id)
    }

    func test_destinationGroup_configuredNestedGroup_isUsed() {
        let nested = KPGroup(name: "Signups")
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [KPGroup(name: "General"), KPGroup(name: "Web", groups: [nested])])
        let root = KPGroup(name: "Root", groups: [topLevelGroup])

        let destination = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: nested.id)

        XCTAssertEqual(destination.id, nested.id)
    }

    func test_destinationGroup_deletedGroup_fallsBackToTheTopLevelGroup() {
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [KPGroup(name: "General")])
        let root = KPGroup(name: "Root", groups: [topLevelGroup])

        let destination = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: UUID())

        XCTAssertEqual(destination.id, topLevelGroup.id)
    }

    func test_destinationGroup_recycleBinOrGroupInsideIt_fallsBackToTheTopLevelGroup() {
        let recycled = KPGroup(name: "Signups")
        let recycleBin = KPGroup(name: "Recycle Bin", groups: [recycled])
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [recycleBin])
        let root = KPGroup(name: "Root", groups: [topLevelGroup], recycleBinUUID: recycleBin.id)

        XCTAssertEqual(
            AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: recycled.id).id,
            topLevelGroup.id
        )
        XCTAssertEqual(
            AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: recycleBin.id).id,
            topLevelGroup.id
        )
    }

    func test_destinationGroup_neverTheSyntheticRoot() {
        let topLevelGroup = KPGroup(name: "MyDatabase")
        let root = KPGroup(name: "Root", groups: [topLevelGroup])

        let destination = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: root.id)

        XCTAssertEqual(destination.id, topLevelGroup.id)
    }

    func test_saveNewEntry_configuredDestination_createsTheEntryInThatGroup() async throws {
        let autoFillGroup = KPGroup(name: "AutoFill")
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [KPGroup(name: "General"), autoFillGroup])
        let root = KPGroup(name: "Root", groups: [topLevelGroup])
        var reference = makeLocalReference()
        reference.autoFillDestinationGroupID = autoFillGroup.id

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
            sessionKey: SymmetricKey(size: .bits256),
            compositeKey: SymmetricKey(data: Data("composite-key".utf8)),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(recorder: SaveRecorder())
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected save to succeed")
        }
        let savedTopLevelGroup = try XCTUnwrap(outcome.savedRootGroup.groups.first)
        let savedAutoFillGroup = try XCTUnwrap(savedTopLevelGroup.groups.first(where: { $0.id == autoFillGroup.id }))
        XCTAssertEqual(savedAutoFillGroup.entries.map(\.title), ["Example"])
        XCTAssertTrue(savedTopLevelGroup.entries.isEmpty)
        XCTAssertEqual(outcome.savedRootGroup.allEntries.count, 1)
    }

    func test_saveNewEntry_destinationMovedToRecycleBin_savesToTheTopLevelGroup() async throws {
        let recycled = KPGroup(name: "AutoFill")
        let recycleBin = KPGroup(name: "Recycle Bin", groups: [recycled])
        let topLevelGroup = KPGroup(name: "MyDatabase", groups: [recycleBin])
        let root = KPGroup(name: "Root", groups: [topLevelGroup], recycleBinUUID: recycleBin.id)
        var reference = makeLocalReference()
        reference.autoFillDestinationGroupID = recycled.id

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
            sessionKey: SymmetricKey(size: .bits256),
            compositeKey: SymmetricKey(data: Data("composite-key".utf8)),
            openTimeSHA512: Data("open-sha".utf8),
            environment: makeEnvironment(recorder: SaveRecorder())
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected save to succeed")
        }
        XCTAssertEqual(outcome.savedRootGroup.groups.first?.entries.map(\.title), ["Example"])
        XCTAssertEqual(outcome.savedRootGroup.allEntries.count, 1)
    }

    // MARK: - Save-prepare default database selection (slice 03)

    // `ASSavePasswordRequest` is unavailable on macOS, not merely gated by an
    // availability version, so `@available(iOS 26.2, *)` alone does not keep
    // these out of the `KeeForgeMacTests` build.
#if os(iOS)
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

        let presenter = CredentialProviderPresentingSpy()
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

        let presenter = CredentialProviderPresentingSpy()
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

    func test_prepareSaveRequest_readOnlyLocalAndCloudDatabases_showNoticeBeforeCancelling() throws {
        guard #available(iOS 26.2, *) else {
            throw XCTSkip("ASSavePasswordRequest requires iOS 26.2")
        }

        for reference in [makeLocalReference(isReadOnly: true), makeCloudReference(rev: "rev-1", isReadOnly: true)] {
            DatabaseListStore.update(reference)
            DatabaseListStore.activeAutoFillDatabaseID = reference.id
            let presenter = CredentialProviderPresentingSpy()
            presenter.isPresentationActive = false
            let coordinator = CredentialProviderCoordinator(presenter: presenter)

            coordinator.prepareInterface(for: makeSavePasswordRequest())

            XCTAssertNotNil(coordinator.pendingReadOnlyCancellationMessage)
            XCTAssertFalse(coordinator.pendingUnlock)
            XCTAssertNil(coordinator.pendingSavePasswordRequestStorage)
            XCTAssertTrue(presenter.cancelledErrorCodes.isEmpty)

            presenter.isPresentationActive = true
            coordinator.presentationDidBecomeActive()
            let notice = try XCTUnwrap(presenter.readOnlyNotice)
            XCTAssertEqual(notice.message, String(localized: "This database is read-only. Open KeeForge to enable editing."))
            notice.onAcknowledge()

            XCTAssertEqual(presenter.cancelledErrorCodes, [.userCanceled])
            XCTAssertFalse(presenter.didCompleteSavePassword)
            XCTAssertNil(coordinator.pendingReadOnlyCancellationMessage)
        }
    }

    /// A website must not store a `{REF:…}`: the next fill on that site would
    /// resolve it and hand over another entry's secrets.
    func test_saveRequest_fieldReferenceFromTheWebsite_isRefusedWithoutSaving() async throws {
        guard #available(iOS 26.2, *) else {
            throw XCTSkip("ASSavePasswordRequest requires iOS 26.2")
        }

        for (user, password) in [("alex", "{REF:P@T:Bank}"), ("{ref:U@I:0123456789ABCDEF0123456789ABCDEF}", "secret")] {
            let reference = makeLocalReference()
            DatabaseListStore.update(reference)
            DatabaseListStore.activeAutoFillDatabaseID = reference.id
            let presenter = CredentialProviderPresentingSpy()
            let coordinator = CredentialProviderCoordinator(presenter: presenter)
            coordinator.prepareInterface(for: makeSavePasswordRequest(user: user, password: password))
            coordinator.parsedRootGroup = KPGroup(name: "Root", groups: [KPGroup(name: "MyDatabase")])
            coordinator.parsedMeta = KPMeta()
            coordinator.parsedFormatVersion = .kdbx4(minor: 0)
            coordinator.sessionKey = SymmetricKey(size: .bits256)
            coordinator.compositeKey = SymmetricKey(data: Data("composite-key".utf8))
            coordinator.openTimeSHA512 = Data("open-sha".utf8)

            XCTAssertTrue(coordinator.handlePendingSaveRequestIfNeeded())
            let creator = try XCTUnwrap(presenter.entryCreator)
            let outcome = await creator.onSave(creator.initialDraft)

            guard case .showError(let message) = outcome else {
                return XCTFail("Expected the save to be refused, got \(outcome)")
            }
            XCTAssertEqual(message, String(localized: "KeeForge can't save this login because it contains a field reference ({REF:…})."))
            XCTAssertFalse(presenter.didCompleteSavePassword)
            XCTAssertEqual(coordinator.openTimeSHA512, Data("open-sha".utf8), "Nothing may be written")
        }
    }

    @available(iOS 26.2, *)
    private func makeSavePasswordRequest(user: String = "alex", password: String = "secret") -> ASSavePasswordRequest {
        ASSavePasswordRequest(
            serviceIdentifier: ASCredentialServiceIdentifier(
                identifier: "https://accounts.example.com/sign-in",
                type: .URL
            ),
            credential: ASPasswordCredential(user: user, password: password),
            sessionID: "session-1",
            event: .userInitiated
        )
    }
#endif

    private func makeEnvironment(
        recorder: SaveRecorder,
        saveDraft: (@Sendable (DatabaseDraft, DatabaseReference, SymmetricKey, Data) async throws -> AutoFillSaveCoordinator.SaveResult)? = nil
    ) -> AutoFillSaveCoordinator.Environment {
        AutoFillSaveCoordinator.Environment(
            generatePassword: {
                "generated-password"
            },
            saveDraft: saveDraft ?? { draft, reference, compositeKey, openTimeSHA512 in
                recorder.events.append("saveDraft")
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
            populateCredentialStore: { databaseID, entries in
                recorder.populatedDatabaseIDs.append(databaseID)
                recorder.populatedEntryTitles.append(entries.map(\.title).sorted())
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
                    lastSyncIssue: nil
                )
            )
        )
    }

    private final class SaveRecorder: @unchecked Sendable {
        struct SaveCall: Sendable {
            let referenceID: UUID
            let compositeKey: SymmetricKey
            let openTimeSHA512: Data
            let entryTitles: [String]
        }

        var events: [String] = []
        var saveCalls: [SaveCall] = []
        var populatedEntryTitles: [[String]] = []
        var populatedDatabaseIDs: [UUID] = []
    }
}
