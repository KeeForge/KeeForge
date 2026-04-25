import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseCreationServiceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    func testCreatePasswordOnlyDatabaseWritesParseableKDBX4() async throws {
        let destinationURL = try makeDestinationURL(name: "Personal.kdbx")

        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Personal",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                password: "correct horse battery staple"
            )
        )

        let encryptedBytes = try Data(contentsOf: destinationURL)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: encryptedBytes,
            password: "correct horse battery staple",
            sessionKey: SymmetricKey(size: .bits256)
        )

        XCTAssertEqual(created.reference.filename, "Personal.kdbx")
        XCTAssertEqual(parsed.header.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [created.reference.id])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: created.reference))), encryptedBytes)
    }

    func testCreatePasswordAndKeyFileDatabaseReopensWithCompositeKey() async throws {
        let destinationURL = try makeDestinationURL(name: "Keyed.kdbx")
        let keyFileData = try SecureRandom.data(count: 32)
        let keyFileURL = try makeTemporaryFileURL(name: "Keyed.key", contents: keyFileData)

        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Keyed",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                password: "password plus file",
                keyFileData: keyFileData,
                keyFileBookmarkData: try bookmarkData(for: keyFileURL),
                keyFileFilename: keyFileURL.lastPathComponent
            )
        )

        let encryptedBytes = try Data(contentsOf: destinationURL)
        let parsed = try KDBXParser.parseWithMeta(
            data: encryptedBytes,
            password: "password plus file",
            keyFileData: keyFileData,
            sessionKey: SymmetricKey(size: .bits256)
        )

        XCTAssertEqual(created.reference.keyFileFilename, "Keyed.key")
        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "Keyed")
    }

    func testCreateDatabaseBuildsSingleVisibleRootAndRecycleBin() async throws {
        let destinationURL = try makeDestinationURL(name: "Structure.kdbx")

        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Structure",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                password: "structure password"
            )
        )

        let visibleRoot = try XCTUnwrap(created.rootGroup.groups.first)
        let recycleBin = try XCTUnwrap(visibleRoot.groups.first)

        XCTAssertEqual(created.rootGroup.name, "Root")
        XCTAssertEqual(created.rootGroup.groups.count, 1)
        XCTAssertEqual(visibleRoot.name, "Structure")
        XCTAssertEqual(recycleBin.name, "Recycle Bin")
        XCTAssertEqual(created.meta.recycleBinUUID, recycleBin.id)
        XCTAssertTrue(created.meta.hasRecycleBinUUIDElement)
    }

    func testCreateDatabaseUsesExpectedKDFDefaults() throws {
        let salt = Data(repeating: 7, count: DatabaseCreationDefaults.kdfSaltByteCount)
        let parameters = try DatabaseCreationDefaults.argon2idKDFParameters(salt: salt)

        XCTAssertEqual(parameters["$UUID"] as? Data, KDBXParser.argon2idUUID)
        XCTAssertEqual(parameters["I"] as? UInt64, 3)
        XCTAssertEqual(parameters["M"] as? UInt64, 64 * 1024 * 1024)
        XCTAssertEqual(parameters["P"] as? UInt32, 1)
        XCTAssertEqual(parameters["V"] as? UInt32, 0x13)
        XCTAssertEqual(parameters["S"] as? Data, salt)
    }

    func testCreateDatabaseDoesNotRegisterReferenceWhenDestinationWriteFails() async throws {
        let destinationURL = try makeDestinationURL(name: "WriteFailure.kdbx")
        let environment = failingWriteEnvironment()

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "WriteFailure",
                    destination: .files(
                        url: destinationURL,
                        bookmarkData: try bookmarkData(for: destinationURL)
                    ),
                    password: "write failure password"
                ),
                environment: environment
            )
            XCTFail("Expected destination write to fail.")
        } catch {
            XCTAssertTrue(DatabaseListStore.databases.isEmpty)
        }
    }

    func testCreateDatabaseRejectsDuplicateDestinationBeforeWriting() async throws {
        let destinationURL = try makeDestinationURL(name: "Duplicate.kdbx")
        _ = try DatabaseListStore.add(url: destinationURL)
        let recorder = WriteRecorder()

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "Duplicate",
                    destination: .files(
                        url: destinationURL,
                        bookmarkData: try bookmarkData(for: destinationURL)
                    ),
                    password: "duplicate password"
                ),
                environment: recordingEnvironment(recorder: recorder)
            )
            XCTFail("Expected duplicate destination to be rejected.")
        } catch DatabaseListStore.AddDatabaseError.duplicateFile {
            XCTAssertFalse(recorder.didWrite)
            XCTAssertEqual(DatabaseListStore.databases.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateDatabaseRejectsDuplicateAppCreatedFilenameForAppOnlyFallback() async throws {
        _ = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "LocalOnly",
                destination: .appOnlyAcknowledged,
                password: "first password"
            )
        )

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "LocalOnly",
                    destination: .appOnlyAcknowledged,
                    password: "second password"
                )
            )
            XCTFail("Expected duplicate app-only filename to be rejected.")
        } catch DatabaseListStore.AddDatabaseError.duplicateCreatedFilename(let filename) {
            XCTAssertEqual(filename, "LocalOnly.kdbx")
            XCTAssertEqual(DatabaseListStore.databases.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateDatabaseSanitizesFilenameAndAppendsKDBXExtension() throws {
        XCTAssertEqual(
            try DatabaseCreationService.normalizedFilename(for: "  Family/Vault  "),
            "Family_Vault.kdbx"
        )
        XCTAssertEqual(
            try DatabaseCreationService.normalizedFilename(for: "Work.kdbx"),
            "Work.kdbx"
        )
    }

    func testCreatedEncryptedBytesDoNotContainVisibleRootName() async throws {
        let destinationURL = try makeDestinationURL(name: "SecretName.kdbx")

        _ = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "SecretName",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                password: "secret name password"
            )
        )

        let encryptedBytes = try Data(contentsOf: destinationURL)
        XCTAssertFalse(encryptedBytes.contains(Data("SecretName".utf8)))
    }

    private func failingWriteEnvironment() -> DatabaseCreationService.Environment {
        .init(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            id: { UUID() },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in },
            writePrimaryFile: { _, _, _ in throw CocoaError(.fileWriteNoPermission) },
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            }
        )
    }

    private func recordingEnvironment(recorder: WriteRecorder) -> DatabaseCreationService.Environment {
        .init(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            id: { UUID() },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in },
            writePrimaryFile: { data, url, usesSecurityScope in
                recorder.recordWrite()
                try DatabaseCreationService.Environment.live.writePrimaryFile(data, url, usesSecurityScope)
            },
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            }
        )
    }

    private func makeDestinationURL(name: String) throws -> URL {
        try makeTemporaryFileURL(name: name, contents: Data())
    }

    private func makeTemporaryFileURL(name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, options: .atomic)
        return url
    }

    private func bookmarkData(for url: URL) throws -> Data {
        try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
    }
}

private final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var didWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func recordWrite() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
