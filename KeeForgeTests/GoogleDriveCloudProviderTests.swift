#if os(iOS)
@preconcurrency import AppAuth
import AuthenticationServices
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class GoogleDriveCloudProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
        DatabaseListStore.clearAll()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testAppAuthRequestsOnlyDriveFileAndUsesPKCE() throws {
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: "synthetic.apps.googleusercontent.com",
            scheme: "com.googleusercontent.apps.synthetic"))
        let request = try GoogleDriveAuthorization.authorizationRequest(configuration: configuration, fileID: "fixture-file")
        XCTAssertEqual(request.scope, "https://www.googleapis.com/auth/drive.file")
        XCTAssertEqual(request.redirectURL?.scheme, "com.googleusercontent.apps.synthetic")
        XCTAssertEqual(request.codeChallengeMethod, "S256")
        XCTAssertNotNil(request.codeVerifier)
        XCTAssertNotNil(request.state)
        XCTAssertEqual(request.additionalParameters?["prompt"], "consent")
        XCTAssertEqual(request.additionalParameters?["trigger_onepick"], "true")
        XCTAssertEqual(request.additionalParameters?["file_ids"], "fixture-file")
    }

    func testSelectReconnectAndDownloadTheSameFile() async throws {
        let bytes = Data("synthetic remote".utf8)
        let transport = DriveTransport([
            .json(["user": ["permissionId": "test-account"]]), try .file(bytes, revision: "base"),
            try .file(bytes, revision: "base"), .body(bytes),
            .json(["user": ["permissionId": "test-account"]]), try .file(bytes, revision: "base"),
        ])
        let vault = DriveTestCredentials()
        let provider = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, expected in
            if let expected { XCTAssertEqual(expected, "fixture-file") }
            return DriveTestCredentials.grant()
        }), transport: transport)
        let selection = try await provider.selectDatabase(from: ASPresentationAnchor())
        XCTAssertEqual(selection.file.id, "fixture-file")
        XCTAssertEqual(selection.account.id, "test-account")
        XCTAssertEqual(vault.archive(for: selection.account.id), Data([1]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await provider.download(accountId: selection.account.id, fileId: selection.file.id, to: url) { _ in }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(result?.rev, "base")
        var reference = try registerDriveReference(bytes: bytes)
        reference.updateCloudSyncMetadata { $0.lastSyncIssue = .notAuthenticated }
        DatabaseListStore.testUpsert(reference)
        let reconnected = try await provider.reconnect(from: ASPresentationAnchor(), reference: reference)
        XCTAssertEqual(reconnected.cloudSyncMetadata?.fileId, reference.cloudSyncMetadata?.fileId)
        XCTAssertNil(reconnected.cloudSyncMetadata?.lastSyncIssue)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/drive/v3/about", "/drive/v3/files/fixture-file", "/drive/v3/files/fixture-file",
            "/drive/v3/files/fixture-file", "/drive/v3/about", "/drive/v3/files/fixture-file",
        ])
        XCTAssertEqual(requests[3].url?.query, "alt=media")
    }

    func testReconnectRefusesAnotherAccountAndAnotherFile() async throws {
        let reference = try registerDriveReference(bytes: .init())
        let expected = try XCTUnwrap(reference.cloudSyncMetadata)
        let vault = DriveTestCredentials()
        let transport = DriveTransport([.json(["user": ["permissionId": "other-account"]])])
        let sameFile = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, _ in
            DriveTestCredentials.grant()
        }), transport: transport)
        await assertIssue(.permissionDenied) {
            _ = try await sameFile.selectDatabase(from: ASPresentationAnchor(), reconnecting: expected)
        }
        let otherFile = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, _ in
            DriveTestCredentials.grant(fileID: "different-file")
        }), transport: transport)
        await assertIssue(.permissionDenied) {
            _ = try await otherFile.selectDatabase(from: ASPresentationAnchor(), reconnecting: expected)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(vault.archive(for: "other-account"))
        XCTAssertNil(vault.archive(for: "test-account"))
        XCTAssertTrue(CloudAccountStore.accounts.isEmpty)
    }

    func testOAuthCancellationAndLateCallbackAfterClosingTheSheet() async throws {
        let vault = DriveTestCredentials()
        let transport = DriveTransport([])
        let cancelled = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, _ in
            throw NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.userCanceledAuthorizationFlow.rawValue)
        }), transport: transport)
        await assertIssue(.authenticationCancelled) {
            _ = try await cancelled.selectDatabase(from: ASPresentationAnchor())
        }
        let latch = DriveGrantLatch()
        let provider = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, _ in
            await latch.grant()
        }), transport: transport)
        let pending = Task { try await provider.selectDatabase(from: ASPresentationAnchor()) }
        await latch.waitUntilStarted()
        provider.cancelPendingAuthentication()
        latch.resume()
        await assertIssue(.authenticationCancelled) { _ = try await pending.value }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(vault.archive(for: "test-account"))
    }

    func testLateCallbackAfterSignOutCannotReviveTheAccount() async throws {
        let vault = DriveTestCredentials()
        try vault.seed()
        let latch = DriveGrantLatch()
        let base = Data("base".utf8)
        let transport = DriveTransport([
            .json(["user": ["permissionId": "test-account"]]), try .file(base, revision: "base"),
        ])
        let provider = GoogleDriveCloudProvider(authorization: try vault.authorization(present: { _, _, _ in
            await latch.grant()
        }), transport: transport)
        let pending = Task { try await provider.selectDatabase(from: ASPresentationAnchor()) }
        await latch.waitUntilStarted()
        provider.signOut(accountId: "test-account")
        latch.resume()
        await assertIssue(.notAuthenticated) { _ = try await pending.value }
        XCTAssertFalse(provider.isAuthenticated(accountId: "test-account"))
        XCTAssertNil(vault.archive(for: "test-account"))
        XCTAssertTrue(CloudAccountStore.accounts.isEmpty)
    }

    func testRefreshStoresTheNewArchiveAndRevocationAloneClearsIt() async throws {
        let vault = DriveTestCredentials()
        try vault.seed()
        let refresh = try vault.authorization(refresh: { _, _ in
            GoogleDriveToken(accessToken: "refreshed-test-token", archive: Data([2]))
        })
        let token = try await refresh.accessToken(accountID: "test-account")
        XCTAssertEqual(token, "refreshed-test-token")
        XCTAssertEqual(vault.archive(for: "test-account"), Data([2]))
        let offline = try vault.authorization(refresh: { _, _ in throw URLError(.notConnectedToInternet) })
        await assertIssue(.networkUnavailable) { _ = try await offline.accessToken(accountID: "test-account") }
        XCTAssertEqual(vault.archive(for: "test-account"), Data([2]))
        let revoked = try vault.authorization(refresh: { _, _ in
            throw NSError(domain: OIDOAuthTokenErrorDomain, code: OIDErrorCodeOAuthToken.invalidGrant.rawValue)
        })
        await assertIssue(.notAuthenticated) { _ = try await revoked.accessToken(accountID: "test-account") }
        XCTAssertNil(vault.archive(for: "test-account"))
    }

    func testMultipartWritesOnlyAfterMatchingPreflightAndChecksPaginatedHistory() async throws {
        let initial = Data("old document".utf8)
        let saved = Data("new document".utf8)
        let fixture = try DriveTransport.Reply.file(saved, revision: "our-write")
        let transport = DriveTransport([
            try .file(initial, revision: "base"), try .file(initial, revision: "base"), fixture,
            .json(["revisions": [["id": "base"]], "nextPageToken": "next"]),
            .json(["revisions": [["id": "our-write"]]]), fixture,
        ])
        let provider = try authenticatedProvider(transport)
        let observed = try await provider.getMetadata(accountId: "test-account", fileId: "fixture-file")
        let result = try await provider.upload(accountId: "test-account", fileId: "fixture-file", data: saved, observed: observed) { _ in }
        XCTAssertEqual(result.rev, "our-write")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "PATCH", "GET", "GET", "GET"])
        XCTAssertTrue(requests[2].url?.query?.contains("uploadType=multipart") == true)
        XCTAssertTrue(requests[2].httpBody?.range(of: saved) != nil)
        XCTAssertTrue(requests[4].url?.query?.contains("pageToken=next") == true)
    }

    func testChecksumMismatchWithSameRevisionPreventsTheWrite() async throws {
        let transport = DriveTransport([
            try .file(Data([1]), revision: "base"), try .file(Data([2]), revision: "base"),
        ])
        let provider = try authenticatedProvider(transport)
        let observed = try await provider.getMetadata(accountId: "test-account", fileId: "fixture-file")
        await assertIssue(.conflict) {
            _ = try await provider.upload(accountId: "test-account", fileId: "fixture-file", data: Data([3]), observed: observed) { _ in }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    }

    func testResumableTransferUsesOnlyTheSameSession() async throws {
        let bytes = Data(repeating: 3, count: 5_000_001)
        let fixture = try DriveTransport.Reply.file(bytes, revision: "our-write")
        let transport = DriveTransport([
            try .file(Data([1]), revision: "base"), try .file(Data([1]), revision: "base"),
            .body(.init(), headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files/fixture-file?upload_id=synthetic"]),
            .body(.init(), status: 308, headers: ["Range": "bytes=0-262143"]),
            fixture, .json(["revisions": [["id": "base"], ["id": "our-write"]]]), fixture,
        ])
        let provider = try authenticatedProvider(transport)
        let observed = try await provider.getMetadata(accountId: "test-account", fileId: "fixture-file")
        _ = try await provider.upload(accountId: "test-account", fileId: "fixture-file", data: bytes, observed: observed) { _ in }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "PATCH", "PUT", "PUT", "GET", "GET"])
        XCTAssertTrue(requests[2].url?.query?.contains("uploadType=resumable") == true)
        XCTAssertEqual(requests[3].url, requests[4].url)
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Content-Range"), "bytes 262144-5000000/5000001")
    }

    func testConflictCopyCreatesANewDriveFileThroughTheCreationJournal() async throws {
        let bytes = Data("conflict ciphertext".utf8)
        let name = "Fixture (conflict).kdbx"
        let reference = try registerDriveReference(bytes: bytes)
        let receipt = try DriveTransport.Reply.file(bytes, revision: "copy-revision", id: "new-copy", name: name)
        let transport = DriveTransport([receipt])
        let provider = try authenticatedProvider(transport)
        try await DatabaseViewModel.writeConflictCopyToCloud(reference: reference, fileID: name, bytes: bytes,
                                                            providerResolver: { _ in provider })
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        XCTAssertEqual(requests.first?.url?.path, "/upload/drive/v3/files")
        let body = try XCTUnwrap(requests.first?.httpBody)
        XCTAssertTrue(body.range(of: bytes) != nil)
        XCTAssertTrue(body.range(of: Data(name.utf8)) != nil)
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [reference.id])
        let creations = try PendingUploadQueue.listCreations()
        XCTAssertEqual(creations.first?.intent.phase, .completed)
        XCTAssertEqual(creations.first?.intent.receipt?.cloudSyncMetadata?.fileId, "new-copy")
    }

    func testDrainerPreservesDurableCiphertextAcrossEveryPostDispatchOutcome() async throws {
        for issue: CloudSyncIssue in [.postUploadConflict, .uploadResponseLost, .uploadVerificationIncomplete] {
            let base = Data("base ciphertext".utf8)
            let payload = Data("saved ciphertext".utf8)
            let reference = try registerDriveReference(bytes: base)
            let context = try CloudJournalTestContext(reference: reference, base: base, payload: payload)
            var replies: [DriveTransport.Reply] = [try .file(base, revision: "base"), try .file(base, revision: "base")]
            if issue == .uploadResponseLost {
                replies.append(.lost)
            } else {
                replies.append(try .file(payload, revision: "our-write"))
                let history = issue == .postUploadConflict ? ["base", "other-write", "our-write"] : ["our-write"]
                replies.append(.json(["revisions": history.map { ["id": $0] }]))
            }
            let transport = DriveTransport(replies)
            let provider = try authenticatedProvider(transport)
            var saver = context.environment()
            saver.getMetadata = { _ in try await provider.getMetadata(accountId: "test-account", fileId: "fixture-file") }
            saver.uploadObserved = { _, data, observed in
                try await provider.upload(accountId: "test-account", fileId: "fixture-file", data: data, observed: observed) { _ in }
            }
            saver.upload = { _, _, _, _ in throw CloudProviderError.invalidConfiguration }
            saver.revisionIdentifiesContent = { _, _ in true }
            let environment = context.drainerEnvironment(saver: saver)
            let result = await PendingUploadDrainer(environment: environment).drain(databaseId: reference.id)
            XCTAssertTrue(result.drainedDatabaseIDs.isEmpty)
            let stored = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertEqual(stored.marker.uploadRecoveryIssue, issue)
            XCTAssertEqual(stored.marker.observedUploadRevision, issue == .uploadResponseLost ? nil : "our-write")
            XCTAssertNil(stored.marker.confirmedAt)
            XCTAssertEqual(stored.marker.attemptIsFenced, false)
            XCTAssertEqual(CloudJournalDecision.driveUploadRecoveryIssue(for: stored.marker), issue)
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(stored), payload)
            XCTAssertEqual(try Data(contentsOf: context.cacheURL), payload)
            let nextPass = await PendingUploadDrainer(environment: environment).drain(databaseId: reference.id)
            XCTAssertTrue(nextPass.drainedDatabaseIDs.isEmpty)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "PATCH" }.count, 1)
        }
    }

    private func authenticatedProvider(_ transport: DriveTransport) throws -> GoogleDriveCloudProvider {
        let vault = DriveTestCredentials()
        try vault.seed()
        return GoogleDriveCloudProvider(authorization: try vault.authorization(), transport: transport)
    }

    private func registerDriveReference(bytes: Data) throws -> DatabaseReference {
        var reference = try DatabaseListStore.addCloud(provider: "googledrive", accountId: "test-account",
            file: CloudFile(id: "fixture-file", name: "Fixture.kdbx", path: "Fixture.kdbx", isFolder: false,
                modifiedDate: .now, size: Int64(bytes.count)))
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "base"
            metadata.remoteContentHash = DriveTransport.md5(bytes)
        }
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    private func assertIssue(_ issue: CloudSyncIssue, _ operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected failure", file: file, line: line)
        } catch {
            XCTAssertEqual(CloudProviderError.issue(for: error), issue, file: file, line: line)
        }
    }
}

@MainActor
final class DriveTestCredentials {
    private final class Archives: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [String: Data] = [:]

        func read(_ id: String) -> Data? { lock.withLock { data[id] } }
        func write(_ bytes: Data?, for id: String) { lock.withLock { data[id] = bytes } }
    }

    private let archives = Archives()
    private lazy var store = GoogleDriveCredentialStore(
        read: { [archives] in archives.read($0) },
        write: { [archives] data, id in archives.write(data, for: id); return true },
        delete: { [archives] id in archives.write(nil, for: id); return true })

    func archive(for id: String) -> Data? { archives.read(id) }

    func seed() throws {
        guard store.saveAuthorization(Data([1]), accountID: "test-account", expectedLifetime: nil,
                                      authorizationGeneration: store.authorizationGeneration, registered: {}) else {
            throw CloudProviderError.notAuthenticated
        }
    }

    func authorization(present: GoogleDriveAuthorization.Present? = nil,
                       refresh: @escaping GoogleDriveAuthorization.Refresh = { data, _ in
                           GoogleDriveToken(accessToken: "synthetic-token", archive: data)
                       }) throws -> GoogleDriveAuthorization {
        let configuration = try XCTUnwrap(GoogleDriveConfiguration(clientID: "synthetic.apps.googleusercontent.com",
            scheme: "com.googleusercontent.apps.synthetic"))
        return GoogleDriveAuthorization(configuration: configuration, credentials: store, present: present, refresh: refresh)
    }

    nonisolated static func grant(fileID: String = "fixture-file") -> GoogleDriveAuthorization.Grant {
        GoogleDriveAuthorization.Grant(token: GoogleDriveToken(accessToken: "synthetic-token", archive: Data([1])), fileID: fileID)
    }
}

@MainActor
private final class DriveGrantLatch {
    private var pending: CheckedContinuation<GoogleDriveAuthorization.Grant, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func grant() async -> GoogleDriveAuthorization.Grant {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func resume() {
        pending?.resume(returning: DriveTestCredentials.grant())
        pending = nil
    }
}

actor DriveTransport: GoogleDriveTransport {
    enum Reply: Sendable {
        case body(Data, status: Int = 200, headers: [String: String] = [:])
        case lost

        static func json(_ value: [String: Any]) -> Self {
            .body((try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }

        static func file(_ bytes: Data, revision: String, id: String = "fixture-file", name: String = "Fixture.kdbx") throws -> Self {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": id, "name": name, "mimeType": "application/octet-stream",
                "modifiedTime": "2026-03-01T00:00:00.000Z", "size": String(bytes.count), "headRevisionId": revision,
                "md5Checksum": DriveTransport.md5(bytes),
                "capabilities": ["canModifyContent": true, "canDownload": true, "canReadRevisions": true],
            ])
            return .body(data)
        }
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw CloudProviderError.invalidConfiguration }
        switch replies.removeFirst() {
        case .lost: throw URLError(.networkConnectionLost)
        case let .body(body, status, headers):
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
            return (body, response)
        }
    }

    nonisolated static func md5(_ bytes: Data) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
