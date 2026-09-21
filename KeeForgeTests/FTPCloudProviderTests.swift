import AuthenticationServices
import XCTest
@testable import KeeForge

/// Drives `FTPCloudProvider` end to end against `FakeFTPServer`, so the real
/// command sequence, data connections, and reply mapping are exercised.
/// Credential-dependent tests seed `CloudTokenStore` and `XCTSkip` when the
/// Keychain is unavailable in the test host.
final class FTPCloudProviderTests: XCTestCase {
    private let providerId = CloudProviderKind.ftp.rawValue
    private var seededAccountIds: [String] = []

    override func tearDown() {
        for accountId in seededAccountIds {
            _ = CloudTokenStore.deleteToken(provider: providerId, accountId: accountId)
            CloudAccountStore.remove(provider: providerId, accountId: accountId)
        }
        seededAccountIds.removeAll()
        super.tearDown()
    }

    // MARK: - Connect

    func testConnectLogsInChecksFolderAndPersistsAccount() async throws {
        try skipIfKeychainUnavailable()
        let server = FakeFTPServer()
        server.addDirectory("vaults")
        let provider = FTPCloudProvider(client: server.makeClient())

        let account = try await provider.connect(configuration(serverURL: "NAS.local/vaults"))
        seededAccountIds.append(account.id)

        XCTAssertEqual(account.displayName, "alex@nas.local/vaults")
        XCTAssertEqual(account.provider, providerId)
        XCTAssertTrue(provider.isAuthenticated(accountId: account.id))
        XCTAssertNotNil(CloudAccountStore.account(provider: providerId, accountId: account.id))
        XCTAssertEqual(server.connectionLog, ["nas.local:21"])
        XCTAssertEqual(server.commandLog, ["USER alex", "PASS ***", "OPTS UTF8 ON", "TYPE I", "CWD vaults", "QUIT"])
    }

    func testConnectWithWrongPasswordIsNotAuthenticatedAndPersistsNothing() async throws {
        let server = FakeFTPServer()
        let provider = FTPCloudProvider(client: server.makeClient())

        await assertThrows(CloudProviderError.notAuthenticated) {
            _ = try await provider.connect(self.configuration(password: "wrong"))
        }
        let accountId = FTPURL.accountId(
            normalizedBaseURL: try FTPURL.normalizedBaseURL(from: "ftp://nas.local/", allowsUnencryptedFTP: true),
            username: "alex"
        )
        XCTAssertFalse(provider.isAuthenticated(accountId: accountId))
    }

    func testConnectToMissingFolderIsFileNotFound() async {
        let server = FakeFTPServer()
        let provider = FTPCloudProvider(client: server.makeClient())

        await assertThrows(CloudProviderError.fileNotFound) {
            _ = try await provider.connect(self.configuration(serverURL: "ftp://nas.local/missing"))
        }
    }

    func testConnectWithoutUnencryptedOptInNeverOpensAConnection() async {
        let server = FakeFTPServer()
        let provider = FTPCloudProvider(client: server.makeClient())

        do {
            _ = try await provider.connect(configuration(allowsUnencryptedFTP: false))
            XCTFail("Expected the unencrypted opt-in to be required")
        } catch {
            XCTAssertEqual(error as? FTPURLError, .unencryptedNotAllowed)
        }
        XCTAssertTrue(server.connectionLog.isEmpty)
    }

    // MARK: - Listing

    func testListFilesShowsFoldersThenDatabasesFromMachineListing() async throws {
        let server = FakeFTPServer()
        server.addDirectory("vaults")
        server.addDirectory("vaults/Archive")
        server.setFile("vaults/zeta.kdbx", data: Data("z".utf8))
        server.setFile("vaults/Alpha.KDBX", data: Data("aa".utf8), modified: "20260918120001")
        server.setFile("vaults/notes.txt", data: Data("n".utf8))
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults/")

        let files = try await provider.listFiles(accountId: accountId, path: nil, query: nil, includesAllFiles: false)

        XCTAssertEqual(files.map(\.id), ["/Archive", "/Alpha.KDBX", "/zeta.kdbx"])
        XCTAssertEqual(files.map(\.isFolder), [true, false, false])
        XCTAssertEqual(files[1].size, 2)
        XCTAssertEqual(files[1].modifiedDate, FTPListingParser.date(fromTimeVal: "20260918120001"))
        XCTAssertTrue(server.commandLog.contains("MLSD"))
    }

    func testListFilesInSubfolderFallsBackToLISTAndPASVAgainstTheControlHost() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.supportsExtendedPassive = false
        server.addDirectory("Team Vaults")
        server.setFile("Team Vaults/shared vault.kdbx", data: Data(count: 3072))
        let (provider, accountId) = try makeProvider(server: server)

        let files = try await provider.listFiles(accountId: accountId, path: "/Team Vaults", query: nil, includesAllFiles: false)

        XCTAssertEqual(files.map(\.id), ["/Team Vaults/shared vault.kdbx"])
        XCTAssertEqual(files.first?.size, 3072)
        XCTAssertTrue(server.commandLog.contains("CWD Team Vaults"))
        XCTAssertTrue(server.commandLog.contains("LIST"))
        XCTAssertTrue(
            server.connectionLog.dropFirst().allSatisfy { $0.hasPrefix("nas.local:") },
            "PASV advertised 10.9.8.7; data connections must still go to the control host: \(server.connectionLog)"
        )
    }

    func testListFilesShowsDatabasesStoredWithoutTheKDBXExtensionOnlyWhenAllFilesAreRequested() async throws {
        let server = FakeFTPServer()
        server.addDirectory("vaults")
        server.addDirectory("vaults/Archive")
        server.setFile("vaults/personal.kdbx", data: Data("p".utf8))
        server.setFile("vaults/vault.bin", data: Data("v".utf8))
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults/")

        let databasesOnly = try await provider.listFiles(accountId: accountId, path: nil, query: nil, includesAllFiles: false)
        XCTAssertEqual(databasesOnly.map(\.id), ["/Archive", "/personal.kdbx"])

        let allFiles = try await provider.listFiles(accountId: accountId, path: nil, query: nil, includesAllFiles: true)
        XCTAssertEqual(allFiles.map(\.id), ["/Archive", "/personal.kdbx", "/vault.bin"])
    }

    func testListFilesFiltersByQuery() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("p".utf8))
        server.setFile("work.kdbx", data: Data("w".utf8))
        let (provider, accountId) = try makeProvider(server: server)

        let files = try await provider.listFiles(accountId: accountId, path: "/", query: " WORK ", includesAllFiles: false)

        XCTAssertEqual(files.map(\.name), ["work.kdbx"])
    }

    // MARK: - Download and metadata

    func testDownloadWritesTheRemoteBytesAndReportsTheirRev() async throws {
        let server = FakeFTPServer()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        server.setFile("vaults/personal.kdbx", data: payload)
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("personal.kdbx")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let metadata = try await provider.download(accountId: accountId, fileId: "/personal.kdbx", to: destination) { _ in }

        XCTAssertEqual(metadata?.rev, FTPCloudProvider.rev(of: payload))
        XCTAssertEqual(metadata?.size, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(server.commandLog.contains("RETR vaults/personal.kdbx"))
    }

    /// The sync records this rev as the cache's baseline, so it must describe
    /// the downloaded bytes even when the file changes right after the transfer.
    func testDownloadRevDescribesTheTransferredBytesNotALaterWrite() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("downloaded".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        server.beforeNext("MLST") {
            server.setFile("personal.kdbx", data: Data("other device".utf8))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("personal.kdbx")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let metadata = try await provider.download(accountId: accountId, fileId: "/personal.kdbx", to: destination) { _ in }

        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded".utf8))
        XCTAssertEqual(metadata?.rev, rev("downloaded"))
        XCTAssertEqual(metadata?.size, 10)
    }

    func testGetMetadataRevIsTheSHA256OfTheServerBytes() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("database".utf8), modified: "20260918120001")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, rev("database"))
        XCTAssertEqual(metadata.size, 8)
        XCTAssertEqual(metadata.modifiedDate, FTPListingParser.date(fromTimeVal: "20260918120001"))
        XCTAssertTrue(server.commandLog.contains("RETR personal.kdbx"))
    }

    func testGetMetadataFallsBackToSIZEAndMDTM() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.setFile("personal.kdbx", data: Data("database".utf8), modified: "20260918120001")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, rev("database"))
        XCTAssertEqual(metadata.modifiedDate, FTPListingParser.date(fromTimeVal: "20260918120001"))
        XCTAssertTrue(server.commandLog.contains("SIZE personal.kdbx"))
        XCTAssertTrue(server.commandLog.contains("MDTM personal.kdbx"))
    }

    func testGetMetadataWithoutModificationTimeStillHasARev() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.supportsModificationTime = false
        server.setFile("personal.kdbx", data: Data(count: 42))
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, FTPCloudProvider.rev(of: Data(count: 42)))
        XCTAssertEqual(metadata.size, 42)
    }

    func testGetMetadataForMissingFileIsFileNotFound() async throws {
        let server = FakeFTPServer()
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.fileNotFound) {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/gone.kdbx")
        }
        XCTAssertEqual(
            server.commandLog.filter { ["MLST", "SIZE", "MLSD"].contains($0.prefix(4)) },
            ["MLST gone.kdbx", "SIZE gone.kdbx", "MLSD"],
            "absence is only reported once a listing of the folder shows it"
        )
    }

    // MARK: - Rev

    func testRevIsDeterministicAndDependsOnlyOnTheBytes() {
        let first = FTPCloudProvider.rev(of: Data("same bytes".utf8))

        XCTAssertEqual(first, FTPCloudProvider.rev(of: Data("same bytes".utf8)))
        XCTAssertEqual(first, "sha256:" + KDBXCrypto.sha256(Data("same bytes".utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertNotEqual(first, FTPCloudProvider.rev(of: Data("same bytez".utf8)))
    }

    func testSameSizeAndStampWithDifferentBytesGetDifferentRevs() async throws {
        let server = FakeFTPServer()
        let (provider, accountId) = try makeProvider(server: server)

        server.setFile("personal.kdbx", data: Data("first".utf8), modified: "20260918120000")
        let first = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.setFile("personal.kdbx", data: Data("other".utf8), modified: "20260918120000")
        let second = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(first.size, second.size)
        XCTAssertEqual(first.modifiedDate, second.modifiedDate)
        XCTAssertNotEqual(first.rev, second.rev)
    }

    func testUploadConflictsOnASameSecondSameSizeRemoteWrite() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("first".utf8), modified: "20260918120000")
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("STOR") {
            server.setFile("personal.kdbx", data: Data("other".utf8), modified: "20260918120000")
        }

        await assertThrows(CloudProviderError.conflict(remoteRev: rev("other"))) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("mine!".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("other".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"], "the temporary upload must be cleaned up")
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("RNTO") })
    }

    func testFailedRevisionDownloadAbortsTheSave() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.overrideNextReply(to: "RETR", with: "425 Can't open data connection")

        await assertThrows(CloudProviderError.networkUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("RNTO") })
    }

    func testCancelledRevisionDownloadAbortsTheSave() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        let canceller = TaskCanceller()
        server.silentVerbs = ["RETR"]
        server.beforeNext("RETR") { canceller.cancel() }

        let upload = Task {
            try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        canceller.track(upload)

        do {
            _ = try await upload.value
            XCTFail("Expected the save to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("RNTO") })
    }

    // MARK: - Existence behind 550

    func testExistingFileBehindAnMLST550IsFoundThroughSIZE() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("database".utf8))
        server.overrideNextReply(to: "MLST", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, rev("database"))
        XCTAssertTrue(server.commandLog.contains("SIZE personal.kdbx"))
    }

    func testExistingFileBehindMLSTAndSIZE550IsFoundInTheListing() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("database".utf8))
        server.overrideNextReply(to: "MLST", with: "550 Permission denied")
        server.overrideNextReply(to: "SIZE", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, rev("database"))
        XCTAssertTrue(server.commandLog.contains("MLSD"))
    }

    func testUnverifiable550IsPermissionDeniedNotFileNotFound() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("database".utf8))
        server.overrideNextReply(to: "MLST", with: "550 Permission denied")
        server.overrideNextReply(to: "SIZE", with: "550 Permission denied")
        server.overrideNextReply(to: "MLSD", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        }
    }

    func testRefusedLISTFallbackCannotProveAbsence() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.overrideNextReply(to: "LIST", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/gone.kdbx")
        }
    }

    func testLISTCannotProveAHiddenNameAbsent() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/.hidden.kdbx")
        }
        XCTAssertTrue(server.commandLog.contains("LIST"))
    }

    func testCreateFileTreatsAnMLST550ForAnExistingFileAsTaken() async throws {
        let server = FakeFTPServer()
        server.setFile("taken.kdbx", data: Data("keep".utf8))
        server.overrideNextReply(to: "MLST", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.conflict(remoteRev: nil)) {
            _ = try await provider.createFile(accountId: accountId, path: "/taken.kdbx", data: Data("new".utf8)) { _ in }
        }
        XCTAssertEqual(server.file("taken.kdbx")?.data, Data("keep".utf8))
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("STOR") })
    }

    func testCreateFileNeverReplacesADatabaseHiddenBehindAnAmbiguous550() async throws {
        let server = FakeFTPServer()
        server.setFile("taken.kdbx", data: Data("keep".utf8))
        server.overrideNextReply(to: "MLST", with: "550 Permission denied")
        server.overrideNextReply(to: "SIZE", with: "550 Permission denied")
        server.overrideNextReply(to: "MLSD", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.createFile(accountId: accountId, path: "/taken.kdbx", data: Data("new".utf8)) { _ in }
        }
        XCTAssertEqual(server.file("taken.kdbx")?.data, Data("keep".utf8))
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("STOR") })
    }

    // MARK: - Upload

    func testUploadWritesATemporaryFileThenRenamesItOverTheDatabase() async throws {
        let server = FakeFTPServer()
        server.setFile("vaults/personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults/")
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        let after = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new bytes".utf8),
            expectedRev: before.rev
        ) { _ in }

        XCTAssertEqual(server.file("vaults/personal.kdbx")?.data, Data("new bytes".utf8))
        XCTAssertEqual(server.filePaths, ["vaults/personal.kdbx"])
        XCTAssertEqual(after.rev, rev("new bytes"))
        XCTAssertEqual(after.size, 9)
        let reread = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        XCTAssertEqual(reread.rev, after.rev, "the next save must not see its own write as a conflict")
        XCTAssertEqual(writeCommands(in: server), [
            "STOR vaults/\(uploadName)",
            "RNFR vaults/\(uploadName)",
            "RNTO vaults/personal.kdbx",
        ])
    }

    func testUploadRefusesWhenTheDatabaseChangedAfterExpectedRev() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("STOR") {
            server.setFile("personal.kdbx", data: Data("other device".utf8))
        }

        await assertThrows(CloudProviderError.conflict(remoteRev: rev("other device"))) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("mine".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("other device".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"], "the temporary upload must be cleaned up")
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("RNTO") })
    }

    func testFailedTransferLeavesTheDatabaseUntouched() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        server.overrideNextReply(to: "STOR", with: "552 Quota exceeded")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.insufficientSpace) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: nil
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertTrue(server.commandLog.contains("DELE \(uploadName)"), "a partial upload is removed too")
    }

    func testRejectedWriteIsPermissionDenied() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        server.overrideNextReply(to: "STOR", with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: nil
            ) { _ in }
        }
    }

    // MARK: - Replacement without rename-over (IIS)

    func testUploadSetsTheDatabaseAsideWhenRenameCannotReplace() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        let after = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: before.rev
        ) { _ in }

        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"], "neither the upload nor the backup may remain")
        XCTAssertEqual(after.rev, rev("new"))
        XCTAssertEqual(writeCommands(in: server), [
            "STOR \(uploadName)",
            "RNFR \(uploadName)",
            "RNTO personal.kdbx",
            "RNFR personal.kdbx",
            "RNTO \(backupName)",
            "RNFR \(uploadName)",
            "RNTO personal.kdbx",
            "DELE \(backupName)",
        ])
        XCTAssertTrue(server.commandLog.contains("RETR \(backupName)"), "the set-aside copy is re-checked")
    }

    func testFailedInstallRestoresTheOriginalDatabase() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("RETR", argument: backupName) {
            server.overrideNextReply(to: "RNTO", argument: "personal.kdbx", with: "550 Access denied")
        }

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
        XCTAssertTrue(server.commandLog.contains("RNFR \(backupName)"))
    }

    func testDroppedInstallIsRestoredOverAFreshConnection() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("RETR", argument: backupName) {
            server.dropConnection(onNext: "RNTO")
        }
        let controlConnectionsBefore = server.connectionLog.filter { $0 == "nas.local:21" }.count

        await assertThrows(CloudProviderError.networkUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
        XCTAssertEqual(server.connectionLog.filter { $0 == "nas.local:21" }.count, controlConnectionsBefore + 2)
    }

    /// The rename that sets the database aside can be carried out and still
    /// lose its reply. The database is then under the backup name with
    /// nothing at its own path, and only a reconciliation puts it back.
    func testLostSetAsideReplyPutsTheDatabaseBack() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        // Arm on the set-aside's own RNFR, so the refused install rename
        // before it is not the one that loses its reply.
        server.beforeNext("RNFR", argument: "personal.kdbx") {
            server.dropConnection(onNext: "RNTO", afterHandling: true)
        }

        await assertThrows(CloudProviderError.networkUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
    }

    func testLostInstallReplyKeepsTheBackupRatherThanReplacingTheUpload() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("RETR", argument: backupName) {
            server.dropConnection(onNext: "RNTO", afterHandling: true)
        }

        await assertThrows(CloudProviderError.networkUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
        XCTAssertEqual(server.file(backupName)?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths.sorted(), [backupName, "personal.kdbx"].sorted())
    }

    func testUnrestorableOriginalSurvivesUnderItsBackupName() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("RETR", argument: backupName) {
            for _ in 0..<3 {
                server.overrideNextReply(to: "RNTO", argument: "personal.kdbx", with: "550 Access denied")
            }
        }

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertNil(server.file("personal.kdbx"))
        XCTAssertEqual(server.file(backupName)?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, [backupName], "the upload is removed, the backup never")
        XCTAssertFalse(server.commandLog.contains("DELE \(backupName)"))
        XCTAssertFalse(server.commandLog.contains("STOR personal.kdbx"))
    }

    func testUploadConflictsWhenTheDatabaseChangesJustBeforeItIsSetAside() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("RNFR", argument: "personal.kdbx") {
            server.setFile("personal.kdbx", data: Data("other device".utf8))
        }

        await assertThrows(CloudProviderError.conflict(remoteRev: rev("other device"))) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("mine".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("other device".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
    }

    func testRefusedSetAsideLeavesTheDatabaseInPlace() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        server.overrideNextReply(to: "RNTO", argument: backupName, with: "550 Access denied")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.permissionDenied) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: nil
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
    }

    // MARK: - Temporary file cleanup

    func testFailedStatAfterTheTransferRemovesTheUpload() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.overrideNextReply(to: "MLST", with: "421 Service not available")

        await assertThrows(CloudProviderError.serviceUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
    }

    func testFailedRenameRemovesTheUpload() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        server.overrideNextReply(to: "RNFR", with: "450 File busy")
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.serviceUnavailable) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("new".utf8),
                expectedRev: nil
            ) { _ in }
        }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("old".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
    }

    func testFailedCleanupKeepsTheOriginalError() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("first".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.beforeNext("STOR") {
            server.setFile("personal.kdbx", data: Data("other".utf8))
        }
        server.overrideNextReply(to: "DELE", with: "550 Permission denied")

        await assertThrows(CloudProviderError.conflict(remoteRev: rev("other"))) {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("mine!".utf8),
                expectedRev: before.rev
            ) { _ in }
        }
        XCTAssertTrue(server.commandLog.contains("DELE \(uploadName)"))
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("other".utf8))
    }

    func testSaveSweepsOnlyStaleUploadLeftovers() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let stale = [
            ".personal.kdbx.20260916120000-DEADBEEF.keeforge-upload",
            ".work.kdbx.20260901000000-0badf00d.keeforge-upload",
        ]
        let kept = [
            ".personal.kdbx.20260918115000-12345678.keeforge-upload",
            ".personal.kdbx.20260901000000-DEADBEEF.keeforge-backup",
            ".personal.kdbx.DEADBEEF.keeforge-upload",
            ".personal.kdbx.20260901000000-NOTAHEX0.keeforge-upload",
            ".personal.kdbx.20270101000000-DEADBEEF.keeforge-upload",
            "..20260901000000-DEADBEEF.keeforge-upload",
            "personal.kdbx.20260901000000-DEADBEEF.keeforge-upload",
            ".hidden",
            "Archive/.personal.kdbx.20260901000000-DEADBEEF.keeforge-upload",
        ]
        for name in stale + kept {
            server.setFile(name, data: Data("x".utf8))
        }
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: before.rev
        ) { _ in }

        XCTAssertEqual(server.filePaths, (kept + ["personal.kdbx"]).sorted())
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
    }

    func testFailedSweepDoesNotFailTheSave() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let stale = ".personal.kdbx.20260901000000-DEADBEEF.keeforge-upload"
        server.setFile(stale, data: Data("x".utf8))
        server.overrideNextReply(to: "DELE", argument: stale, with: "550 Permission denied")
        let (provider, accountId) = try makeProvider(server: server)

        let after = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: nil
        ) { _ in }

        XCTAssertEqual(after.rev, rev("new"))
        XCTAssertEqual(server.filePaths, [stale, "personal.kdbx"].sorted())

        server.overrideNextReply(to: "MLSD", with: "550 Permission denied")
        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("newer".utf8),
            expectedRev: after.rev
        ) { _ in }
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("newer".utf8))
    }

    /// An install that could not be undone leaves the database only under its
    /// backup name (`testUnrestorableOriginalSurvivesUnderItsBackupName`).
    /// Some later database taking the freed name does not make that copy
    /// redundant, so occupancy must never license deleting it.
    func testStaleBackupSurvivesADifferentDatabaseTakingItsName() async throws {
        let server = FakeFTPServer()
        let orphaned = ".personal.kdbx.20260901000000-DEADBEEF.keeforge-backup"
        server.setFile(orphaned, data: Data("the only copy".utf8))
        server.setFile("personal.kdbx", data: Data("a different database".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: before.rev
        ) { _ in }

        XCTAssertEqual(server.file(orphaned)?.data, Data("the only copy".utf8))
        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
    }

    /// The delete right after a successful install is the only moment the
    /// backup is known to be redundant, so a refusal is retried there rather
    /// than left to a later sweep that could not tell it apart from the copy
    /// above.
    func testRefusedBackupDeletionIsRetriedOverAFreshConnection() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)
        let before = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
        server.overrideNextReply(to: "DELE", argument: backupName, with: "450 Busy")
        let controlConnectionsBefore = server.connectionLog.filter { $0 == "nas.local:21" }.count

        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: before.rev
        ) { _ in }

        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"], "the backup is gone after the retry")
        XCTAssertEqual(
            server.connectionLog.filter { $0 == "nas.local:21" }.count,
            controlConnectionsBefore + 2,
            "the save's own session plus one fresh session for the retry"
        )
    }

    func testScratchNamesRoundTripAndOnlyUploadsAreRecognized() throws {
        let created = try XCTUnwrap(FTPListingParser.date(fromTimeVal: "20260918120000"))
        let upload = FTPCloudProvider.scratchName(for: "a.b.kdbx", kind: .upload, createdAt: created, token: "0A1B2C3D")
        let backup = FTPCloudProvider.scratchName(for: "a.b.kdbx", kind: .backup, createdAt: created, token: "0A1B2C3D")

        XCTAssertEqual(upload, ".a.b.kdbx.20260918120000-0A1B2C3D.keeforge-upload")
        XCTAssertEqual(FTPCloudProvider.creationDate(ofUploadScratchNamed: upload), created)
        XCTAssertNil(FTPCloudProvider.creationDate(ofUploadScratchNamed: backup))
        XCTAssertNil(FTPCloudProvider.creationDate(ofUploadScratchNamed: "a.b.kdbx"))
    }

    // MARK: - Create

    func testCreateFileWritesANewDatabase() async throws {
        let server = FakeFTPServer()
        server.addDirectory("vaults")
        let stale = "vaults/.old.kdbx.20260901000000-DEADBEEF.keeforge-upload"
        server.setFile(stale, data: Data("x".utf8))
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults/")

        let created = try await provider.createFile(accountId: accountId, path: "new.kdbx", data: Data("kdbx".utf8)) { _ in }

        XCTAssertEqual(created.file.id, "/new.kdbx")
        XCTAssertEqual(created.file.name, "new.kdbx")
        XCTAssertEqual(created.metadata.size, 4)
        XCTAssertEqual(created.metadata.rev, rev("kdbx"))
        XCTAssertEqual(server.file("vaults/new.kdbx")?.data, Data("kdbx".utf8))
        XCTAssertEqual(server.filePaths, ["vaults/new.kdbx"], "the stale upload is swept after a create too")
    }

    func testCreateFileRefusesAnExistingNameWithoutUploading() async throws {
        let server = FakeFTPServer()
        server.setFile("taken.kdbx", data: Data("keep".utf8))
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.conflict(remoteRev: nil)) {
            _ = try await provider.createFile(accountId: accountId, path: "/taken.kdbx", data: Data("new".utf8)) { _ in }
        }
        XCTAssertEqual(server.file("taken.kdbx")?.data, Data("keep".utf8))
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("STOR") })
    }

    func testCreateFileRefusesANameThatAppearsDuringTheUpload() async throws {
        let server = FakeFTPServer()
        let (provider, accountId) = try makeProvider(server: server)
        server.beforeNext("STOR") {
            server.setFile("race.kdbx", data: Data("other device".utf8))
        }

        await assertThrows(CloudProviderError.conflict(remoteRev: nil)) {
            _ = try await provider.createFile(accountId: accountId, path: "/race.kdbx", data: Data("new".utf8)) { _ in }
        }
        XCTAssertEqual(server.file("race.kdbx")?.data, Data("other device".utf8))
        XCTAssertEqual(server.filePaths, ["race.kdbx"], "the temporary upload must be cleaned up")
    }

    // MARK: - Transport and safety

    func testUnresponsiveServerTimesOutAsOffline() async throws {
        let server = FakeFTPServer()
        server.silentVerbs = ["MLST"]
        server.setFile("personal.kdbx", data: Data("x".utf8))
        let (provider, accountId) = try makeProvider(server: server, timeout: .milliseconds(200))

        do {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? CloudProviderError, .networkUnavailable)
            XCTAssertTrue(CloudProviderError.isLikelyOffline(error))
        }
    }

    func testRefusedConnectionIsNetworkUnavailable() async throws {
        let server = FakeFTPServer()
        server.refusesConnections = true
        let (provider, accountId) = try makeProvider(server: server)

        await assertThrows(CloudProviderError.networkUnavailable) {
            _ = try await provider.listFiles(accountId: accountId, path: nil, query: nil, includesAllFiles: false)
        }
    }

    func testLineBreakInFileNameNeverReachesTheServer() async throws {
        let server = FakeFTPServer()
        let (provider, accountId) = try makeProvider(server: server)

        for lineBreak in ["\r\n", "\n", "\r"] {
            await assertThrows(CloudProviderError.invalidName) {
                _ = try await provider.getMetadata(accountId: accountId, fileId: "/x.kdbx\(lineBreak)DELE personal.kdbx")
            }
        }
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("DELE") })
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("MLST") })
    }

    @MainActor
    func testReconnectExplainsHowToAddTheServerAgain() async {
        let provider = FTPCloudProvider(client: FakeFTPServer().makeClient())

        do {
            _ = try await provider.authenticate(from: ASPresentationAnchor())
            XCTFail("FTP has no hosted sign-in")
        } catch {
            XCTAssertEqual(
                error as? CloudProviderError,
                .unknown("Reconnect by adding the FTP server again with its address, username, and password.")
            )
        }
    }

    func testMissingCredentialIsNotAuthenticated() async {
        let provider = FTPCloudProvider(client: FakeFTPServer().makeClient())

        await assertThrows(CloudProviderError.notAuthenticated) {
            _ = try await provider.listFiles(accountId: "ftp-missing", path: nil, query: nil, includesAllFiles: false)
        }
    }

    // MARK: - Helpers

    private func configuration(
        serverURL: String = "ftp://nas.local/",
        password: String = "secret",
        allowsUnencryptedFTP: Bool = true
    ) -> FTPConnectionConfiguration {
        FTPConnectionConfiguration(
            serverURL: serverURL,
            username: "alex",
            password: password,
            allowsUnencryptedFTP: allowsUnencryptedFTP
        )
    }

    /// Scratch names the provider below produces for `personal.kdbx`.
    private let uploadName = ".personal.kdbx.20260918120000-0000CAFE.keeforge-upload"
    private let backupName = ".personal.kdbx.20260918120000-0000CAFE.keeforge-backup"

    /// A provider with a seeded credential for `baseURL`, a clock fixed at
    /// 2026-09-18 12:00 UTC, a fixed scratch token, and `server` as its only
    /// reachable host.
    private func makeProvider(
        server: FakeFTPServer,
        baseURL: String = "ftp://nas.local/",
        timeout: Duration = .seconds(5)
    ) throws -> (FTPCloudProvider, String) {
        let normalized = try FTPURL.normalizedBaseURL(from: baseURL, allowsUnencryptedFTP: true)
        let accountId = FTPURL.accountId(normalizedBaseURL: normalized, username: "alex")
        let credential = FTPCredential(serverURL: normalized.absoluteString, username: "alex", password: "secret")
        guard CloudTokenStore.setTokenData(try JSONEncoder().encode(credential), provider: providerId, accountId: accountId) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        seededAccountIds.append(accountId)

        let now = try XCTUnwrap(FTPListingParser.date(fromTimeVal: "20260918120000"))
        let provider = FTPCloudProvider(
            client: server.makeClient(timeout: timeout),
            now: { now },
            makeScratchToken: { "0000CAFE" }
        )
        return (provider, accountId)
    }

    private func rev(_ text: String) -> String {
        FTPCloudProvider.rev(of: Data(text.utf8))
    }

    /// The commands that write, move, or delete, in order.
    private func writeCommands(in server: FakeFTPServer) -> [String] {
        server.commandLog.filter { ["STOR", "RNFR", "RNTO", "DELE"].contains($0.prefix(4)) }
    }

    private func skipIfKeychainUnavailable() throws {
        let probeId = "ftp-keychain-probe"
        guard CloudTokenStore.setTokenData(Data("x".utf8), provider: providerId, accountId: probeId) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        _ = CloudTokenStore.deleteToken(provider: providerId, accountId: probeId)
    }

    private func assertThrows(
        _ expected: CloudProviderError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CloudProviderError, expected, file: file, line: line)
        }
    }
}

/// Cancels a task from a server hook that may run before the test has the
/// task in hand.
private final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<CloudFileMetadata, Error>?
    private var requested = false

    func track(_ task: Task<CloudFileMetadata, Error>) {
        let cancelNow = lock.withLock {
            self.task = task
            return requested
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            requested = true
            return self.task
        }
        task?.cancel()
    }
}
