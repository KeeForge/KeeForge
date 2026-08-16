import CryptoKit
import XCTest
@testable import KeeForge

final class LocalDatabaseSaverTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        super.tearDown()
    }

    func testSaveWritesValidKDBXThatReParsesEqualToDraft() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Slice 04 Added Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let reparsed = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: databaseURL),
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )

        let savedTitles = reparsed.rootGroup.allEntries.map(\.title)
        let originalTitles = context.originalRootGroup.allEntries.map(\.title)

        XCTAssertTrue(savedTitles.contains("Slice 04 Added Entry"))
        XCTAssertEqual(savedTitles.count, originalTitles.count + 1)
        for title in originalTitles {
            XCTAssertTrue(savedTitles.contains(title))
        }
    }

    func testSaveTwofishDatabasePreservesCipherAndRefreshesCache() async throws {
        let databaseURL = try makeScratchTwofishDatabase()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Twofish Saved Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let savedData = try Data(contentsOf: databaseURL)
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: savedData,
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Twofish Saved Entry" })

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        XCTAssertEqual(try Data(contentsOf: cachedURL), savedData)
    }

    func testSaveTakesBackupOfPreviousBytesIntoBackupDirectory() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Backup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let backups = DatabaseListStore.recentBackups(for: reference)
        let backupURL = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
    }

    func testBackupTakenBySaveReopensWithOriginalCredentialsAtPreEditContent() async throws {
        // A backup that is merely present is worthless; this proves the bytes
        // written aside are a decryptable KDBX file that still holds the
        // pre-edit entry state, i.e. that a restore would actually recover it.
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let target = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "Twitter" })
        XCTAssertEqual(try target.password.decrypt(using: sessionKey), "twitterpass123")
        let originalTitles = parsed.rootGroup.allEntries.map(\.title).sorted()
        let originalHistoryCount = target.history.count

        let dirtyDraft = try DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey
        ).apply(
            .updateEntry(
                entryID: target.id,
                draft: EntryDraftPayload(
                    title: target.title,
                    username: target.username,
                    password: "rotated-password",
                    url: target.url,
                    notes: target.notes,
                    customFields: target.customFields,
                    tags: target.tags
                )
            )
        )

        _ = try await LocalDatabaseSaver.save(
            draft: dirtyDraft,
            reference: reference,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: KDBXCrypto.sha512(originalData)
        )

        let verifyKey = SymmetricKey(size: .bits256)
        let savedParsed = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: databaseURL),
            password: fixturePassword,
            sessionKey: verifyKey
        )
        let savedEntry = try XCTUnwrap(savedParsed.rootGroup.allEntries.first { $0.title == "Twitter" })
        XCTAssertEqual(try savedEntry.password.decrypt(using: verifyKey), "rotated-password")
        XCTAssertEqual(savedEntry.history.count, originalHistoryCount + 1)

        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        let restored = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: backupURL),
            password: fixturePassword,
            sessionKey: verifyKey
        )
        let restoredEntry = try XCTUnwrap(restored.rootGroup.allEntries.first { $0.title == "Twitter" })

        XCTAssertEqual(try restoredEntry.password.decrypt(using: verifyKey), "twitterpass123")
        XCTAssertEqual(
            restoredEntry.history.count,
            originalHistoryCount,
            "The backup predates the edit, so it must not carry the snapshot the edit pushed"
        )
        XCTAssertEqual(restored.rootGroup.allEntries.map(\.title).sorted(), originalTitles)
    }

    func testSavePrunesBackupsToFiveNewest() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let dates = DateSequence(
            dates: (0..<7).map { Date(timeIntervalSince1970: 1_000 + Double($0)) }
        )
        var environment = LocalDatabaseSaver.Environment.live
        environment.now = {
            dates.next()
        }

        var priorVersions: [Data] = []
        for index in 0..<7 {
            let currentData = try Data(contentsOf: databaseURL)
            priorVersions.append(currentData)
            let context = try makeDirtySaveContext(
                databaseURL: databaseURL,
                entryTitle: "Prune Entry \(index)"
            )

            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: environment
            )
        }

        let backups = DatabaseListStore.recentBackups(for: reference)
        let backupContents = try backups.map { try Data(contentsOf: $0) }

        XCTAssertEqual(backups.count, 5)
        XCTAssertEqual(backupContents, Array(priorVersions.suffix(5).reversed()))
    }

    func testSaveReturnsSavedSHA512ThatMatchesNewBytes() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Hash Entry"
        )

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )
        let savedData = try Data(contentsOf: databaseURL)

        guard case .saved(let newSHA512) = result else {
            XCTFail("Expected save to succeed.")
            return
        }

        XCTAssertEqual(newSHA512, KDBXCrypto.sha512(savedData))
    }

    func testSaveRefreshesSharedCachedCopyWithSavedBytes() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Cached Entry"
        )
        let cacheWrites = WriteCounter()
        var environment = LocalDatabaseSaver.Environment.live
        let liveCacheCopy = environment.cacheDatabaseCopy
        environment.cacheDatabaseCopy = { data, reference in
            cacheWrites.increment()
            try liveCacheCopy(data, reference)
        }

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        let savedData = try Data(contentsOf: databaseURL)
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))

        XCTAssertEqual(try Data(contentsOf: cachedURL), savedData)
        XCTAssertEqual(
            cacheWrites.count,
            1,
            "Local references save to the bookmarked file, so the explicit cache refresh is load-bearing"
        )
    }

    func testSaveCloudReferenceResolvedToCacheWritesCacheExactlyOnce() async throws {
        // A cloud-backed reference has no bookmark, so (as in an AutoFill
        // extension save) the resolved save location IS the shared cache
        // file. The atomic replace is the cache write; a second refresh
        // through cacheDatabaseCopy would write the same bytes again.
        let reference = makeCloudReference()
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL), for: reference)
        let cacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        let context = try makeDirtySaveContext(
            databaseURL: cacheURL,
            entryTitle: "Cloud Cache Entry"
        )

        let cacheWrites = WriteCounter()
        let cachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        var environment = LocalDatabaseSaver.Environment.live
        let liveReplace = environment.replaceFileAtomically
        environment.replaceFileAtomically = { data, url in
            if url.standardizedFileURL.resolvingSymlinksInPath().path == cachePath {
                cacheWrites.increment()
            }
            try liveReplace(data, url)
        }
        let liveCacheCopy = environment.cacheDatabaseCopy
        environment.cacheDatabaseCopy = { data, reference in
            cacheWrites.increment()
            try liveCacheCopy(data, reference)
        }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        guard case .saved(let newSHA512) = result else {
            XCTFail("Expected save to succeed.")
            return
        }
        XCTAssertEqual(
            cacheWrites.count,
            1,
            "Saving a cloud reference must write the shared cache exactly once"
        )
        XCTAssertEqual(KDBXCrypto.sha512(try Data(contentsOf: cacheURL)), newSHA512)
    }

    func testSaveRemoteChangedSinceOpenReturnsConflictDoesNotWrite() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Conflict Entry"
        )
        let remoteData = Data("remote-change".utf8)
        try remoteData.write(to: databaseURL, options: .atomic)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected save conflict.")
            return
        }

        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(remoteData))
        XCTAssertEqual(conflictData, remoteData)
        XCTAssertEqual(try Data(contentsOf: databaseURL), remoteData)
    }

    // A merge has already read the diverged file and folded it into the draft,
    // so that file — and only that file — is safe to replace.

    func testSaveWithReconciledRemoteHashReplacesThatFileButNoOtherState() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Merged Entry"
        )

        let reconciledRemoteData = try makeDivergedDatabaseData(from: databaseURL)
        try reconciledRemoteData.write(to: databaseURL, options: .atomic)
        let reconciledRemoteSHA512 = KDBXCrypto.sha512(reconciledRemoteData)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: .mainApp
        )

        guard case .saved(let newSHA512) = result else {
            XCTFail("A save gated on the reconciled remote must replace exactly that file.")
            return
        }
        XCTAssertEqual(KDBXCrypto.sha512(try Data(contentsOf: databaseURL)), newSHA512)

        // A third state under the save was never reconciled by anyone, so the
        // widened gate must still refuse it.
        let strangerData = try makeDivergedDatabaseData(from: databaseURL)
        try strangerData.write(to: databaseURL, options: .atomic)

        let secondResult = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: .mainApp
        )

        guard case .conflict(let remoteSHA512, _) = secondResult else {
            XCTFail("Expected a conflict for content neither the session nor the merge has seen.")
            return
        }
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(strangerData))
        XCTAssertEqual(try Data(contentsOf: databaseURL), strangerData)
    }

    func testSaveOnReadOnlyFilesystemThrowsAndLeavesOriginalIntact() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let directoryURL = databaseURL.deletingLastPathComponent()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Read Only FS Entry"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Expected save to fail on a read-only filesystem.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        }
    }

    func testSaveAtomicReplaceDoesNotLeaveTempFilesOnSuccess() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Temp Cleanup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: databaseURL.deletingLastPathComponent().path
        ).sorted()

        XCTAssertEqual(siblingNames, [databaseURL.lastPathComponent])
    }

    func testSaveAtomicReplaceFailureLeavesOriginalIntact() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Failure Entry"
        )
        var environment = LocalDatabaseSaver.Environment.live
        environment.replaceFileAtomically = { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: environment
            )
            XCTFail("Expected save to fail when the replace step throws.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        }
    }

    func testSaveUnderNSFileCoordinatorDoesNotDeadlockWhenOtherCoordinatorActive() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Coordinated Entry"
        )

        let readerStarted = expectation(description: "reader started")
        DispatchQueue.global(qos: .utility).async {
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: databaseURL, options: [], error: &coordinatorError) { _ in
                readerStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        await fulfillment(of: [readerStarted], timeout: 5)

        // Generous budget: a deadlock never resolves, so this still catches one,
        // while a slow CI runner doing a real KDBX save (Argon2 + crypto) does
        // not false-fail. GitHub runners have exceeded the previous 5s budget.
        let result = try await withTimeout(seconds: 30) {
            try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
        }

        guard case .saved = result else {
            XCTFail("Expected save to succeed while another coordinator is active.")
            return
        }
    }

    func testSaveLegacyKDBX31ThrowsDatabaseIsReadOnly() async throws {
        let databaseURL = try makeScratchDatabaseCopy(fixtureName: "legacy-kdbx31")
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Legacy Save Attempt"
        )

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Expected legacy KDBX3 save to be blocked as read-only.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Rekey (change master key, #59)

    func testRekeySaveWritesFileThatOpensWithNewKeyAndRejectsOldKey() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekeyed Entry"
        )
        let newPassword = "rotated-master-123"
        let newCompositeKey = try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: newCompositeKey
        )

        guard case .saved(let newSHA512) = result else {
            XCTFail("Expected rekey save to succeed.")
            return
        }

        let savedData = try Data(contentsOf: databaseURL)
        XCTAssertEqual(newSHA512, KDBXCrypto.sha512(savedData))

        let reparsed = try KDBXParser.parseWithMeta(
            data: savedData,
            password: newPassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Rekeyed Entry" })

        XCTAssertThrowsError(
            try KDBXParser.parseWithMeta(
                data: savedData,
                password: fixturePassword,
                sessionKey: SymmetricKey(size: .bits256)
            ),
            "The old credentials must no longer open the rekeyed file."
        )
    }

    func testRekeySaveBackupStillOpensWithOldCredentials() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Backup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        )

        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
        let restored = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: backupURL),
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertEqual(
            restored.rootGroup.allEntries.map(\.title).sorted(),
            context.originalRootGroup.allEntries.map(\.title).sorted()
        )
    }

    func testRekeySaveConflictLeavesFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Conflict Entry"
        )
        let remoteData = Data("changed-outside".utf8)
        try remoteData.write(to: databaseURL, options: .atomic)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        )

        guard case .conflict = result else {
            XCTFail("Expected the rekey save to conflict.")
            return
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), remoteData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    func testRekeySaveVerificationFailureLeavesFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Verify Entry"
        )
        let newCompositeKey = try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        var environment = LocalDatabaseSaver.Environment.live
        let liveExtractHeader = environment.extractHeader
        environment.extractHeader = { data, key, kdfPolicy in
            if key == newCompositeKey {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try liveExtractHeader(data, key, kdfPolicy)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey,
                environment: environment
            )
            XCTFail("Expected the rekey save to fail verification.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .rekeyVerificationFailed)
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    /// A real KDBX under the same key whose bytes differ from `databaseURL`'s
    /// — what another client would have left behind.
    private func makeDivergedDatabaseData(from databaseURL: URL) throws -> Data {
        let compositeKey = try KDBXCrypto.compositeKey(password: fixturePassword)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: try Data(contentsOf: databaseURL),
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
        let parent = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup) == parsed.rootGroup.id
            ? parsed.rootGroup
            : parsed.rootGroup.groups[0]
        parent.entries.append(KPEntry(title: "Diverged \(UUID().uuidString)"))

        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: parsed.header,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }

    private func makeDirtySaveContext(
        databaseURL: URL,
        entryTitle: String
    ) throws -> SaveContext {
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let cleanDraft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey
        )
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: entryTitle,
                    password: "secret-\(entryTitle)"
                )
            )
        )

        return SaveContext(
            draft: dirtyDraft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: KDBXCrypto.sha512(originalData),
            originalRootGroup: parsed.rootGroup
        )
    }

    private func makeCloudReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
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
            isReadOnly: false,
            autoFillEnabled: true,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-local-saver",
                    fileId: "/Vaults/cloud.kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: "rev-1",
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }

    private func makeScratchDatabaseCopy(fixtureName: String = "test") throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            named: fixtureName,
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scratchURL = scratchDirectory.appendingPathComponent("local-save.kdbx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data(contentsOf: fixtureURL).write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    private func makeScratchTwofishDatabase() throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            named: "test",
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        let sourceData = try Data(contentsOf: fixtureURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: sourceData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let compositeKey = KDBXCrypto.compositeKey(password: fixturePassword)
        let twofishData = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.twofishCipherUUID,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scratchURL = scratchDirectory.appendingPathComponent("twofish-save.kdbx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try twofishData.write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

private struct SaveContext {
    let draft: DatabaseDraft
    let compositeKey: SymmetricKey
    let openTimeSHA512: Data
    let originalRootGroup: KPGroup
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class DateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}

private struct TimeoutError: Error {}
