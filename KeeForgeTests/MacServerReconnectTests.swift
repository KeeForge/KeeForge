#if os(macOS)
import RemoteFileTransports
import XCTest
@testable import KeeForge

/// Reconnect against the production WebDAV and FTP providers: a stubbed HTTP
/// transport and `FakeFTPServer`, never an injected success.
@MainActor
final class MacServerReconnectTests: XCTestCase {
    private var seeded: [(provider: String, accountID: String)] = []

    override func tearDown() async throws {
        for (provider, accountID) in seeded {
            _ = CloudTokenStore.deleteToken(provider: provider, accountId: accountID)
            CloudAccountStore.remove(provider: provider, accountId: accountID)
        }
        seeded = []
        try await super.tearDown()
    }

    func testWebDAVFormIsPrefilledWithTheAccountButNeverItsPassword() throws {
        let (accountID, base) = try webDAVAccount(username: "alice", server: "http://nas.local:8080/dav")
        try seed(WebDAVCredential(serverURL: base.absoluteString, username: "alice", password: "old"),
                 provider: .webDAV, accountID: accountID)
        let reconnect = try XCTUnwrap(MacServerReconnect(reference: reference(.webDAV, accountID: accountID),
            provider: { _ in WebDAVCloudProvider(client: WebDAVClient(transport: Self.refusingTransport)) }))

        guard case .webDAV(let form)? = reconnect.makeForm() else { return XCTFail("A WebDAV form") }

        XCTAssertEqual(form.serverURL, base.absoluteString)
        XCTAssertEqual(form.username, "alice")
        XCTAssertEqual(form.password, "")
        XCTAssertTrue(form.allowsUnencryptedHTTP, "The account was added over http://")
        XCTAssertEqual(reconnect.providerKind, .webDAV)
    }

    func testRejectedPasswordStaysInTheFormAndAnotherAccountIsRefusedBeforeConnecting() async throws {
        let (accountID, base) = try webDAVAccount(username: "alice")
        try seed(WebDAVCredential(serverURL: base.absoluteString, username: "alice", password: "old"),
                 provider: .webDAV, accountID: accountID)
        let requests = RequestCounter()
        let provider = WebDAVCloudProvider(client: WebDAVClient(transport: { request in
            await requests.increment()
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                                          httpVersion: nil, headerFields: nil)))
        }))
        let reconnect = try XCTUnwrap(MacServerReconnect(reference: reference(.webDAV, accountID: accountID),
                                                         provider: { _ in provider }))

        do {
            try await reconnect.run { form in
                guard case .webDAV(let webDAV) = form else { return false }
                webDAV.password = "still wrong"
                let rejected = await webDAV.connect()
                XCTAssertNil(rejected)
                XCTAssertEqual(webDAV.errorMessage, String(localized: "The WebDAV username or password was rejected."))
                let requestsAfterRejection = await requests.count
                XCTAssertEqual(requestsAfterRejection, 1)

                webDAV.username = "bob"
                let other = await webDAV.connect()
                XCTAssertNil(other)
                XCTAssertEqual(webDAV.errorMessage,
                    String(localized: "This database was added with a different server address or username."))
                let requestsAfterMismatch = await requests.count
                XCTAssertEqual(requestsAfterMismatch, 1, "Another account never reaches the server")
                return false
            }
            XCTFail("Closing the form cancels")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .authenticationCancelled)
        }
        let stored = try XCTUnwrap(CloudTokenStore.tokenData(provider: CloudProviderKind.webDAV.rawValue,
                                                             accountId: accountID))
        XCTAssertEqual(try JSONDecoder().decode(WebDAVCredential.self, from: stored).password, "old",
                       "A rejected password replaces nothing")
    }

    func testFTPReconnectLogsInWithTheNewPasswordAndStoresItForTheSameAccount() async throws {
        let server = FakeFTPServer()
        let base = try FTPURL.normalizedBaseURL(from: "ftp://nas.local/", allowsUnencryptedFTP: true)
        let accountID = FTPURL.accountId(normalizedBaseURL: base, username: "alex")
        try seed(FTPCredential(serverURL: base.absoluteString, username: "alex", password: "old"),
                 provider: .ftp, accountID: accountID)
        let provider = FTPCloudProvider(client: server.makeClient())
        let reconnect = try XCTUnwrap(MacServerReconnect(reference: reference(.ftp, accountID: accountID),
                                                         provider: { _ in provider }))

        try await reconnect.run { form in
            guard case .ftp(let ftp) = form else { return false }
            XCTAssertEqual(ftp.serverURL, base.absoluteString)
            XCTAssertEqual(ftp.username, "alex")
            XCTAssertEqual(ftp.password, "")
            XCTAssertTrue(ftp.allowsUnencryptedFTP)
            ftp.password = "secret"
            return await ftp.connect() != nil
        }

        let stored = try XCTUnwrap(CloudTokenStore.tokenData(provider: CloudProviderKind.ftp.rawValue,
                                                             accountId: accountID))
        XCTAssertEqual(try JSONDecoder().decode(FTPCredential.self, from: stored).password, "secret")
        XCTAssertTrue(server.commandLog.contains("PASS ***"))
    }

    func testReconnectRefusesAnotherServerOrUsernameForBothProviders() async throws {
        let webDAVBase = try WebDAVURL.normalizedBaseURL(from: "https://cloud.example.com/dav/")
        let webDAV = WebDAVConnectViewModel(connector: WebDAVCloudProvider(
            client: WebDAVClient(transport: { _ in
                XCTFail("Another account must never reach the provider transport")
                throw URLError(.cancelled)
            })), expectedAccountID: WebDAVURL.accountId(normalizedBaseURL: webDAVBase, username: "alice"))
        let ftpBase = try FTPURL.normalizedBaseURL(from: "ftp://nas.local/", allowsUnencryptedFTP: true)
        let server = FakeFTPServer()
        let ftp = FTPConnectViewModel(connector: FTPCloudProvider(client: server.makeClient()),
            expectedAccountID: FTPURL.accountId(normalizedBaseURL: ftpBase, username: "alice"))
        ftp.allowsUnencryptedFTP = true
        for changedUsername in [false, true] {
            webDAV.serverURL = changedUsername ? webDAVBase.absoluteString : "https://other.example.com/dav/"
            webDAV.username = changedUsername ? "bob" : "alice"
            webDAV.password = "new"
            let webDAVAccount = await webDAV.connect()
            XCTAssertNil(webDAVAccount)
            XCTAssertEqual(webDAV.errorMessage,
                String(localized: "This database was added with a different server address or username."))

            ftp.serverURL = changedUsername ? ftpBase.absoluteString : "ftp://other.local/"
            ftp.username = changedUsername ? "bob" : "alice"
            ftp.password = "new"
            let ftpAccount = await ftp.connect()
            XCTAssertNil(ftpAccount)
            XCTAssertEqual(ftp.errorMessage,
                String(localized: "This database was added with a different server address or username."))
        }
        XCTAssertTrue(server.commandLog.isEmpty, "Another FTP account never reaches the server")
        webDAV.cancelPendingConnection()
        ftp.cancelPendingConnection()
    }

    func testOnlyServerReferencesWithAConnectFormCanReconnect() {
        XCTAssertNil(MacServerReconnect(reference: MacLockedPageFixtures.reference(filename: "local.kdbx")))
        XCTAssertNil(MacServerReconnect(reference: reference(.webDAV, accountID: "a"), provider: { _ in nil }))
    }

    func testThePromptAnswersOnceAndLockOrCloseCancelsIt() async throws {
        let prompt = MacServerCredentialPrompt()
        let form = MacServerCredentialForm.webDAV(WebDAVConnectViewModel(
            connector: WebDAVCloudProvider(client: WebDAVClient(transport: Self.refusingTransport))))

        let connected = Task { await prompt.present(form) }
        while prompt.request == nil { await Task.yield() }
        prompt.finish(connected: true)
        let first = await connected.value
        XCTAssertTrue(first)
        XCTAssertNil(prompt.request)

        let cancelled = Task { await prompt.present(form) }
        while prompt.request == nil { await Task.yield() }
        prompt.finish(connected: false)
        prompt.finish(connected: true)
        let second = await cancelled.value
        XCTAssertFalse(second, "Only the first answer counts")
    }

    func testFinishingThePromptClearsThePasswordBeforeTheViewDisappears() async {
        let prompt = MacServerCredentialPrompt()
        let form = WebDAVConnectViewModel(connector: WebDAVCloudProvider(
            client: WebDAVClient(transport: Self.refusingTransport)))
        let waiting = Task { await prompt.present(.webDAV(form)) }
        while prompt.request == nil { await Task.yield() }
        form.password = "typed server password"

        prompt.finish(connected: false)

        XCTAssertEqual(form.password, "")
        let connected = await waiting.value
        XCTAssertFalse(connected)
        let lateConnection = await form.connect()
        XCTAssertNil(lateConnection)
    }

    // MARK: - Helpers

    private static let refusingTransport: WebDAVClient.Transport = { _ in throw URLError(.cancelled) }

    private func webDAVAccount(username: String, server: String = "https://cloud.example.com/dav/") throws -> (String, URL) {
        let base = try WebDAVURL.normalizedBaseURL(from: server, allowsUnencryptedHTTP: true)
        return (WebDAVURL.accountId(normalizedBaseURL: base, username: username), base)
    }

    private func seed(_ credential: some Encodable, provider: CloudProviderKind, accountID: String) throws {
        guard CloudTokenStore.setTokenData(try JSONEncoder().encode(credential), provider: provider.rawValue,
                                           accountId: accountID) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
        seeded.append((provider.rawValue, accountID))
    }

    private func reference(_ provider: CloudProviderKind, accountID: String) -> DatabaseReference {
        var reference = MacLockedPageFixtures.reference(filename: "vault.kdbx", provider: provider)
        reference.source = .cloud(CloudSyncMetadata(provider: provider.rawValue, accountId: accountID,
            fileId: "/vault.kdbx", displayPath: "/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
            lastSyncedAt: nil, lastSyncIssue: nil))
        return reference
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
#endif
