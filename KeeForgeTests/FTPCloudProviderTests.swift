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

        let files = try await provider.listFiles(accountId: accountId, path: nil, query: nil)

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

        let files = try await provider.listFiles(accountId: accountId, path: "/Team Vaults", query: nil)

        XCTAssertEqual(files.map(\.id), ["/Team Vaults/shared vault.kdbx"])
        XCTAssertEqual(files.first?.size, 3072)
        XCTAssertTrue(server.commandLog.contains("CWD Team Vaults"))
        XCTAssertTrue(server.commandLog.contains("LIST"))
        XCTAssertTrue(
            server.connectionLog.dropFirst().allSatisfy { $0.hasPrefix("nas.local:") },
            "PASV advertised 10.9.8.7; data connections must still go to the control host: \(server.connectionLog)"
        )
    }

    func testListFilesFiltersByQuery() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data("p".utf8))
        server.setFile("work.kdbx", data: Data("w".utf8))
        let (provider, accountId) = try makeProvider(server: server)

        let files = try await provider.listFiles(accountId: accountId, path: "/", query: " WORK ")

        XCTAssertEqual(files.map(\.name), ["work.kdbx"])
    }

    // MARK: - Download and metadata

    func testDownloadWritesTheRemoteBytesAndReportsNoMetadata() async throws {
        let server = FakeFTPServer()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        server.setFile("vaults/personal.kdbx", data: payload)
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("personal.kdbx")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let metadata = try await provider.download(accountId: accountId, fileId: "/personal.kdbx", to: destination) { _ in }

        XCTAssertNil(metadata)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(server.commandLog.contains("RETR vaults/personal.kdbx"))
    }

    func testGetMetadataUsesModificationStampAndSizeAsRev() async throws {
        let server = FakeFTPServer()
        server.setFile("personal.kdbx", data: Data(count: 42), modified: "20260918120001")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, "mtime:20260918120001;size:42")
        XCTAssertEqual(metadata.size, 42)
        XCTAssertEqual(metadata.modifiedDate, FTPListingParser.date(fromTimeVal: "20260918120001"))
    }

    func testGetMetadataFallsBackToSIZEAndMDTMWithTheSameRev() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.setFile("personal.kdbx", data: Data(count: 42), modified: "20260918120001")
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertEqual(metadata.rev, "mtime:20260918120001;size:42")
        XCTAssertTrue(server.commandLog.contains("SIZE personal.kdbx"))
        XCTAssertTrue(server.commandLog.contains("MDTM personal.kdbx"))
    }

    func testGetMetadataWithoutModificationTimeHasNoRev() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.supportsModificationTime = false
        server.setFile("personal.kdbx", data: Data(count: 42))
        let (provider, accountId) = try makeProvider(server: server)

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/personal.kdbx")

        XCTAssertNil(metadata.rev)
        XCTAssertEqual(metadata.size, 42)
    }

    func testGetMetadataForMissingFileIsFileNotFound() async throws {
        let (provider, accountId) = try makeProvider(server: FakeFTPServer())

        await assertThrows(CloudProviderError.fileNotFound) {
            _ = try await provider.getMetadata(accountId: accountId, fileId: "/gone.kdbx")
        }
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
        XCTAssertNotNil(after.rev)
        XCTAssertNotEqual(after.rev, before.rev)
        XCTAssertEqual(after.size, 9)
        let writes = server.commandLog.filter { ["STOR", "RNFR", "RNTO"].contains($0.prefix(4)) }
        XCTAssertEqual(writes, [
            "STOR vaults/.personal.kdbx.tmp.keeforge-upload",
            "RNFR vaults/.personal.kdbx.tmp.keeforge-upload",
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

        do {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/personal.kdbx",
                data: Data("mine".utf8),
                expectedRev: before.rev
            ) { _ in }
            XCTFail("Expected a conflict")
        } catch let CloudProviderError.conflict(remoteRev) {
            let current = try XCTUnwrap(server.file("personal.kdbx"))
            XCTAssertEqual(remoteRev, "mtime:\(current.modified);size:12")
        }

        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("other device".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"], "the temporary upload must be cleaned up")
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("RNTO") })
    }

    func testUploadFallsBackToWritingInPlaceWhenRenameCannotReplace() async throws {
        let server = FakeFTPServer()
        server.renameReplacesExisting = false
        server.setFile("personal.kdbx", data: Data("old".utf8))
        let (provider, accountId) = try makeProvider(server: server)

        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/personal.kdbx",
            data: Data("new".utf8),
            expectedRev: nil
        ) { _ in }

        XCTAssertEqual(server.file("personal.kdbx")?.data, Data("new".utf8))
        XCTAssertEqual(server.filePaths, ["personal.kdbx"])
        XCTAssertFalse(server.commandLog.contains("DELE personal.kdbx"), "the database must never be deleted first")
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

    // MARK: - Create

    func testCreateFileWritesANewDatabase() async throws {
        let server = FakeFTPServer()
        server.addDirectory("vaults")
        let (provider, accountId) = try makeProvider(server: server, baseURL: "ftp://nas.local/vaults/")

        let created = try await provider.createFile(accountId: accountId, path: "new.kdbx", data: Data("kdbx".utf8)) { _ in }

        XCTAssertEqual(created.file.id, "/new.kdbx")
        XCTAssertEqual(created.file.name, "new.kdbx")
        XCTAssertEqual(created.metadata.size, 4)
        XCTAssertNotNil(created.metadata.rev)
        XCTAssertEqual(server.file("vaults/new.kdbx")?.data, Data("kdbx".utf8))
        XCTAssertEqual(server.filePaths, ["vaults/new.kdbx"])
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
            _ = try await provider.listFiles(accountId: accountId, path: nil, query: nil)
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
            _ = try await provider.listFiles(accountId: "ftp-missing", path: nil, query: nil)
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

    /// A provider with a seeded credential for `baseURL`, a fixed temporary
    /// upload name, and `server` as its only reachable host.
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

        let provider = FTPCloudProvider(
            client: server.makeClient(timeout: timeout),
            makeTemporaryName: { ".\($0).tmp.keeforge-upload" }
        )
        return (provider, accountId)
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
