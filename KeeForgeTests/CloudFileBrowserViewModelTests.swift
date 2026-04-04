import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class CloudFileBrowserViewModelTests: XCTestCase {
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
}

private final class MockBrowserCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    var filesToReturn: [CloudFile] = []
    var listError: Error?
    private(set) var lastListAccountID: String?
    private(set) var lastListPath: String?
    private(set) var lastListQuery: String?

    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: id)
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
}
