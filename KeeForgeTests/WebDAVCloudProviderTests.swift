import XCTest
@testable import KeeForge

/// Tests for `WebDAVCloudProvider` and its URL/rev helper statics, plus
/// provider behaviors driven by a stubbed-transport `WebDAVClient`.
///
/// Credential-dependent tests seed `CloudTokenStore` directly under a unique
/// accountId and clean up in `tearDown`; if Keychain writes are unavailable in
/// the test host they `XCTSkip` (matching `CloudTokenStoreTests`).
final class WebDAVCloudProviderTests: XCTestCase {
    private let providerId = CloudProviderKind.webDAV.rawValue
    private var seededAccountIds: [String] = []

    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        for accountId in seededAccountIds {
            _ = CloudTokenStore.deleteToken(provider: providerId, accountId: accountId)
        }
        seededAccountIds = []
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    // MARK: - URL normalization

    func testNormalizedBaseURLAddsTrailingSlash() throws {
        let url = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/remote.php/dav")
        XCTAssertEqual(url.absoluteString, "https://cloud.example.com/remote.php/dav/")
    }

    func testNormalizedBaseURLLowercasesSchemeAndHostPreservesPathCase() throws {
        let url = try WebDAVURL.normalizedBaseURL(from: "HTTPS://Cloud.EXAMPLE.com/Remote.PHP/DAV/Files/")
        XCTAssertEqual(url.absoluteString, "https://cloud.example.com/Remote.PHP/DAV/Files/")
    }

    func testNormalizedBaseURLDropsDefault443KeepsCustomPort() throws {
        let dropped = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com:443/dav")
        XCTAssertEqual(dropped.absoluteString, "https://cloud.example.com/dav/")

        let kept = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com:8443/dav")
        XCTAssertEqual(kept.absoluteString, "https://cloud.example.com:8443/dav/")
    }

    func testNormalizedBaseURLRejectsHTTP() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "http://cloud.example.com/dav")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .insecureScheme)
        }
    }

    func testNormalizedBaseURLRejectsEmpty() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "   ")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .empty)
        }
    }

    func testNormalizedBaseURLRejectsGarbageAndMissingHost() {
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "not a url ::::")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .malformed)
        }
        // Scheme present but no host.
        XCTAssertThrowsError(try WebDAVURL.normalizedBaseURL(from: "https:///dav")) { error in
            XCTAssertEqual(error as? WebDAVURLError, .missingHost)
        }
    }

    // MARK: - accountId

    func testAccountIdIsStableAndSecretFree() throws {
        let base = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/dav/")
        let first = WebDAVURL.accountId(normalizedBaseURL: base, username: "alice")
        let second = WebDAVURL.accountId(normalizedBaseURL: base, username: "alice")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("webdav-"))
        XCTAssertGreaterThanOrEqual(first.count, 32 + 7)
        // Secret-free: no host / username substrings leak into the hex digest.
        // (Inspect the part after the "webdav-" prefix so the literal "dav" in the
        // prefix doesn't trip the check.)
        let digest = String(first.dropFirst("webdav-".count))
        XCTAssertFalse(digest.contains("cloud.example.com"))
        XCTAssertFalse(digest.contains("alice"))
        XCTAssertFalse(digest.contains("example"))
    }

    func testAccountIdDiffersByUsernameAndBaseURL() throws {
        let baseA = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/dav/")
        let baseB = try WebDAVURL.normalizedBaseURL(from: "https://other.example.com/dav/")

        let alice = WebDAVURL.accountId(normalizedBaseURL: baseA, username: "alice")
        let bob = WebDAVURL.accountId(normalizedBaseURL: baseA, username: "bob")
        let aliceOtherHost = WebDAVURL.accountId(normalizedBaseURL: baseB, username: "alice")

        XCTAssertNotEqual(alice, bob)
        XCTAssertNotEqual(alice, aliceOtherHost)
    }

    // MARK: - fileId ↔ URL round-trip

    func testFileIdURLRoundTripNestedSpacesUnicodePlus() throws {
        // A root base URL makes `serverRelativePath(from: url.path)` a true inverse
        // of `url(forFileId:)` (no base path prefix to strip).
        let base = try XCTUnwrap(URL(string: "https://host.example.com/"))
        let fileIds = [
            "/Vaults/personal.kdbx",
            "/Vaults/My Passwörter.kdbx",
            "/deeply/nested/folder/vault.kdbx",
            "/a+b/c+d.kdbx",
        ]
        for fileId in fileIds {
            let url = WebDAVCloudProvider.url(forFileId: fileId, base: base)
            let roundTrip = WebDAVCloudProvider.serverRelativePath(from: url.path)
            XCTAssertEqual(roundTrip, fileId, "Round-trip failed for \(fileId): url=\(url.absoluteString)")
        }
    }

    func testFolderPathURLResolution() throws {
        let base = try XCTUnwrap(URL(string: "https://host.example.com/dav/"))

        XCTAssertEqual(WebDAVCloudProvider.url(forFolderPath: nil, base: base), base)
        XCTAssertEqual(WebDAVCloudProvider.url(forFolderPath: "/", base: base), base)

        let sub = WebDAVCloudProvider.url(forFolderPath: "/Vaults", base: base)
        XCTAssertTrue(sub.absoluteString.hasSuffix("/Vaults/"), "Subfolder should get a trailing slash: \(sub.absoluteString)")
    }

    // MARK: - rev semantics

    func testRevPrefersStrongETagVerbatim() {
        let response = makeResponse(eTag: "\"strong\"", ocETag: "\"oc\"", lastModified: "Tue, 01 Jul 2025 10:20:30 GMT")
        XCTAssertEqual(WebDAVCloudProvider.rev(from: response), "\"strong\"")
    }

    func testRevFallsBackToOCETagWhenETagAbsent() {
        let response = makeResponse(eTag: nil, ocETag: "\"oc-value\"", lastModified: "Tue, 01 Jul 2025 10:20:30 GMT")
        XCTAssertEqual(WebDAVCloudProvider.rev(from: response), "\"oc-value\"")
    }

    func testRevFallsBackToLastmodWhenNoETag() {
        let response = makeResponse(eTag: nil, ocETag: nil, lastModified: "Tue, 01 Jul 2025 10:20:30 GMT")
        XCTAssertEqual(WebDAVCloudProvider.rev(from: response), "lastmod:Tue, 01 Jul 2025 10:20:30 GMT")
    }

    func testRevNilWhenNeitherPresent() {
        let response = makeResponse(eTag: nil, ocETag: nil, lastModified: nil)
        XCTAssertNil(WebDAVCloudProvider.rev(from: response))
    }

    func testStrongIfMatchValue() {
        XCTAssertEqual(WebDAVCloudProvider.strongIfMatchValue(from: "\"strong\""), "\"strong\"")
        XCTAssertNil(WebDAVCloudProvider.strongIfMatchValue(from: "W/\"weak\""))
        XCTAssertNil(WebDAVCloudProvider.strongIfMatchValue(from: "lastmod:Tue, 01 Jul 2025 10:20:30 GMT"))
        XCTAssertNil(WebDAVCloudProvider.strongIfMatchValue(from: nil))
        XCTAssertNil(WebDAVCloudProvider.strongIfMatchValue(from: ""))
    }

    // MARK: - Provider: getMetadata

    func testGetMetadataHappyPathViaHead() async throws {
        let accountId = try seedCredential(username: "alice")
        let responder = TransportResponder { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            return StubResponse(status: 200, headers: [
                "ETag": "\"meta-etag\"",
                "Content-Length": "2048",
                "Last-Modified": "Tue, 01 Jul 2025 10:20:30 GMT",
            ])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/vault.kdbx")

        XCTAssertEqual(metadata.rev, "\"meta-etag\"")
        XCTAssertNil(metadata.contentHash)
        XCTAssertEqual(metadata.size, 2048)
    }

    func testGetMetadataHead405FallsBackToPropfind() async throws {
        let accountId = try seedCredential(username: "alice")
        let multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/vault.kdbx</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength>777</d:getcontentlength>
                <d:getetag>"probe-etag"</d:getetag>
                <d:getlastmodified>Fri, 04 Jul 2025 09:00:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let responder = TransportResponder { request in
            if request.httpMethod == "HEAD" {
                return StubResponse(status: 405, headers: [:])
            }
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
            return StubResponse(status: 207, headers: [:], body: Data(multistatus.utf8))
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        let metadata = try await provider.getMetadata(accountId: accountId, fileId: "/vault.kdbx")

        XCTAssertEqual(metadata.rev, "\"probe-etag\"")
        XCTAssertEqual(metadata.size, 777)
        XCTAssertNil(metadata.contentHash)
    }

    // MARK: - Provider: upload

    func testUploadSendsIfMatchForStrongRev() async throws {
        let accountId = try seedCredential(username: "alice")
        let recorder = MethodRecorder()
        let responder = TransportResponder { request in
            await recorder.record(request)
            return StubResponse(status: 204, headers: ["ETag": "\"new-etag\""])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        let metadata = try await provider.upload(
            accountId: accountId,
            fileId: "/vault.kdbx",
            data: Data("bytes".utf8),
            expectedRev: "\"strong-old\"",
            progress: { _ in }
        )

        let capturedPut = await recorder.firstMatching(method: "PUT")
        let put = try XCTUnwrap(capturedPut)
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"strong-old\"")
        XCTAssertEqual(metadata.rev, "\"new-etag\"")
    }

    func testUploadOmitsIfMatchForLastmodRev() async throws {
        let accountId = try seedCredential(username: "alice")
        let recorder = MethodRecorder()
        let responder = TransportResponder { request in
            await recorder.record(request)
            return StubResponse(status: 204, headers: ["ETag": "\"new-etag\""])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        _ = try await provider.upload(
            accountId: accountId,
            fileId: "/vault.kdbx",
            data: Data("bytes".utf8),
            expectedRev: "lastmod:Tue, 01 Jul 2025 10:20:30 GMT",
            progress: { _ in }
        )

        let capturedPut = await recorder.firstMatching(method: "PUT")
        let put = try XCTUnwrap(capturedPut)
        XCTAssertNil(put.value(forHTTPHeaderField: "If-Match"))
    }

    func testUpload412ThrowsConflict() async throws {
        let accountId = try seedCredential(username: "alice")
        let responder = TransportResponder { request in
            if request.httpMethod == "PUT" {
                return StubResponse(status: 412, headers: [:])
            }
            // Fresh HEAD after the conflict.
            return StubResponse(status: 200, headers: ["ETag": "\"remote-fresh\""])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        do {
            _ = try await provider.upload(
                accountId: accountId,
                fileId: "/vault.kdbx",
                data: Data(),
                expectedRev: "\"strong-old\"",
                progress: { _ in }
            )
            XCTFail("Expected conflict")
        } catch let error as CloudProviderError {
            guard case .conflict(let remoteRev) = error else {
                return XCTFail("Expected .conflict, got \(error)")
            }
            XCTAssertEqual(remoteRev, "\"remote-fresh\"")
        }
    }

    func testUploadPutWithoutETagTriggersFollowupHead() async throws {
        let accountId = try seedCredential(username: "alice")
        let recorder = MethodRecorder()
        let responder = TransportResponder { request in
            await recorder.record(request)
            if request.httpMethod == "PUT" {
                return StubResponse(status: 204, headers: [:]) // no ETag
            }
            return StubResponse(status: 200, headers: ["ETag": "\"head-etag\""])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        let metadata = try await provider.upload(
            accountId: accountId,
            fileId: "/vault.kdbx",
            data: Data(),
            expectedRev: nil,
            progress: { _ in }
        )

        XCTAssertEqual(metadata.rev, "\"head-etag\"")
        let capturedHead = await recorder.firstMatching(method: "HEAD")
        XCTAssertNotNil(capturedHead)
    }

    // MARK: - Provider: createFile

    func testCreateFileSendsIfNoneMatchStar() async throws {
        let accountId = try seedCredential(username: "alice")
        let recorder = MethodRecorder()
        let responder = TransportResponder { request in
            await recorder.record(request)
            return StubResponse(status: 201, headers: ["ETag": "\"created-etag\""])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        let created = try await provider.createFile(
            accountId: accountId,
            path: "/Vaults/new.kdbx",
            data: Data("bytes".utf8),
            progress: { _ in }
        )

        let capturedPut = await recorder.firstMatching(method: "PUT")
        let put = try XCTUnwrap(capturedPut)
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(created.metadata.rev, "\"created-etag\"")
        XCTAssertEqual(created.file.name, "new.kdbx")
        XCTAssertEqual(created.file.path, "/Vaults/new.kdbx")
    }

    func testCreateFile412ThrowsConflict() async throws {
        let accountId = try seedCredential(username: "alice")
        let responder = TransportResponder { _ in
            StubResponse(status: 412, headers: [:])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        do {
            _ = try await provider.createFile(
                accountId: accountId,
                path: "/Vaults/new.kdbx",
                data: Data(),
                progress: { _ in }
            )
            XCTFail("Expected conflict")
        } catch let error as CloudProviderError {
            guard case .conflict = error else {
                return XCTFail("Expected .conflict, got \(error)")
            }
        }
    }

    // MARK: - Provider: listFiles

    func testListFilesFiltersSortsAndAppliesQuery() async throws {
        let accountId = try seedCredential(username: "alice")
        let multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/zeta.kdbx</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/alpha.kdbx</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/notes.txt</d:href>
            <d:propstat>
              <d:prop><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/Backups/</d:href>
            <d:propstat>
              <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let responder = TransportResponder { _ in
            StubResponse(status: 207, headers: [:], body: Data(multistatus.utf8))
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        // No query: folders first (case-insensitive), .txt filtered out.
        let all = try await provider.listFiles(accountId: accountId, path: nil, query: nil)
        XCTAssertEqual(all.map(\.name), ["Backups", "alpha.kdbx", "zeta.kdbx"])
        XCTAssertFalse(all.contains(where: { $0.name == "notes.txt" }))

        // Query: filters by name substring.
        let filtered = try await provider.listFiles(accountId: accountId, path: nil, query: "alpha")
        XCTAssertEqual(filtered.map(\.name), ["alpha.kdbx"])
    }

    // MARK: - Provider: not authenticated

    func testGetMetadataThrowsNotAuthenticatedWithoutCredential() async {
        let responder = TransportResponder { _ in
            StubResponse(status: 200, headers: [:])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))

        do {
            _ = try await provider.getMetadata(accountId: "webdav-nonexistent", fileId: "/vault.kdbx")
            XCTFail("Expected notAuthenticated")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - connect()

    func testConnectProbesDepth0StoresCredentialAndAccount() async throws {
        try skipIfKeychainUnavailable()
        let recorder = MethodRecorder()
        let responder = TransportResponder { request in
            await recorder.record(request)
            return StubResponse(status: 207, headers: [:], body: Data(Self.emptyMultistatus.utf8))
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))
        let config = WebDAVConnectionConfiguration(
            serverURL: "https://cloud.example.com/dav",
            username: "alice",
            password: "s3cr3t"
        )

        let account = try await provider.connect(config)
        seededAccountIds.append(account.id)

        // Probe was a PROPFIND Depth 0.
        let capturedProbe = await recorder.firstMatching(method: "PROPFIND")
        let probe = try XCTUnwrap(capturedProbe)
        XCTAssertEqual(probe.value(forHTTPHeaderField: "Depth"), "0")

        // Credential persisted + account upserted.
        XCTAssertTrue(account.id.hasPrefix("webdav-"))
        XCTAssertNotNil(CloudTokenStore.tokenData(provider: providerId, accountId: account.id))
        XCTAssertNotNil(CloudAccountStore.account(provider: providerId, accountId: account.id))
        XCTAssertEqual(account.displayName, "alice@cloud.example.com/dav")
    }

    func testConnect401ThrowsNotAuthenticatedAndPersistsNothing() async throws {
        let responder = TransportResponder { _ in
            StubResponse(status: 401, headers: [:])
        }
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: responder.transport))
        let base = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/dav")
        let expectedAccountId = WebDAVURL.accountId(normalizedBaseURL: base, username: "alice")
        let config = WebDAVConnectionConfiguration(
            serverURL: "https://cloud.example.com/dav",
            username: "alice",
            password: "wrong"
        )

        do {
            _ = try await provider.connect(config)
            XCTFail("Expected notAuthenticated")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .notAuthenticated)
        }

        XCTAssertNil(CloudTokenStore.tokenData(provider: providerId, accountId: expectedAccountId))
        XCTAssertNil(CloudAccountStore.account(provider: providerId, accountId: expectedAccountId))
    }

    // MARK: - Helpers

    private static let emptyMultistatus = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/dav/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private func makeResponse(eTag: String?, ocETag: String?, lastModified: String?) -> WebDAVClient.Response {
        WebDAVClient.Response(
            statusCode: 200,
            data: Data(),
            eTag: eTag,
            ocETag: ocETag,
            lastModified: lastModified,
            contentLength: nil
        )
    }

    /// Seeds a `WebDAVCredential` for a base URL + username into `CloudTokenStore`
    /// and returns the derived accountId (tracked for cleanup). Skips the test if
    /// Keychain writes are unavailable in the host.
    private func seedCredential(
        baseURL: String = "https://host.example.com/dav/",
        username: String
    ) throws -> String {
        let normalized = try WebDAVURL.normalizedBaseURL(from: baseURL)
        let accountId = WebDAVURL.accountId(normalizedBaseURL: normalized, username: username)
        let credential = WebDAVCredential(
            serverURL: normalized.absoluteString,
            username: username,
            password: "s3cr3t"
        )
        let payload = try JSONEncoder().encode(credential)
        guard CloudTokenStore.setTokenData(payload, provider: providerId, accountId: accountId) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        seededAccountIds.append(accountId)
        return accountId
    }

    private func skipIfKeychainUnavailable() throws {
        let probeId = "webdav-keychain-probe"
        guard CloudTokenStore.setTokenData(Data("x".utf8), provider: providerId, accountId: probeId) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        _ = CloudTokenStore.deleteToken(provider: providerId, accountId: probeId)
    }
}

// MARK: - Stub transport plumbing

private struct StubResponse {
    let status: Int
    let headers: [String: String]
    var body: Data = Data()
}

/// Wraps an async responder closure into a `WebDAVClient.Transport`, building the
/// `HTTPURLResponse` from the returned `StubResponse`.
private struct TransportResponder {
    let respond: @Sendable (URLRequest) async -> StubResponse

    init(_ respond: @escaping @Sendable (URLRequest) async -> StubResponse) {
        self.respond = respond
    }

    var transport: WebDAVClient.Transport {
        { request in
            let stub = await respond(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com/")!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            return (stub.body, response)
        }
    }
}

/// Records requests so tests can assert which HTTP methods/headers were sent.
private actor MethodRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func firstMatching(method: String) -> URLRequest? {
        requests.first { $0.httpMethod == method }
    }
}
