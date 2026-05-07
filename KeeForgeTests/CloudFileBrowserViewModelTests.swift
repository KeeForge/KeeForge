import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class CloudFileBrowserViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testRequestKeyIncludesAccountPathAndSearchText() {
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        viewModel.searchText = "vault"

        XCTAssertEqual(viewModel.requestKey(accountID: "acct-1"), "acct-1|/Vaults|vault")
    }

    func testLoadUsesTrimmedQueryAndClearsPreviousErrorOnSuccess() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        provider.listError = CloudProviderError.fileNotFound

        await viewModel.load(provider: provider, accountID: "acct-1")

        viewModel.searchText = "  personal  "
        provider.listError = nil
        provider.filesToReturn = [
            CloudFile(
                id: "/Vaults/personal.kdbx",
                name: "personal.kdbx",
                path: "/Vaults/personal.kdbx",
                isFolder: false,
                modifiedDate: nil,
                size: nil
            )
        ]

        await viewModel.load(provider: provider, accountID: "acct-1")

        XCTAssertEqual(provider.lastListAccountID, "acct-1")
        XCTAssertEqual(provider.lastListPath, "/Vaults")
        XCTAssertEqual(provider.lastListQuery, "personal")
        XCTAssertEqual(viewModel.files, provider.filesToReturn)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadSetsErrorAndClearsFilesOnFailure() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: nil)
        provider.filesToReturn = [
            CloudFile(
                id: "existing",
                name: "existing.kdbx",
                path: "/existing.kdbx",
                isFolder: false,
                modifiedDate: nil,
                size: nil
            )
        ]

        await viewModel.load(provider: provider, accountID: "acct-1")

        provider.listError = CloudProviderError.fileNotFound
        await viewModel.load(provider: provider, accountID: "acct-1")

        XCTAssertEqual(viewModel.errorMessage, CloudProviderError.fileNotFound.localizedDescription)
        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadPassesNilQueryWhenSearchTextIsOnlyWhitespace() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        viewModel.searchText = "   "

        await viewModel.load(provider: provider, accountID: "acct-1")

        XCTAssertNil(provider.lastListQuery)
    }

    func testBrowserSessionAuthenticateRefreshesAccountsAndSelectsAuthenticatedAccount() async {
        let provider = MockBrowserCloudProvider()
        let account = CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: provider.id)
        provider.authenticateResult = .success(account)
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }

        let result = await session.authenticate {
            ASPresentationAnchor()
        }

        switch result {
        case .authenticated(let authenticatedAccount):
            XCTAssertEqual(authenticatedAccount, account)
        default:
            XCTFail("Expected authentication success")
        }

        XCTAssertEqual(session.accounts, [account])
        XCTAssertEqual(session.selectedAccountID, account.id)
        XCTAssertFalse(session.isAuthenticating)
    }

    func testBrowserSessionAuthenticateReturnsCancelledWithoutDismissingState() async {
        let provider = MockBrowserCloudProvider()
        provider.authenticateResult = .failure(CloudProviderError.authenticationCancelled)
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }

        let result = await session.authenticate {
            ASPresentationAnchor()
        }

        switch result {
        case .cancelled:
            break
        default:
            XCTFail("Expected authentication cancellation")
        }

        XCTAssertTrue(session.accounts.isEmpty)
        XCTAssertNil(session.selectedAccountID)
        XCTAssertFalse(session.isAuthenticating)
    }

    func testBrowserSessionCancelPendingAuthenticationDelegatesToProvider() {
        let provider = MockBrowserCloudProvider()
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }

        session.cancelPendingAuthentication()

        XCTAssertEqual(provider.cancelPendingAuthenticationCallCount, 1)
    }
}

private final class MockBrowserCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    var authenticateResult: Result<CloudAccount, Error> = .success(
        CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: CloudProviderKind.dropbox.rawValue)
    )
    var filesToReturn: [CloudFile] = []
    var listError: Error?
    private(set) var lastListAccountID: String?
    private(set) var lastListPath: String?
    private(set) var lastListQuery: String?
    private(set) var cancelPendingAuthenticationCallCount = 0

    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        let account = try authenticateResult.get()
        CloudAccountStore.upsert(account)
        return account
    }

    func cancelPendingAuthentication() {
        cancelPendingAuthenticationCallCount += 1
    }

    func isAuthenticated(accountId: String) -> Bool {
        true
    }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        lastListAccountID = accountId
        lastListPath = path
        lastListQuery = query

        if let listError {
            throw listError
        }

        return filesToReturn
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {}

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        CloudFileMetadata(modifiedDate: Date(), contentHash: nil, size: 0)
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        progress(1)
        return CloudFileMetadata(
            modifiedDate: Date(),
            contentHash: nil,
            size: Int64(data.count),
            rev: expectedRev
        )
    }
}
