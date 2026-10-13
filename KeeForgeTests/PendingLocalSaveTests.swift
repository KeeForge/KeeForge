import CryptoKit
import XCTest
@testable import KeeForge

/// AutoFill saves the Mac extension can only write to the shared copy (#182):
/// the store that keeps them, the save that records them, and the app-side
/// merge that carries them into the database file.
@MainActor
final class PendingLocalSaveTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    // MARK: - Store

    func testAddKeepsEncryptedBytesUnderTheGroupContainerOldestFirst() throws {
        let databaseID = UUID()
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)

        let second = try PendingLocalSaveStore.add(Data("second".utf8), for: databaseID, now: earlier.addingTimeInterval(60))
        let first = try PendingLocalSaveStore.add(Data("first".utf8), for: databaseID, now: earlier)

        XCTAssertEqual(PendingLocalSaveStore.saves(for: databaseID), [first, second])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("second".utf8))
        XCTAssertTrue(PendingLocalSaveStore.saves(for: UUID()).isEmpty)

        let containerPath = normalizedPath(AppGroupContainer.url)
        for save in [first, second] {
            XCTAssertTrue(normalizedPath(save.fileURL).hasPrefix(containerPath))
            XCTAssertEqual(save.fileURL.pathExtension, "kdbx", "Only .kdbx payloads may be written to the group container")
        }
    }

    func testAddNeverReplacesASaveMadeAtTheSameInstant() throws {
        let databaseID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try PendingLocalSaveStore.add(Data("first".utf8), for: databaseID, now: now)
        let second = try PendingLocalSaveStore.add(Data("second".utf8), for: databaseID, now: now)

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: databaseID), [first, second])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
    }

    func testRemovingADatabaseRemovesItsPendingSaves() throws {
        let reference = try DatabaseListStore.add(url: makeScratchDatabaseCopy())
        let kept = UUID()
        try PendingLocalSaveStore.add(Data("removed".utf8), for: reference.id)
        try PendingLocalSaveStore.add(Data("kept".utf8), for: kept)

        DatabaseListStore.remove(id: reference.id)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: kept))
    }

    func testMoveToBackupsListsTheSaveAmongTheDatabaseBackups() throws {
        let reference = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        let save = try PendingLocalSaveStore.add(Data("unmergeable".utf8), for: reference.id)

        let backupURL = try PendingLocalSaveStore.moveToBackups(save, for: reference)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(
            DatabaseListStore.recentBackups(for: reference).map(\.lastPathComponent),
            [backupURL.lastPathComponent]
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), Data("unmergeable".utf8))
        XCTAssertTrue(DatabaseListStore.isRetainedBackup(backupURL))
        XCTAssertEqual(
            DatabaseExportService.backupDate(fromFilename: backupURL.lastPathComponent),
            DatabaseExportService.backupDate(fromFilename: save.fileURL.lastPathComponent),
            "Database Details dates a backup from its filename, and this one keeps the time of the AutoFill save"
        )
    }

    func testBackupRotationNeverRemovesASaveMovedToTheBackups() throws {
        let reference = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let save = try PendingLocalSaveStore.add(Data("unmergeable".utf8), for: reference.id, now: earlier)
        let retainedURL = try PendingLocalSaveStore.moveToBackups(save, for: reference)
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        for offset in 1...7 {
            let name = LocalDatabaseSaver.backupFilename(for: earlier.addingTimeInterval(Double(offset) * 60))
            try Data("ordinary-\(offset)".utf8).write(to: backupDirectory.appendingPathComponent(name))
        }

        try DatabaseListStore.pruneBackups(for: reference, keeping: 5)

        let remaining = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(remaining.filter { DatabaseListStore.isRetainedBackup($0) == false }.count, 5)
        XCTAssertEqual(try Data(contentsOf: retainedURL), Data("unmergeable".utf8), "The oldest file, and the only copy of the save")

        try DatabaseListStore.pruneBackups(for: reference, keeping: 0)

        XCTAssertEqual(DatabaseListStore.recentBackups(for: reference).map(\.lastPathComponent), [retainedURL.lastPathComponent])
    }

    // MARK: - Saving to the shared copy

    /// The reported failure and its fix in one place: the Mac extension's
    /// sandbox denies the read of the bookmarked file, which is where the save
    /// used to go.
    func testSaveToTheSharedCopySucceedsWhereTheBookmarkedFileCannotBeOpened() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "New Passkey")

        var sandboxed = LocalDatabaseSaver.Environment.live
        let liveRead = sandboxed.readData
        let cachePath = normalizedPath(DatabaseListStore.cacheLocation(for: reference))
        sandboxed.readData = { url in
            guard normalizedPath(url) == cachePath else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try liveRead(url)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: sandboxed
            )
            XCTFail("A save aimed at the bookmarked file cannot succeed without access to it")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
        }
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))

        sandboxed.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: sandboxed
        )

        guard case .saved(let newSHA512) = result else {
            return XCTFail("Expected the save to the shared copy to succeed")
        }
        let sharedCopy = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(KDBXCrypto.sha512(sharedCopy), newSHA512)
        XCTAssertTrue(try entryTitles(in: sharedCopy).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "The bookmarked file is the app's to write")

        let pendingSaves = PendingLocalSaveStore.saves(for: reference.id)
        XCTAssertEqual(pendingSaves.count, 1)
        XCTAssertEqual(try pendingSaves.first.map { try Data(contentsOf: $0.fileURL) }, sharedCopy)

        let backups = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try backups.first.map { try Data(contentsOf: $0) }, original)
    }

    func testSaveWhoseSharedCopyReplaceFailsKeepsNoPendingSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "Never Saved")

        var environment = LocalDatabaseSaver.Environment.live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
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
            XCTFail("Expected the save to fail when the replace step throws")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }

        XCTAssertFalse(
            PendingLocalSaveStore.hasSaves(for: reference.id),
            "A save that never reached the shared copy must not be merged into the file later"
        )
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
    }

    func testSaveAgainstAChangedSharedCopyConflictsAndKeepsNoPendingSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let refreshed = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "App Refresh")) }
        try DatabaseListStore.cacheDatabaseCopy(refreshed, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "Stale Save")

        var environment = LocalDatabaseSaver.Environment.live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        guard case .conflict = result else {
            return XCTFail("The shared copy changed after it was read, so the save must conflict")
        }
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), refreshed)
    }

    func testAnAppSaveLeavesTheSharedCopyAloneWhileASaveIsPending() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "App Edit")

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        guard case .saved = result else {
            return XCTFail("Expected the app save to succeed")
        }
        XCTAssertTrue(try entryTitles(in: try Data(contentsOf: databaseURL)).contains("App Edit"))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            pending,
            "AutoFill reads the shared copy, and the saved bytes do not hold the pending passkey"
        )
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
    }

    func testAutoFillSaveOfABookmarkedDatabaseLandsWhereTheExtensionCanWrite() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(data: original, password: fixturePassword, sessionKey: sessionKey)
        var environment = AutoFillSaveCoordinator.Environment.live
        environment.populateCredentialStore = { _, _ in }

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(title: "example.com", username: "alice", url: "https://example.com"),
            reference: reference,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: KDBXCrypto.sha512(original),
            environment: environment
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected the AutoFill save to succeed")
        }
        let sharedCopy = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(KDBXCrypto.sha512(sharedCopy), outcome.newSHA512)
        #if os(macOS)
        XCTAssertTrue(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: reference))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "The Mac extension cannot open the bookmarked file")
        XCTAssertEqual(
            try PendingLocalSaveStore.saves(for: reference.id).map { try Data(contentsOf: $0.fileURL) },
            [sharedCopy]
        )
        #else
        XCTAssertFalse(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: reference))
        XCTAssertEqual(try Data(contentsOf: databaseURL), sharedCopy, "The iOS extension writes the bookmarked file itself")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        #endif
    }

    #if os(macOS)
    func testOnlyBookmarkedLocalDatabasesAwaitWriteBackOnTheMac() throws {
        let bookmarked = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        var appOnly = bookmarked
        appOnly.bookmarkData = nil

        XCTAssertTrue(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: bookmarked))
        XCTAssertFalse(
            LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: appOnly),
            "A database without a bookmark lives in the shared copy, which is its only file"
        )
        XCTAssertFalse(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: makeCloudReference()))

        let location = try XCTUnwrap(LocalDatabaseSaver.Environment.autoFillExtension.resolveLocation(bookmarked))
        XCTAssertEqual(normalizedPath(location.url), normalizedPath(DatabaseListStore.cacheLocation(for: bookmarked)))
        XCTAssertTrue(location.awaitsWriteBack)
        XCTAssertFalse(location.usesSecurityScope)
    }
    #endif

    // MARK: - Merging into the database file

    func testUnlockMergesAPendingSaveIntoTheDatabaseFileAndRemovesIt() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        let saved = try Data(contentsOf: databaseURL)
        XCTAssertTrue(try entryTitles(in: saved).contains("New Passkey"))
        XCTAssertTrue(Set(try entryTitles(in: saved)).isSuperset(of: try entryTitles(in: original)))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(saved))
        XCTAssertTrue(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), saved)
        XCTAssertTrue(
            try DatabaseListStore.recentBackups(for: reference).contains { try Data(contentsOf: $0) == original },
            "The file's previous bytes are backed up like any other save"
        )
        XCTAssertNil(vm.pendingUploadMergeFailure)
        XCTAssertNil(vm.saveError)
        XCTAssertFalse(vm.isSaving)
    }

    func testUnlockKeepsWhatTheFileGainedSinceTheSharedCopyWasTaken() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)
        try seedPendingSave(pending, for: reference)
        try PendingLocalSaveStore.add(pending, for: reference.id)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        let titles = try entryTitles(in: try Data(contentsOf: databaseURL))
        XCTAssertTrue(titles.contains("New Passkey"))
        XCTAssertTrue(titles.contains("Added In Another App"))
        XCTAssertEqual(titles.filter { $0 == "New Passkey" }.count, 1, "Merging the same save twice adds it once")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testUnlockLeavesTheSharedCopyAloneWhileASaveIsPending() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        var reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        reference.isReadOnly = true
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            pending,
            "Replacing the shared copy from the file would hide the save from AutoFill"
        )
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1, "A read-only session cannot merge")
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testUnlockWithoutAPendingSaveStillRefreshesTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(Data("stale".utf8), for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testAPendingSaveThatCannotBeOpenedMovesToTheBackupsAndIsReported() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let unreadable = Data("not-a-kdbx-file".utf8)
        try seedPendingSave(unreadable, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        let backupURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == unreadable }
        )
        guard case .changeUnreadable(.backup(let reportedURL))? = vm.pendingUploadMergeFailure else {
            return XCTFail("Expected the unreadable save to be reported, got \(String(describing: vm.pendingUploadMergeFailure))")
        }
        XCTAssertEqual(normalizedPath(reportedURL), normalizedPath(backupURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            original,
            "The shared copy follows the file again"
        )
    }

    func testAPendingSaveWithDivergedAttachmentsMovesToTheBackupsAndIsReported() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let diverged = try makeVariantData(
            of: original,
            binaryPoolFields: [Data([0x00]) + Data("attachment-bytes".utf8)]
        ) { visibleRoot in
            var entry = KPEntry(title: "Entry With Attachment")
            entry.attachments = [KPAttachment(name: "note.txt", ref: 0)]
            visibleRoot.entries.append(entry)
        }
        let mergeable = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(diverged, for: reference, now: Date(timeIntervalSince1970: 1_800_000_000))
        try PendingLocalSaveStore.add(mergeable, for: reference.id, now: Date(timeIntervalSince1970: 1_800_000_060))
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        let backupURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == diverged }
        )
        guard case .attachmentsDivergedFromFile(let reportedURL)? = vm.pendingUploadMergeFailure else {
            return XCTFail("Expected the diverged save to be reported, got \(String(describing: vm.pendingUploadMergeFailure))")
        }
        XCTAssertEqual(normalizedPath(reportedURL), normalizedPath(backupURL))
        let titles = try entryTitles(in: try Data(contentsOf: databaseURL))
        XCTAssertTrue(titles.contains("New Passkey"), "One unmergeable save must not hold back the others")
        XCTAssertFalse(titles.contains("Entry With Attachment"))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            try Data(contentsOf: databaseURL)
        )
    }

    func testASaveMovedToTheBackupsSurvivesTheBackupRotationOfLaterSaves() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let diverged = try makeVariantData(
            of: original,
            binaryPoolFields: [Data([0x00]) + Data("attachment-bytes".utf8)]
        ) { visibleRoot in
            var entry = KPEntry(title: "Only Copy Of This Passkey")
            entry.attachments = [KPAttachment(name: "note.txt", ref: 0)]
            visibleRoot.entries.append(entry)
        }
        try seedPendingSave(diverged, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let retainedURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == diverged }
        )

        for index in 1...6 {
            vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Later Edit \(index)")
            try await vm.save()
        }

        XCTAssertEqual(
            try entryTitles(in: try Data(contentsOf: databaseURL)).filter { $0.hasPrefix("Later Edit") }.count,
            6
        )
        let backups = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(backups.filter { DatabaseListStore.isRetainedBackup($0) == false }.count, 5, "Ordinary backups still rotate")
        XCTAssertEqual(try Data(contentsOf: retainedURL), diverged)
        XCTAssertTrue(try entryTitles(in: try Data(contentsOf: retainedURL)).contains("Only Copy Of This Passkey"))
    }

    func testAPendingSaveWaitsForUnsavedEditsAndIsMergedByTheSaveThatWritesThem() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Edit")

        await vm.mergePendingLocalSaves()

        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "Unsaved edits are the user's to save or discard")
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), pending)

        try await vm.save()

        let saved = try Data(contentsOf: databaseURL)
        let titles = try entryTitles(in: saved)
        XCTAssertTrue(titles.contains("Unsaved Edit"))
        XCTAssertTrue(titles.contains("New Passkey"), "The save the merge was waiting for must run it")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            saved,
            "AutoFill must never lose sight of the passkey"
        )
        XCTAssertTrue(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
        XCTAssertNil(vm.draft)
    }

    func testChangingTheMasterKeyMergesAPendingSaveFirst() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        let rekeyed = try Data(contentsOf: databaseURL)
        let reopened = try KDBXParser.parse(data: rekeyed, password: "rotated-master", sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(
            allEntryTitles(in: reopened).contains("New Passkey"),
            "A save written under the old key cannot be merged once the key has changed"
        )
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), rekeyed)
    }

    func testChangingTheMasterKeyIsRefusedWhileAPendingSaveCannotBeMerged() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)

        do {
            try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("The pending save is still under the old key")
        } catch {
            // Not `pendingUploadsExist`: its message tells the user to wait
            // for syncing, and no amount of waiting moves this session's
            // baseline past the change another app made.
            XCTAssertEqual(error as? DatabaseViewModel.RekeyError, .conflict)
            XCTAssertEqual(
                MasterKeyChangeViewModel.message(for: error),
                String(localized: "The database file changed since it was opened. Reload the database and try again.")
            )
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), changedElsewhere)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)

        // Following that message works: the reload takes the other app's
        // change as the baseline, and the retry merges the save and rekeys.
        try await vm.reloadDiscardingDraft()
        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        let reopened = try KDBXParser.parse(
            data: try Data(contentsOf: databaseURL), password: "rotated-master", sessionKey: SymmetricKey(size: .bits256)
        )
        let titles = allEntryTitles(in: reopened)
        XCTAssertTrue(titles.contains("New Passkey"))
        XCTAssertTrue(titles.contains("Added In Another App"))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testChangingTheMasterKeyStillAsksToWaitWhenAPendingSaveIsNotHeldUpByTheFile() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        // A save that fails for another reason than a changed file leaves the
        // pending save in place without a conflict to reload out of.
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _, _, _, _ in throw SaveError.saveContextUnavailable }
        )
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        do {
            try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("The pending save is still under the old key")
        } catch {
            XCTAssertEqual(error as? DatabaseViewModel.RekeyError, .pendingUploadsExist)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
    }

    func testMergeWhoseSaveConflictsKeepsThePendingSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)

        let result = await vm.mergePendingLocalSaves()

        XCTAssertEqual(result, .fileChangedSinceOpen)
        XCTAssertEqual(try Data(contentsOf: databaseURL), changedElsewhere, "The file moved on since this session opened it")
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertNil(vm.pendingUploadMergeFailure)
        XCTAssertNil(vm.saveConflict)
        XCTAssertFalse(vm.isSaving)
        XCTAssertFalse(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
    }

    func testBecomingActiveMergesAPendingSaveInsteadOfReplacingTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        vm.refreshSharedDatabaseCacheIfPossible()

        try await waitUntil("the pending save is merged") {
            PendingLocalSaveStore.hasSaves(for: reference.id) == false && vm.isSaving == false
        }
        let saved = try Data(contentsOf: databaseURL)
        XCTAssertTrue(try entryTitles(in: saved).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), saved)
    }

    func testBecomingActiveWhileLockedLeavesThePendingSaveAndTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        vm.refreshSharedDatabaseCacheIfPossible()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), pending)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    // MARK: - Helpers

    private struct SaveContext {
        let draft: DatabaseDraft
        let compositeKey: SymmetricKey
        let openTimeSHA512: Data
    }

    /// What the extension leaves behind: the saved bytes in the shared copy
    /// and the same bytes as a pending save.
    private func seedPendingSave(_ data: Data, for reference: DatabaseReference, now: Date = .now) throws {
        try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
        try PendingLocalSaveStore.add(data, for: reference.id, now: now)
    }

    private func makeDirtySaveContext(data: Data, entryTitle: String) throws -> SaveContext {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(data: data, password: fixturePassword, sessionKey: sessionKey)
        let cleanDraft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup),
                draft: EntryDraftPayload(title: entryTitle, password: "secret-\(entryTitle)")
            )
        )
        return SaveContext(
            draft: dirtyDraft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: KDBXCrypto.sha512(data)
        )
    }

    private func makeDirtyDraft(from viewModel: DatabaseViewModel, entryTitle: String) throws -> DatabaseDraft {
        let rootGroup = try XCTUnwrap(viewModel.rootGroup)
        let cleanDraft = DatabaseDraft(
            rootGroup: rootGroup,
            meta: KPMeta(
                recycleBinUUID: rootGroup.recycleBinUUID,
                hasRecycleBinUUIDElement: rootGroup.recycleBinUUID != nil
            ),
            sessionKey: try XCTUnwrap(viewModel.sessionKey)
        )
        return try cleanDraft.apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: rootGroup),
                draft: EntryDraftPayload(title: entryTitle, password: "secret-\(entryTitle)")
            )
        )
    }

    /// A database that opens with the fixture password but whose content
    /// differs from `data`, as another writer would leave it.
    private func makeVariantData(
        of data: Data,
        binaryPoolFields: [Data]? = nil,
        mutate: (KPGroup) -> Void
    ) throws -> Data {
        let compositeKey = try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
        let visibleRoot = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup) == parsed.rootGroup.id
            ? parsed.rootGroup
            : parsed.rootGroup.groups[0]
        mutate(visibleRoot)

        var header = parsed.header
        if let binaryPoolFields {
            header.innerHeaderBinaryFields = binaryPoolFields
        }
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }

    private func entryTitles(in data: Data) throws -> [String] {
        let root = try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        return allEntryTitles(in: root)
    }

    private func allEntryTitles(in group: KPGroup) -> [String] {
        group.entries.map(\.title) + group.groups.flatMap(allEntryTitles(in:))
    }

    private func makeScratchDatabaseCopy() throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(bundle: Bundle(for: PendingLocalSaveTests.self))
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true, attributes: nil)
        let scratchURL = scratchDirectory.appendingPathComponent("pending-local-save.kdbx", isDirectory: false)
        try Data(contentsOf: fixtureURL).write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    #if os(macOS)
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
                    provider: CloudProviderKind.webDAV.rawValue,
                    accountId: "acct-pending-local-save",
                    fileId: "/Vaults/cloud.kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: "rev-1",
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }
    #endif

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting until \(description)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// On a device the group container lives under `/private/var`, and Foundation
/// drops that prefix only for paths that already exist.
private func normalizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}
