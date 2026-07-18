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

    func testSupersededSlowLoadDoesNotClobberNewerResults() async {
        let provider = GatedBrowserCloudProvider()
        let startedGate = AsyncGate()
        let releaseGate = AsyncGate()
        let staleFiles = [
            CloudFile(id: "stale", name: "stale.kdbx", path: "/stale.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        let freshFiles = [
            CloudFile(id: "fresh", name: "fresh.kdbx", path: "/fresh.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        provider.responses = [
            { startedGate.open(); await releaseGate.wait(); return staleFiles },
            { freshFiles }
        ]
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")

        let slowLoad = Task { await viewModel.load(provider: provider, accountID: "acct-1") }
        // The slow load has reached listFiles (generation 1) and is parked.
        await startedGate.wait()

        // A newer request completes first and owns the published state.
        await viewModel.load(provider: provider, accountID: "acct-1")
        XCTAssertEqual(viewModel.files, freshFiles)

        // Releasing the stale request must not clobber the newer results.
        releaseGate.open()
        await slowLoad.value

        XCTAssertEqual(viewModel.files, freshFiles)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testCancelledLoadDoesNotClobberOrSurfaceError() async {
        let provider = GatedBrowserCloudProvider()
        let startedGate = AsyncGate()
        let releaseGate = AsyncGate()
        provider.responses = [
            {
                startedGate.open()
                await releaseGate.wait()
                return [
                    CloudFile(id: "late", name: "late.kdbx", path: "/late.kdbx", isFolder: false, modifiedDate: nil, size: nil)
                ]
            }
        ]
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")

        let load = Task { await viewModel.load(provider: provider, accountID: "acct-1") }
        await startedGate.wait()
        load.cancel()
        releaseGate.open()
        await load.value

        // A cancelled task must not publish results or a spurious error.
        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadDoesNotSurfaceCancellationErrorAsUserFacingMessage() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: nil)
        let seededFiles = [
            CloudFile(id: "seed", name: "seed.kdbx", path: "/seed.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        provider.filesToReturn = seededFiles
        await viewModel.load(provider: provider, accountID: "acct-1")
        XCTAssertEqual(viewModel.files, seededFiles)

        provider.listError = CancellationError()
        await viewModel.load(provider: provider, accountID: "acct-1")

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.files, seededFiles)
        XCTAssertFalse(viewModel.isLoading)
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

    func testBrowserSessionUsesManualConnectionFormForWebDAVProvider() {
        let webDAVSession = CloudFileBrowserSession(providerID: CloudProviderKind.webDAV.rawValue) { _ in nil }
        let dropboxSession = CloudFileBrowserSession(providerID: CloudProviderKind.dropbox.rawValue) { _ in nil }

        XCTAssertTrue(webDAVSession.usesManualConnectionForm)
        XCTAssertFalse(dropboxSession.usesManualConnectionForm)
    }

    func testBrowserSessionAdoptManualAccountRefreshesAndSelectsAccount() {
        let account = CloudAccount(
            id: "webdav-abc",
            displayName: "alex@cloud.example.com",
            provider: CloudProviderKind.webDAV.rawValue
        )
        CloudAccountStore.upsert(account)
        let session = CloudFileBrowserSession(providerID: CloudProviderKind.webDAV.rawValue) { _ in nil }

        session.adoptManualAccount(account)

        XCTAssertEqual(session.accounts, [account])
        XCTAssertEqual(session.selectedAccountID, account.id)
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

/// A one-shot gate for deterministically ordering concurrent async work in tests.
/// `open()` may be called before `wait()`; the waiter resumes immediately in that case.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }
}

/// A provider whose `listFiles` returns a scripted, per-call response, letting tests
/// hold one call open while a later call completes first.
private final class GatedBrowserCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    private let lock = NSLock()
    private var index = 0
    var responses: [@Sendable () async -> [CloudFile]] = []

    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: id)
    }

    func cancelPendingAuthentication() {}

    func isAuthenticated(accountId: String) -> Bool { true }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        // The lock guards only the synchronous cursor advance (no await inside
        // the critical section). Swift 6 forbids calling NSLock.lock() directly
        // from an async context, so take/advance in a synchronous helper.
        let response = nextResponse()
        return await response()
    }

    private func nextResponse() -> @Sendable () async -> [CloudFile] {
        lock.lock()
        defer { lock.unlock() }
        let response = responses[index]
        index += 1
        return response
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
        CloudFileMetadata(modifiedDate: Date(), contentHash: nil, size: Int64(data.count), rev: expectedRev)
    }
}
