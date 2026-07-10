import XCTest
@testable import KeeForge

@MainActor
final class WebDAVConnectViewModelTests: XCTestCase {
    func testConnectRejectsEmptyServerURLWithoutCallingProvider() async {
        let connector = MockWebDAVConnector()
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "   "
        viewModel.username = "alex"
        viewModel.password = "secret"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isConnecting)
    }

    func testConnectRejectsEmptyUsernameWithoutCallingProvider() async {
        let connector = MockWebDAVConnector()
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "https://cloud.example.com/"
        viewModel.username = ""
        viewModel.password = "secret"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testConnectRejectsEmptyPasswordWithoutCallingProvider() async {
        let connector = MockWebDAVConnector()
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "https://cloud.example.com/"
        viewModel.username = "alex"
        viewModel.password = ""

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testConnectRejectsHTTPURLBeforeCallingProvider() async {
        let connector = MockWebDAVConnector()
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "http://cloud.example.com/"
        viewModel.username = "alex"
        viewModel.password = "secret"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Turn on Allow Unencrypted HTTP in Advanced to use an http:// server address."
        )
        XCTAssertFalse(viewModel.isConnecting)
    }

    func testConnectAllowsHTTPWhenExplicitlyEnabled() async {
        let connector = MockWebDAVConnector()
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "http://vault.local:8080/dav"
        viewModel.username = "alex"
        viewModel.password = "secret"
        viewModel.allowsUnencryptedHTTP = true

        let account = await viewModel.connect()

        XCTAssertNotNil(account)
        XCTAssertEqual(connector.connectCallCount, 1)
        XCTAssertEqual(connector.lastConfiguration?.serverURL, "http://vault.local:8080/dav")
        XCTAssertEqual(connector.lastConfiguration?.allowsUnencryptedHTTP, true)
    }

    func testConnectSuccessReturnsAccountAndClearsError() async {
        let connector = MockWebDAVConnector()
        let account = CloudAccount(
            id: "webdav-abc",
            displayName: "alex@cloud.example.com",
            provider: CloudProviderKind.webDAV.rawValue
        )
        connector.result = .success(account)
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "  https://cloud.example.com/  "
        viewModel.username = "  alex  "
        viewModel.password = "secret"

        let returned = await viewModel.connect()

        XCTAssertEqual(returned, account)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isConnecting)
        XCTAssertEqual(connector.connectCallCount, 1)
        XCTAssertEqual(connector.lastConfiguration?.serverURL, "https://cloud.example.com/")
        XCTAssertEqual(connector.lastConfiguration?.username, "alex")
        XCTAssertEqual(connector.lastConfiguration?.password, "secret")
        XCTAssertEqual(connector.lastConfiguration?.allowsUnencryptedHTTP, false)
    }

    func testConnectAuthenticationFailureUsesCredentialSpecificMessage() async {
        let connector = MockWebDAVConnector()
        connector.result = .failure(CloudProviderError.notAuthenticated)
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "https://cloud.example.com/"
        viewModel.username = "alex"
        viewModel.password = "secret"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 1)
        XCTAssertEqual(viewModel.errorMessage, "The WebDAV username or password was rejected.")
        XCTAssertFalse(viewModel.isConnecting)
    }

    func testConnectFailureSetsErrorMessageAndClearsConnecting() async {
        let connector = MockWebDAVConnector()
        connector.result = .failure(CloudProviderError.fileNotFound)
        let viewModel = WebDAVConnectViewModel(connector: connector)
        viewModel.serverURL = "https://cloud.example.com/"
        viewModel.username = "alex"
        viewModel.password = "secret"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.connectCallCount, 1)
        XCTAssertEqual(viewModel.errorMessage, CloudProviderError.fileNotFound.localizedDescription)
        XCTAssertFalse(viewModel.isConnecting)
    }
}

private final class MockWebDAVConnector: WebDAVConnecting, @unchecked Sendable {
    var result: Result<CloudAccount, Error> = .success(
        CloudAccount(id: "webdav-abc", displayName: "alex@cloud.example.com", provider: CloudProviderKind.webDAV.rawValue)
    )
    private(set) var connectCallCount = 0
    private(set) var lastConfiguration: WebDAVConnectionConfiguration?

    func connect(_ configuration: WebDAVConnectionConfiguration) async throws -> CloudAccount {
        connectCallCount += 1
        lastConfiguration = configuration
        return try result.get()
    }
}
