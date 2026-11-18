@preconcurrency @testable import SwiftyDropbox
import XCTest
@testable import KeeForge

final class DropboxCloudProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testCreationClientFailureIsProvenBeforeContentDispatch() async throws {
        let provider = DropboxCloudProvider(clientForAccount: { _ in throw CloudProviderError.notAuthenticated })
        do {
            _ = try await provider.createFile(accountId: "missing", path: "/vault.kdbx", data: Data([1]), progress: { _ in })
            XCTFail("Expected pre-dispatch failure")
        } catch let failure as CloudUploadFailure {
            XCTAssertEqual(failure.outcome, .notDispatched)
            XCTAssertEqual(failure.underlying, .notAuthenticated)
        }
    }

    func testAuthenticateRequestsWriteScope() {
        let scopeRequest = DropboxCloudProvider.makeScopeRequest()

        XCTAssertEqual(scopeRequest.scopes, DropboxCloudProvider.requestedScopes)
        XCTAssertTrue(scopeRequest.scopes.contains("files.content.write"))
        XCTAssertEqual(scopeRequest.includeGrantedScopes, false)
    }

    func testUploadArgumentKeepsLiteralPercentNames() throws {
        let filename = try DatabaseCreationService.normalizedFilename(for: "new%20db 100%")
        let path = DatabaseCreationService.cloudFilePath(filename: filename, folderPath: "/Vaults%20 100%")
        let arguments = Files.UploadArg(path: path, mode: .add, strictConflict: true)
        let json = try Files.UploadArgSerializer().serialize(arguments)
        guard case .dictionary(let fields) = json else {
            return XCTFail("Expected upload arguments")
        }
        XCTAssertEqual(fields["path"], .str("/Vaults%20 100%/new%20db 100%.kdbx"))
    }

    func testSDKProbeInterceptionIsRestrictedToItsRegisteredHost() throws {
        let probe = DropboxHTTPProbe(status: 503)
        defer { probe.close() }
        let own = URLRequest(url: try XCTUnwrap(URL(string: "https://\(probe.host)/2/files/upload")))
        let foreign = URLRequest(url: try XCTUnwrap(URL(string: "https://unregistered-dropbox-probe.invalid/2/files/upload")))
        XCTAssertTrue(DropboxProbeURLProtocol.canInit(with: own))
        XCTAssertFalse(DropboxProbeURLProtocol.canInit(with: foreign))
        XCTAssertEqual(probe.startLoadingCount, 0)
        XCTAssertTrue(probe.requests.isEmpty)
    }

    @MainActor
    func testSDKUncertainUploadResponsesRetainAttemptWithoutSecondRequest() async throws {
        for status in [503, 409] {
            DatabaseListStore.clearAll()
            defer { DatabaseListStore.clearAll() }
            let transport = DropboxHTTPProbe(status: status)
            let client = transport.client()
            defer { client.shutdown(); transport.close() }
            let provider = DropboxCloudProvider(clientForAccount: { _ in client })
            let reference = try! DatabaseListStore.addCloud(provider: provider.id, accountId: "sdk-probe",
                file: .init(id: "/probe.kdbx", name: "probe.kdbx", path: "/probe.kdbx", isFolder: false, modifiedDate: nil, size: nil))
            let context = try CloudJournalTestContext(reference: reference)
            var environment = context.environment()
            environment.upload = { reference, bytes, rev, progress in
                try await provider.upload(accountId: "sdk-probe", fileId: reference.cloudSyncMetadata!.fileId,
                    data: bytes, expectedRev: rev, progress: progress)
            }
            do {
                _ = try await CloudDatabaseSaver.deliver(context.stored, reference: reference, environment: environment)
                XCTFail("An accepted write with a lost acknowledgement cannot settle")
            } catch {
                let cause = error as NSError
                XCTAssertNil(error as? CloudUploadFailure, "A mapped SDK conflict cannot manufacture phase proof")
                if status == 503 {
                    XCTAssertNotNil(error as? DropboxCloudProvider.TransientFailure,
                        "SDK cause domain=\(cause.domain) code=\(cause.code), intercepted=\(transport.requests.count)")
                } else {
                    guard case .conflict? = error as? CloudProviderError else { return XCTFail("Expected mapped SDK conflict") }
                }
            }
            let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertEqual(CloudJournalDecision.state(of: retained.marker), .attempting)
            for _ in 0..<2 {
                guard case .retained? = try await CloudDatabaseSaver.deliver(retained, reference: reference, environment: environment) else {
                    return XCTFail("Unknown SDK request must never be sent again")
                }
            }
            XCTAssertGreaterThan(transport.canInitCount, 0)
            XCTAssertEqual(transport.startLoadingCount, status == 409 ? 2 : 1, "A conflict may read metadata but never resend content")
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertEqual(transport.requests.first?.bytes, context.payload)
            XCTAssertEqual(transport.requests.first?.path, "/probe.kdbx")
            XCTAssertEqual(transport.requests.first?.mode, "update")
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), context.payload)
            XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        }
    }

    // MARK: - Sign-out

    /// Disconnecting from Settings can be the first Dropbox call of the session,
    /// so sign-out must clear the refresh token whether or not the SDK ever got
    /// configured.
    func testSignOutRemovesStoredRefreshToken() throws {
        let providerID = CloudProviderKind.dropbox.rawValue
        let accountID = "unit-dropbox-signout"

        guard CloudTokenStore.setTokenData(Data("refresh-token".utf8), provider: providerID, accountId: accountID) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        defer { _ = CloudTokenStore.deleteToken(provider: providerID, accountId: accountID) }

        DropboxCloudProvider.shared.signOut(accountId: accountID)

        XCTAssertNil(CloudTokenStore.tokenData(provider: providerID, accountId: accountID))
        XCTAssertFalse(DropboxCloudProvider.shared.isAuthenticated(accountId: accountID))
    }

    // MARK: - Offline and auth classification

    /// Airplane-mode shape: only the refresh token is persisted, so the call
    /// fails while refreshing, and SwiftyDropbox has already flattened the
    /// transport cause into `OAuth2Error.unknown` by the time we see it.
    func testOAuthRefreshTransportFailureMapsToNetworkUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.unknown))

        XCTAssertEqual(mapped(error), .networkUnavailable)
    }

    func testOAuthRefreshInvalidGrantMapsToNotAuthenticated() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.invalidGrant))

        XCTAssertEqual(mapped(error), .notAuthenticated)
    }

    func testOAuthRefreshServerErrorMapsToServiceUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.oauthError(OAuth2Error.temporarilyUnavailable))

        XCTAssertEqual(mapped(error), .serviceUnavailable)
    }

    func testURLSessionOfflineErrorMapsToNetworkUnavailable() {
        let error = CallError<Files.DownloadError>.clientError(.urlSessionError(URLError(.notConnectedToInternet)))

        XCTAssertEqual(mapped(error), .networkUnavailable)
    }

    /// A TLS failure is a real error, not "you are offline": it must not send
    /// the caller down the cached-copy path.
    func testTLSFailureDoesNotMapToOffline() {
        let error = CallError<Files.DownloadError>.clientError(.urlSessionError(URLError(.secureConnectionFailed)))

        XCTAssertNotEqual(mapped(error), .networkUnavailable)
    }

    func testInternalServerErrorIsTransientAndMapsToServiceUnavailable() {
        let error = CallError<Files.UploadError>.internalServerError(503, nil, nil)

        let failure = DropboxCloudProvider.mapGenericDropboxError(error) as? DropboxCloudProvider.TransientFailure
        XCTAssertEqual(failure?.kind, .serverError)
        XCTAssertEqual(failure?.mapped, .serviceUnavailable)
    }

    func testServerErrorRetryDelayBacksOffAndExhausts() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .serverError, attempt: 1), 1)
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .serverError, attempt: 2), 2)
        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .serverError, attempt: DropboxCloudProvider.maxAttempts))
    }

    func testExpiredAccessTokenStillMapsToNotAuthenticated() {
        let error = CallError<Files.UploadError>.authError(.expiredAccessToken, nil, nil, nil)

        XCTAssertEqual(mapped(error), .notAuthenticated)
    }

    func testMissingScopeStillMapsToWriteScopeRequired() {
        let error = CallError<Files.UploadError>.authError(
            .missingScope(Auth.TokenScopeError(requiredScope: "files.content.write")),
            nil,
            nil,
            nil
        )

        XCTAssertEqual(mapped(error), .writeScopeRequired)
    }

    // MARK: - Rate limiting

    func testRateLimitErrorIsRetryableAndReportsRateLimited() {
        let error = CallError<Files.UploadError>.rateLimitError(
            Auth.RateLimitError(reason: .tooManyRequests, retryAfter: 4),
            nil,
            nil,
            nil
        )

        let failure = DropboxCloudProvider.mapGenericDropboxError(error) as? DropboxCloudProvider.TransientFailure
        XCTAssertEqual(failure?.kind, .rateLimited(retryAfter: 4))
        XCTAssertEqual(failure?.mapped, .rateLimited)
    }

    func testTooManyWriteOperationsIsRetryable() {
        let failure = DropboxCloudProvider.mapWriteError(.tooManyWriteOperations) as? DropboxCloudProvider.TransientFailure

        XCTAssertEqual(failure?.kind, .tooManyWriteOperations)
        XCTAssertEqual(failure?.mapped, .rateLimited)
    }

    /// Writes surface the transient cause without internally retrying it.
    func testTransientFailureCarriesLocalizedDescription() {
        let failure = DropboxCloudProvider.TransientFailure(kind: .tooManyWriteOperations, mapped: .rateLimited)

        XCTAssertEqual(failure.errorDescription, CloudProviderError.rateLimited.errorDescription)
    }

    // MARK: - Retry delays

    func testRateLimitDelayHonoursRetryAfter() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 3), attempt: 1), 3)
    }

    func testRateLimitDelayIsClampedToTheCeiling() {
        XCTAssertEqual(
            DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 600), attempt: 1),
            DropboxCloudProvider.maxRetryDelay
        )
    }

    func testRateLimitDelayHasAFloorOfOneSecond() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 0), attempt: 1), 1)
    }

    func testWriteBackoffGrowsBetweenAttempts() {
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: 1), 1)
        XCTAssertEqual(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: 2), 2)
    }

    func testRetryStopsOnceTheAttemptBudgetIsSpent() {
        let lastAttempt = DropboxCloudProvider.maxAttempts

        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .rateLimited(retryAfter: 1), attempt: lastAttempt))
        XCTAssertNil(DropboxCloudProvider.retryDelay(for: .tooManyWriteOperations, attempt: lastAttempt))
    }

    // MARK: - Typed write errors

    func testWriteErrorsMapToActionableCases() {
        XCTAssertEqual(writeError(.insufficientSpace), .insufficientSpace)
        XCTAssertEqual(writeError(.noWritePermission), .permissionDenied)
        XCTAssertEqual(writeError(.teamFolder), .permissionDenied)
        XCTAssertEqual(writeError(.disallowedName), .invalidName)
        XCTAssertEqual(writeError(.malformedPath(nil)), .invalidName)
        XCTAssertEqual(writeError(.conflict(.file)), .conflict(remoteRev: nil))
    }

    func testUnspecifiedWriteErrorFallsBackToTheGenericMapping() {
        XCTAssertNil(DropboxCloudProvider.mapWriteError(.other))
    }

    func testUploadRouteErrorUnwrapsTheWriteFailure() {
        let uploadError = Files.UploadError.path(
            Files.UploadWriteFailed(reason: .insufficientSpace, uploadSessionId: "unit-session")
        )

        XCTAssertEqual(DropboxCloudProvider.mapUploadRouteError(uploadError) as? CloudProviderError, .insufficientSpace)
    }

    func testUploadRouteErrorWithoutAPathFailureIsNotMapped() {
        XCTAssertNil(DropboxCloudProvider.mapUploadRouteError(.payloadTooLarge))
    }

    // MARK: - Helpers

    private func mapped<E>(_ error: CallError<E>) -> CloudProviderError? {
        DropboxCloudProvider.mapGenericDropboxError(error) as? CloudProviderError
    }

    // MARK: - Listing filter

    func testNonKDBXFileIsListedOnlyWhenAllFilesAreRequested() {
        let file = dropboxFile(name: "vault.bin")

        XCTAssertNil(DropboxCloudProvider.makeCloudFile(from: file, includesAllFiles: false))
        XCTAssertEqual(DropboxCloudProvider.makeCloudFile(from: file, includesAllFiles: true)?.id, "/Vaults/vault.bin")
        XCTAssertNotNil(DropboxCloudProvider.makeCloudFile(from: dropboxFile(name: "Personal.KDBX"), includesAllFiles: false))
    }

    func testFoldersAreListedEitherWay() {
        let folder = Files.FolderMetadata(name: "Vaults", id: "id:folder", pathDisplay: "/Vaults")

        XCTAssertEqual(DropboxCloudProvider.makeCloudFile(from: folder, includesAllFiles: false)?.isFolder, true)
        XCTAssertEqual(DropboxCloudProvider.makeCloudFile(from: folder, includesAllFiles: true)?.isFolder, true)
    }

    func testSearchDropsTheServerSideExtensionFilterOnlyWhenAllFilesAreRequested() {
        XCTAssertEqual(DropboxCloudProvider.searchOptions(path: "/Vaults", includesAllFiles: false).fileExtensions, ["kdbx"])
        XCTAssertNil(DropboxCloudProvider.searchOptions(path: "/Vaults", includesAllFiles: true).fileExtensions)
        XCTAssertEqual(DropboxCloudProvider.searchOptions(path: "/Vaults", includesAllFiles: true).path, "/Vaults")
    }

    private func dropboxFile(name: String) -> Files.FileMetadata {
        Files.FileMetadata(
            name: name,
            id: "id:file",
            clientModified: Date(timeIntervalSince1970: 1_700_000_000),
            serverModified: Date(timeIntervalSince1970: 1_700_000_000),
            rev: "0123456789abcdef",
            size: 1,
            pathDisplay: "/Vaults/\(name)"
        )
    }

    private func writeError(_ error: Files.WriteError) -> CloudProviderError? {
        DropboxCloudProvider.mapWriteError(error) as? CloudProviderError
    }
}

private final class DropboxHTTPProbe: @unchecked Sendable {
    struct Upload: Sendable {
        let path: String
        let mode: String
        let bytes: Data
    }
    private let lock = NSLock()
    let host = "dropbox-\(UUID().uuidString.lowercased()).invalid"
    let status: Int
    private var uploads: [Upload] = []
    private var paths: [String] = []
    private var canInitCalls = 0
    private var starts = 0
    var canInitCount: Int { lock.withLock { canInitCalls } }
    var startLoadingCount: Int { lock.withLock { starts } }
    func observedCanInit() { lock.withLock { canInitCalls += 1 } }
    func observedStartLoading() { lock.withLock { starts += 1 } }
    var requests: [Upload] { lock.withLock { uploads } }
    var otherPaths: [String] { lock.withLock { paths } }

    init(status: Int) {
        self.status = status
        DropboxProbeURLProtocol.install(self)
    }

    func client() -> DropboxClient {
        var configuration = NetworkSessionConfiguration(kind: .default)
        configuration.urlSessionConfiguration.protocolClasses = [DropboxProbeURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return DropboxClient(transportClient: DropboxTransportClientImpl(accessToken: "unit-transport-only",
            baseHosts: BaseHosts(apiHost: "https://\(host)", contentHost: "https://\(host)", notifyHost: "https://\(host)"), sessionConfiguration: configuration))
    }

    func close() { DropboxProbeURLProtocol.remove(host: host) }

    func response(for request: URLRequest) -> (Int, Data) {
        if request.url?.path.hasSuffix("/upload") == true {
            let argument = request.value(forHTTPHeaderField: "Dropbox-API-Arg")?.data(using: .utf8) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: argument)) as? [String: Any] ?? [:]
            let rawMode = json["mode"] as? [String: Any]
            let mode = rawMode?[".tag"] as? String ?? json["mode"] as? String ?? "missing"
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    bytes.append(contentsOf: buffer.prefix(read))
                }
            }
            lock.withLock { uploads.append(.init(path: json["path"] as? String ?? "missing", mode: mode, bytes: bytes)) }
            let body = status == 409
                ? #"{"error_summary":"path/conflict/file/","error":{".tag":"path","reason":{".tag":"conflict","conflict":{".tag":"file"}},"upload_session_id":"unit"}}"#
                : #"{"error":"accepted response was lost"}"#
            return (status, Data(body.utf8))
        }
        lock.withLock { paths.append(request.url?.path ?? "missing") }
        return (409, Data(#"{"error_summary":"path/not_found/","error":{".tag":"path","path":{".tag":"not_found"}}}"#.utf8))
    }
}

private final class DropboxProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var probes: [String: DropboxHTTPProbe] = [:]
    }
    private static let registry = Registry()
    static func install(_ probe: DropboxHTTPProbe) {
        registry.lock.withLock { registry.probes[probe.host] = probe }
    }
    static func remove(host: String) {
        registry.lock.withLock { _ = registry.probes.removeValue(forKey: host) }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let probe = registry.lock.withLock({ registry.probes[request.url?.host ?? ""] }) else { return false }
        probe.observedCanInit()
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let probe = Self.registry.lock.withLock({ Self.registry.probes[request.url?.host ?? ""] }),
              let url = request.url, let response = HTTPURLResponse(url: url, statusCode: probe.status,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        probe.observedStartLoading()
        let result = probe.response(for: request)
        let actual = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: response.allHeaderFields as? [String: String])!
        client?.urlProtocol(self, didReceive: actual, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
