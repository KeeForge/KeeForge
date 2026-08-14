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
        XCTAssertFalse(created.reference.isDocumentsResident)
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

    func testCreateKeyFileOnlyDatabaseReopensWithKeyFile() async throws {
        let destinationURL = try makeDestinationURL(name: "KeyFileOnly.kdbx")
        let keyFileData = try SecureRandom.data(count: 32)

        _ = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "KeyFileOnly",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                keyFileData: keyFileData
            )
        )

        let parsed = try KDBXParser.parseWithMeta(
            data: Data(contentsOf: destinationURL),
            password: nil,
            keyFileData: keyFileData,
            sessionKey: SymmetricKey(size: .bits256)
        )

        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "KeyFileOnly")
    }

    func testCreateRejectsMalformedSuppliedKeyFileBeforeWriting() async throws {
        let destinationURL = try makeDestinationURL(name: "MalformedKeyFile.kdbx")
        let malformedKeyFile = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <KeyFile>
          <Meta><Version>1.0</Version></Meta>
          <Key><Data>not-a-32-byte-key</Data></Key>
        </KeyFile>
        """.utf8)

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "MalformedKeyFile",
                    destination: .files(
                        url: destinationURL,
                        bookmarkData: try bookmarkData(for: destinationURL)
                    ),
                    keyFileData: malformedKeyFile
                )
            )
            XCTFail("Expected malformed key file to be rejected.")
        } catch KeyFileProcessor.KeyFileError.xmlKeyDataInvalid {
            XCTAssertTrue(try Data(contentsOf: destinationURL).isEmpty)
            XCTAssertTrue(DatabaseListStore.databases.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
        XCTAssertEqual(recycleBin.name, DatabaseDraft.localizedRecycleBinName)
        XCTAssertEqual(created.meta.recycleBinUUID, recycleBin.id)
        XCTAssertTrue(created.meta.hasRecycleBinUUIDElement)
    }

    func testCreateDatabaseUsesExpectedKDFDefaults() throws {
        let salt = Data(repeating: 7, count: DatabaseCreationDefaults.kdfSaltByteCount)
        let parameters = try DatabaseCreationDefaults.argon2idKDFParameters(salt: salt)

        XCTAssertEqual(parameters["$UUID"] as? Data, KDBXParser.argon2idUUID)
        XCTAssertEqual(parameters["I"] as? UInt64, 10)
        XCTAssertEqual(parameters["M"] as? UInt64, 64 * 1024 * 1024)
        XCTAssertEqual(parameters["P"] as? UInt32, UInt32(min(ProcessInfo.processInfo.processorCount, 4)))
        XCTAssertEqual(parameters["V"] as? UInt32, 0x13)
        XCTAssertEqual(parameters["S"] as? Data, salt)
    }

    func testCreateDatabaseUsesChosenPresetKDFParameters() throws {
        let salt = Data(repeating: 9, count: DatabaseCreationDefaults.kdfSaltByteCount)
        let strong = try DatabaseCreationDefaults.argon2idKDFParameters(preset: .strong, salt: salt)
        XCTAssertEqual(strong["M"] as? UInt64, 128 << 20)
        XCTAssertEqual(strong["I"] as? UInt64, 10)

        let maximum = try DatabaseCreationDefaults.argon2idKDFParameters(preset: .maximum, salt: salt)
        XCTAssertEqual(maximum["M"] as? UInt64, 256 << 20)
        XCTAssertEqual(maximum["I"] as? UInt64, 12)
    }

    func testPrepareChaCha20DatabaseRoundTripsWithChaChaCipherHeader() async throws {
        let prepared = try await DatabaseCreationService.prepare(
            request: DatabasePreparationRequest(
                displayName: "ChaCha",
                password: "chacha password",
                keyFileData: nil,
                keyFileBookmarkData: nil,
                keyFileFilename: nil,
                cipher: .chacha20
            )
        )

        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: prepared.encryptedBytes,
            password: "chacha password",
            sessionKey: SymmetricKey(size: .bits256)
        )

        XCTAssertEqual(parsed.header.cipherID, KDBXParser.chachaCipherUUID)
        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "ChaCha")
    }

    func testPrepareWithStrongPresetLandsChosenParametersInHeader() async throws {
        let prepared = try await DatabaseCreationService.prepare(
            request: DatabasePreparationRequest(
                displayName: "Strong",
                password: "strong password",
                keyFileData: nil,
                keyFileBookmarkData: nil,
                keyFileFilename: nil,
                kdfPreset: .strong
            )
        )

        let summary = try KDBXFileSummary.inspect(data: prepared.encryptedBytes)
        XCTAssertEqual(summary.cipher, .aes256CBC)
        XCTAssertEqual(
            summary.keyDerivation,
            .argon2id(
                iterations: 10,
                memoryBytes: 128 << 20,
                parallelism: DatabaseCreationDefaults.argon2idParallelism
            )
        )
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

    func testCreateInDocumentsFolderMarksReferenceDocumentsResident() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let destinationURL = documentsDirectory.appendingPathComponent("Resident.kdbx", isDirectory: false)
        try Data().write(to: destinationURL, options: .atomic)

        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Resident",
                destination: .files(
                    url: destinationURL,
                    bookmarkData: try bookmarkData(for: destinationURL)
                ),
                password: "correct horse battery staple"
            )
        )

        XCTAssertTrue(created.reference.isDocumentsResident)
        XCTAssertEqual(DatabaseListStore.databases.first?.isDocumentsResident, true)
    }

    func testRegisterExportedIntoDocumentsFolderMarksReferenceDocumentsResident() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let prepared = try await DatabaseCreationService.prepare(
            request: DatabasePreparationRequest(
                displayName: "Exported",
                password: "correct horse battery staple",
                keyFileData: nil,
                keyFileBookmarkData: nil,
                keyFileFilename: nil
            )
        )
        let exportedURL = documentsDirectory.appendingPathComponent(prepared.filename, isDirectory: false)
        try prepared.encryptedBytes.write(to: exportedURL, options: .atomic)

        let created = try DatabaseCreationService.registerExported(prepared, exportedURL: exportedURL)

        XCTAssertTrue(created.reference.isDocumentsResident)
        XCTAssertEqual(DatabaseListStore.databases.first?.isDocumentsResident, true)
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

    func testCreateDropboxDatabaseUploadsCachesAndRegistersCloudReference() async throws {
        let recorder = CloudCreateRecorder()
        let environment = cloudCreateEnvironment(recorder: recorder)

        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Cloud Vault",
                destination: .cloud(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    folderPath: "/Vaults"
                ),
                password: "dropbox create password"
            ),
            environment: environment
        )

        let uploadedBytes = try XCTUnwrap(recorder.uploadedData)
        let parsed = try KDBXParser.parseWithMeta(
            data: uploadedBytes,
            password: "dropbox create password",
            sessionKey: SymmetricKey(size: .bits256)
        )
        let metadata = try XCTUnwrap(created.reference.cloudSyncMetadata)
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: created.reference))

        XCTAssertEqual(recorder.uploadedPath, "/Vaults/Cloud Vault.kdbx")
        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "Cloud Vault")
        XCTAssertEqual(created.reference.filename, "Cloud Vault.kdbx")
        XCTAssertEqual(metadata.provider, CloudProviderKind.dropbox.rawValue)
        XCTAssertEqual(metadata.accountId, "acct-1")
        XCTAssertEqual(metadata.fileId, "/Vaults/Cloud Vault.kdbx")
        XCTAssertEqual(metadata.displayPath, "/Vaults/Cloud Vault.kdbx")
        XCTAssertEqual(metadata.remoteContentHash, "created-hash")
        XCTAssertEqual(metadata.remoteRev, "rev-created")
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [created.reference.id])
        XCTAssertEqual(try Data(contentsOf: cachedURL), uploadedBytes)
    }

    func testCreateDropboxDatabaseDoesNotRegisterWhenUploadFails() async throws {
        let recorder = CloudCreateRecorder(error: CloudProviderError.networkUnavailable)
        let environment = cloudCreateEnvironment(recorder: recorder)

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "Upload Failure",
                    destination: .cloud(
                        provider: CloudProviderKind.dropbox.rawValue,
                        accountId: "acct-1",
                        folderPath: nil
                    ),
                    password: "dropbox failure password"
                ),
                environment: environment
            )
            XCTFail("Expected upload failure.")
        } catch CloudProviderError.networkUnavailable {
            XCTAssertTrue(DatabaseListStore.databases.isEmpty)
            XCTAssertEqual(recorder.uploadedPath, "/Upload Failure.kdbx")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateDropboxDatabaseRejectsDuplicateTrackedDestinationBeforeUpload() async throws {
        let existingFile = CloudFile(
            id: "/Vaults/Duplicate.kdbx",
            name: "Duplicate.kdbx",
            path: "/Vaults/Duplicate.kdbx",
            isFolder: false,
            modifiedDate: nil,
            size: nil
        )
        _ = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: existingFile
        )
        let recorder = CloudCreateRecorder()
        let environment = cloudCreateEnvironment(recorder: recorder)

        do {
            _ = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: "Duplicate",
                    destination: .cloud(
                        provider: CloudProviderKind.dropbox.rawValue,
                        accountId: "acct-1",
                        folderPath: "/Vaults"
                    ),
                    password: "duplicate cloud password"
                ),
                environment: environment
            )
            XCTFail("Expected duplicate destination to be rejected.")
        } catch DatabaseListStore.AddDatabaseError.duplicateFile {
            XCTAssertNil(recorder.uploadedPath)
            XCTAssertEqual(DatabaseListStore.databases.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func failingWriteEnvironment() -> DatabaseCreationService.Environment {
        .init(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            id: { UUID() },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in },
            writePrimaryFile: { _, _, _ in throw CocoaError(.fileWriteNoPermission) },
            createCloudFile: DatabaseCreationService.Environment.live.createCloudFile,
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addCreatedCloud: { reference in
                try DatabaseListStore.addCreatedCloud(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            },
            validateCreatedCloud: { provider, accountId, fileId, filename in
                try DatabaseListStore.validateCreatedCloud(
                    provider: provider,
                    accountId: accountId,
                    fileId: fileId,
                    filename: filename
                )
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
            createCloudFile: DatabaseCreationService.Environment.live.createCloudFile,
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addCreatedCloud: { reference in
                try DatabaseListStore.addCreatedCloud(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            },
            validateCreatedCloud: { provider, accountId, fileId, filename in
                try DatabaseListStore.validateCreatedCloud(
                    provider: provider,
                    accountId: accountId,
                    fileId: fileId,
                    filename: filename
                )
            }
        )
    }

    private func cloudCreateEnvironment(recorder: CloudCreateRecorder) -> DatabaseCreationService.Environment {
        .init(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            id: { UUID() },
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in },
            writePrimaryFile: DatabaseCreationService.Environment.live.writePrimaryFile,
            createCloudFile: { provider, accountId, path, data, progress in
                try await recorder.createFile(
                    provider: provider,
                    accountId: accountId,
                    path: path,
                    data: data,
                    progress: progress
                )
            },
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addCreatedCloud: { reference in
                try DatabaseListStore.addCreatedCloud(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            },
            validateCreatedCloud: { provider, accountId, fileId, filename in
                try DatabaseListStore.validateCreatedCloud(
                    provider: provider,
                    accountId: accountId,
                    fileId: fileId,
                    filename: filename
                )
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

private final class CloudCreateRecorder: @unchecked Sendable {
    private let error: Error?
    private nonisolated(unsafe) var storagePath: String?
    private nonisolated(unsafe) var storageData: Data?

    init(error: Error? = nil) {
        self.error = error
    }

    var uploadedPath: String? {
        storagePath
    }

    var uploadedData: Data? {
        storageData
    }

    func createFile(
        provider: String,
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping DatabaseCreationService.CloudProgressHandler
    ) async throws -> CloudCreatedFile {
        storagePath = path
        storageData = data

        if let error {
            throw error
        }

        progress(1)
        let file = CloudFile(
            id: path,
            name: (path as NSString).lastPathComponent,
            path: path,
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_001),
            size: Int64(data.count)
        )
        return CloudCreatedFile(
            file: file,
            metadata: CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 1_700_000_001),
                contentHash: "created-hash",
                size: Int64(data.count),
                rev: "rev-created"
            )
        )
    }
}
