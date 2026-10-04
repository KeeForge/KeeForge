import XCTest
@testable import KeeForge

@MainActor
final class FTPConnectViewModelTests: XCTestCase {
    func testConnectRejectsMissingFieldsWithoutCallingProvider() async {
        let cases: [(server: String, username: String, password: String, message: String)] = [
            ("  ", "alex", "secret", "Enter the FTP server address."),
            ("ftp://nas.local", " ", "secret", "Enter your username."),
            ("ftp://nas.local", "alex", "", "Enter your password."),
        ]

        for testCase in cases {
            let connector = MockFTPConnector()
            let viewModel = makeViewModel(connector: connector)
            viewModel.serverURL = testCase.server
            viewModel.username = testCase.username
            viewModel.password = testCase.password

            let account = await viewModel.connect()

            XCTAssertNil(account)
            XCTAssertEqual(connector.configurations, [])
            XCTAssertEqual(viewModel.errorMessage, testCase.message)
        }
    }

    func testConnectRequiresTheUnencryptedOptInBeforeCallingProvider() async {
        let connector = MockFTPConnector()
        let viewModel = makeViewModel(connector: connector)
        viewModel.allowsUnencryptedFTP = false

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.configurations, [])
        XCTAssertEqual(viewModel.errorMessage, "FTP is not encrypted. Turn on Allow Unencrypted FTP to connect.")
    }

    func testConnectRejectsOtherSchemesBeforeCallingProvider() async {
        let connector = MockFTPConnector()
        let viewModel = makeViewModel(connector: connector)
        viewModel.serverURL = "sftp://nas.local/"

        let account = await viewModel.connect()

        XCTAssertNil(account)
        XCTAssertEqual(connector.configurations, [])
        XCTAssertEqual(viewModel.errorMessage, "The server address must start with ftp://.")
    }

    func testConnectPassesTrimmedValuesAndReturnsTheAccount() async {
        let connector = MockFTPConnector()
        let viewModel = makeViewModel(connector: connector)
        viewModel.serverURL = "  nas.local/vaults "
        viewModel.username = " alex "

        let account = await viewModel.connect()

        XCTAssertEqual(account, MockFTPConnector.account)
        XCTAssertEqual(connector.configurations, [
            FTPConnectionConfiguration(
                serverURL: "nas.local/vaults",
                username: "alex",
                password: "secret",
                allowsUnencryptedFTP: true
            ),
        ])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isConnecting)
    }

    func testConnectExplainsRejectedCredentialsAndMissingFolder() async {
        let cases: [(CloudProviderError, String)] = [
            (.notAuthenticated, "The FTP username or password was rejected."),
            (.fileNotFound, "The FTP server has no folder at this path."),
            (.networkUnavailable, CloudProviderError.networkUnavailable.localizedDescription),
        ]

        for (error, message) in cases {
            let connector = MockFTPConnector()
            connector.error = error
            let viewModel = makeViewModel(connector: connector)

            let account = await viewModel.connect()

            XCTAssertNil(account)
            XCTAssertEqual(viewModel.errorMessage, message)
            XCTAssertFalse(viewModel.isConnecting)
        }
    }

    func testDismissedConnectionDropsLateSuccessAndError() async {
        let results: [Result<CloudAccount, Error>] = [
            .success(MockFTPConnector.account),
            .failure(CloudProviderError.notAuthenticated),
        ]
        for result in results {
            let connector = SuspendedFTPConnector()
            let viewModel = FTPConnectViewModel(connector: connector)
            viewModel.serverURL = "ftp://nas.local/"
            viewModel.username = "alex"
            viewModel.password = "secret"
            viewModel.allowsUnencryptedFTP = true
            let connection = Task { await viewModel.connect() }
            await connector.waitUntilStarted()

            viewModel.cancelPendingConnection()
            await connector.finish(result)
            let account = await connection.value

            XCTAssertNil(account)
            XCTAssertNil(viewModel.errorMessage)
            XCTAssertFalse(viewModel.isConnecting)
            XCTAssertEqual(viewModel.password, "")
        }
    }

    private func makeViewModel(connector: MockFTPConnector) -> FTPConnectViewModel {
        let viewModel = FTPConnectViewModel(connector: connector)
        viewModel.serverURL = "ftp://nas.local/"
        viewModel.username = "alex"
        viewModel.password = "secret"
        viewModel.allowsUnencryptedFTP = true
        return viewModel
    }
}

private actor SuspendedFTPConnector: FTPConnecting {
    private var continuation: CheckedContinuation<CloudAccount, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func connect(_ configuration: FTPConnectionConfiguration) async throws -> CloudAccount {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finish(_ result: Result<CloudAccount, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class MockFTPConnector: FTPConnecting, @unchecked Sendable {
    static let account = CloudAccount(id: "ftp-test", displayName: "alex@nas.local", provider: "ftp")

    var error: Error?
    private(set) var configurations: [FTPConnectionConfiguration] = []

    func connect(_ configuration: FTPConnectionConfiguration) async throws -> CloudAccount {
        configurations.append(configuration)
        if let error {
            throw error
        }
        return Self.account
    }
}
