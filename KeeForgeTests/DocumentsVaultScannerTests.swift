import XCTest
@testable import KeeForge

@MainActor
final class DocumentsVaultScannerTests: XCTestCase {
    private var documentsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        DatabaseListStore.documentsDirectoryOverride = nil
        try? FileManager.default.removeItem(at: documentsDirectory)
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    func testScanRegistersValidKDBXFileAsDocumentsResident() throws {
        try writeDatabaseFile(named: "vault.kdbx")

        let didChange = DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertTrue(didChange)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(stored.filename, "vault.kdbx")
        XCTAssertTrue(stored.isDocumentsResident)
        XCTAssertNotNil(DatabaseListStore.resolveDatabaseURL(for: stored))
        XCTAssertNotNil(DatabaseListStore.cachedDatabaseURL(for: stored.id))
    }

    func testScanIgnoresNonDatabaseHiddenAndDirectoryEntries() throws {
        let fileManager = FileManager.default
        try Data("just text".utf8)
            .write(to: documentsDirectory.appendingPathComponent("notes.txt"))
        // Extension alone must not qualify: registration needs the magic bytes.
        try Data("not a database".utf8)
            .write(to: documentsDirectory.appendingPathComponent("broken.kdbx"))
        try (Self.kdbxMagic + Data("hidden".utf8))
            .write(to: documentsDirectory.appendingPathComponent(".hidden.kdbx"))
        let inbox = documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try (Self.kdbxMagic + Data("nested".utf8))
            .write(to: inbox.appendingPathComponent("nested.kdbx"))
        try fileManager.createDirectory(
            at: documentsDirectory.appendingPathComponent("folder.kdbx", isDirectory: true),
            withIntermediateDirectories: true
        )

        let didChange = DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertFalse(didChange)
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testScanDoesNotDuplicateAlreadyRegisteredFile() throws {
        try writeDatabaseFile(named: "vault.kdbx")

        XCTAssertTrue(DocumentsVaultScanner.scan(directory: documentsDirectory))
        let firstID = try XCTUnwrap(DatabaseListStore.databases.first?.id)

        XCTAssertFalse(DocumentsVaultScanner.scan(directory: documentsDirectory))
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(DatabaseListStore.databases.first?.id, firstID)
    }

    func testScanRebindsReplacedFileToExistingReferenceInsteadOfDuplicating() throws {
        let url = try writeDatabaseFile(named: "vault.kdbx", payload: "original")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        var reference = try XCTUnwrap(DatabaseListStore.databases.first)

        reference.nickname = "Mine"
        // Finder replace over USB is delete+recopy: the old bookmark stops
        // resolving. Corrupt it so resolution fails deterministically.
        reference.bookmarkData = Data("stale-bookmark".utf8)
        DatabaseListStore.update(reference)
        try FileManager.default.removeItem(at: url)
        let replacedContents = try writeDatabaseFile(named: "vault.kdbx", payload: "replaced")

        let didChange = DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertTrue(didChange)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        let rebound = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(rebound.id, reference.id)
        XCTAssertEqual(rebound.nickname, "Mine")
        XCTAssertTrue(rebound.isDocumentsResident)

        let resolvedURL = try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: rebound))
        XCTAssertEqual(try Data(contentsOf: resolvedURL), try Data(contentsOf: replacedContents))

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: rebound.id))
        XCTAssertEqual(try Data(contentsOf: cachedURL), try Data(contentsOf: replacedContents))
    }

    func testScanLeavesStrandedReferenceAloneWhenNoFileMatchesItsFilename() throws {
        try writeDatabaseFile(named: "vault.kdbx")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        var reference = try XCTUnwrap(DatabaseListStore.databases.first)

        reference.bookmarkData = Data("stale-bookmark".utf8)
        DatabaseListStore.update(reference)
        try FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent("vault.kdbx"))
        try writeDatabaseFile(named: "other.kdbx")

        DocumentsVaultScanner.scan(directory: documentsDirectory)

        let stored = DatabaseListStore.databases
        XCTAssertEqual(stored.count, 2)
        let stranded = try XCTUnwrap(stored.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stranded.bookmarkData, Data("stale-bookmark".utf8))
        XCTAssertTrue(stored.contains(where: { $0.filename == "other.kdbx" }))
    }

    func testScanRebindsReferenceWhoseBookmarkResolvesIntoTrash() throws {
        let url = try writeDatabaseFile(named: "vault.kdbx", payload: "original")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        let reference = try XCTUnwrap(DatabaseListStore.databases.first)

        // Files-app Delete: the bookmark keeps following the old copy into
        // .Trash while a fresh file appears at the original path.
        let trashDirectory = documentsDirectory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trashDirectory.appendingPathComponent("vault.kdbx"))
        let replacedContents = try writeDatabaseFile(named: "vault.kdbx", payload: "replaced")

        DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        let rebound = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(rebound.id, reference.id)

        let resolvedURL = try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: rebound))
        XCTAssertFalse(resolvedURL.pathComponents.contains(".Trash"))
        XCTAssertEqual(try Data(contentsOf: resolvedURL), try Data(contentsOf: replacedContents))

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: rebound.id))
        XCTAssertEqual(try Data(contentsOf: cachedURL), try Data(contentsOf: replacedContents))
    }

    func testScanDoesNotRebindStrandedReferenceOntoAnotherReferencesFile() throws {
        try writeDatabaseFile(named: "vault.kdbx")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        let claimant = try XCTUnwrap(DatabaseListStore.databases.first)

        // A stranded Documents-resident reference whose filename now matches a
        // file another live reference resolves to (e.g. its own file was
        // renamed away). Rebinding it would hand vault.kdbx a second identity
        // with the stranded reference's key file and Keychain composite key.
        let stranded = DatabaseReference(
            id: UUID(),
            nickname: "Stranded",
            filename: "vault.kdbx",
            bookmarkData: Data("stale-bookmark".utf8),
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil,
            isDocumentsResident: true
        )
        DatabaseListStore.update(stranded)

        DocumentsVaultScanner.scan(directory: documentsDirectory)

        let stored = DatabaseListStore.databases
        XCTAssertEqual(stored.count, 2)
        let storedStranded = try XCTUnwrap(stored.first(where: { $0.id == stranded.id }))
        XCTAssertEqual(storedStranded.bookmarkData, Data("stale-bookmark".utf8))
        let storedClaimant = try XCTUnwrap(stored.first(where: { $0.id == claimant.id }))
        XCTAssertEqual(
            DatabaseListStore.resolveDatabaseURL(for: storedClaimant)?.lastPathComponent,
            "vault.kdbx"
        )
    }

    func testScanReconcilesStaleCacheAfterSamePathReplace() throws {
        let url = try writeDatabaseFile(named: "vault.kdbx", payload: "original")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        let reference = try XCTUnwrap(DatabaseListStore.databases.first)

        // In-place overwrite (non-atomic, same inode): the bookmark stays
        // valid, so only the reconcile pass can notice the cache went stale.
        let replacedContents = Self.kdbxMagic + Data("replaced".utf8)
        try replacedContents.write(to: url)

        let didChange = DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertFalse(didChange)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: cachedURL), replacedContents)
    }

    func testScanRederivesFilenameAfterRename() throws {
        let url = try writeDatabaseFile(named: "vault.kdbx")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        let reference = try XCTUnwrap(DatabaseListStore.databases.first)

        // Files-app rename: the bookmark keeps resolving, but path-keyed
        // rebinding is keyed on the stored filename, so it must follow.
        try FileManager.default.moveItem(
            at: url,
            to: documentsDirectory.appendingPathComponent("renamed.kdbx")
        )

        let didChange = DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertTrue(didChange)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stored.filename, "renamed.kdbx")
        XCTAssertTrue(stored.isDocumentsResident)
    }

    func testScanDropsResidencyWhenFileMovesOutOfTopLevelDocuments() throws {
        let url = try writeDatabaseFile(named: "vault.kdbx")
        DocumentsVaultScanner.scan(directory: documentsDirectory)
        let reference = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertTrue(reference.isDocumentsResident)

        let subdirectory = documentsDirectory.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: url,
            to: subdirectory.appendingPathComponent("vault.kdbx")
        )

        DocumentsVaultScanner.scan(directory: documentsDirectory)

        // The file left top-level Documents: the reference keeps working via
        // its bookmark but must stop participating in path-keyed rebinding.
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertFalse(stored.isDocumentsResident)
    }

    private static let kdbxMagic = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])

    @discardableResult
    private func writeDatabaseFile(named name: String, payload: String = "body") throws -> URL {
        let url = documentsDirectory.appendingPathComponent(name, isDirectory: false)
        try (Self.kdbxMagic + Data(payload.utf8)).write(to: url)
        return url
    }
}
