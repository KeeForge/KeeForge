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

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let savedData = try Data(contentsOf: databaseURL)
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))

        XCTAssertEqual(try Data(contentsOf: cachedURL), savedData)
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
        let databaseURL = try makeScratchDatabaseCopy(fixtureName: "test-v3-backup")
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
    let compositeKey: Data
    let openTimeSHA512: Data
    let originalRootGroup: KPGroup
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
