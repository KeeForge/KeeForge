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

        XCTAssertEqual(
            viewModel.requestKey(accountID: "acct-1", includesAllFiles: false),
            "acct-1|/Vaults|vault|false"
        )
    }

    func testRequestKeyChangesWhenAllFilesAreShownSoTheListingReloads() {
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")

        XCTAssertNotEqual(
            viewModel.requestKey(accountID: "acct-1", includesAllFiles: false),
            viewModel.requestKey(accountID: "acct-1", includesAllFiles: true)
        )
    }

    func testLoadForwardsShowAllFilesToTheProviderAndPublishesNonKDBXFiles() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        provider.filesToReturn = [
            CloudFile(id: "/Vaults/vault.bin", name: "vault.bin", path: "/Vaults/vault.bin", isFolder: false, modifiedDate: nil, size: nil)
        ]

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)
        XCTAssertEqual(provider.lastListIncludesAllFiles, false)

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: true)
        XCTAssertEqual(provider.lastListIncludesAllFiles, true)
        XCTAssertEqual(viewModel.files.map(\.name), ["vault.bin"])
    }

    func testLoadUsesTrimmedQueryAndClearsPreviousErrorOnSuccess() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        provider.listError = CloudProviderError.fileNotFound

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

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

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

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

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

        provider.listError = CloudProviderError.fileNotFound
        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

        XCTAssertEqual(viewModel.errorMessage, CloudProviderError.fileNotFound.localizedDescription)
        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadPassesNilQueryWhenSearchTextIsOnlyWhitespace() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: "/Vaults")
        viewModel.searchText = "   "

        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

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

        let slowLoad = Task { await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false) }
        // The slow load has reached listFiles (generation 1) and is parked.
        await startedGate.wait()

        // A newer request completes first and owns the published state.
        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)
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

        let load = Task { await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false) }
        await startedGate.wait()
        load.cancel()
        releaseGate.open()
        await load.value

        // A cancelled task must not publish results or a spurious error.
        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAccountSwitchClearsPreviousFilesWhileNewAccountLoads() async {
        let provider = GatedBrowserCloudProvider()
        let startedGate = AsyncGate()
        let releaseGate = AsyncGate()
        let oldFiles = [
            CloudFile(id: "old", name: "old.kdbx", path: "/old.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        let newFiles = [
            CloudFile(id: "new", name: "new.kdbx", path: "/new.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        provider.responses = [
            { oldFiles },
            { startedGate.open(); await releaseGate.wait(); return newFiles }
        ]
        let viewModel = CloudFolderBrowserViewModel(path: nil)
        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)
        XCTAssertEqual(viewModel.files, oldFiles)

        let newLoad = Task { await viewModel.load(provider: provider, accountID: "acct-2", includesAllFiles: false) }
        await startedGate.wait()

        XCTAssertTrue(viewModel.files.isEmpty)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        releaseGate.open()
        await newLoad.value
        XCTAssertEqual(viewModel.files, newFiles)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOldAccountLoadCannotReplaceNewAccountFiles() async {
        let provider = GatedBrowserCloudProvider()
        let startedGate = AsyncGate()
        let releaseGate = AsyncGate()
        let oldFiles = [
            CloudFile(id: "old", name: "old.kdbx", path: "/old.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        let newFiles = [
            CloudFile(id: "new", name: "new.kdbx", path: "/new.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        provider.responses = [
            { startedGate.open(); await releaseGate.wait(); return oldFiles },
            { newFiles }
        ]
        let viewModel = CloudFolderBrowserViewModel(path: nil)
        let oldLoad = Task { await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false) }
        await startedGate.wait()
        await viewModel.load(provider: provider, accountID: "acct-2", includesAllFiles: false)

        releaseGate.open()
        await oldLoad.value
        XCTAssertEqual(viewModel.files, newFiles)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadDoesNotSurfaceCancellationErrorAsUserFacingMessage() async {
        let provider = MockBrowserCloudProvider()
        let viewModel = CloudFolderBrowserViewModel(path: nil)
        let seededFiles = [
            CloudFile(id: "seed", name: "seed.kdbx", path: "/seed.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        ]
        provider.filesToReturn = seededFiles
        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)
        XCTAssertEqual(viewModel.files, seededFiles)

        provider.listError = CancellationError()
        await viewModel.load(provider: provider, accountID: "acct-1", includesAllFiles: false)

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

    func testBrowserSessionUsesManualConnectionFormForWebDAVAndFTPProviders() {
        let webDAVSession = CloudFileBrowserSession(providerID: CloudProviderKind.webDAV.rawValue) { _ in nil }
        let ftpSession = CloudFileBrowserSession(providerID: CloudProviderKind.ftp.rawValue) { _ in nil }
        let dropboxSession = CloudFileBrowserSession(providerID: CloudProviderKind.dropbox.rawValue) { _ in nil }

        XCTAssertTrue(webDAVSession.usesManualConnectionForm)
        XCTAssertTrue(ftpSession.usesManualConnectionForm)
        XCTAssertFalse(dropboxSession.usesManualConnectionForm)
    }

    func testBrowserSessionAdoptManualAccountRefreshesAndSelectsAccount() {
        let account = CloudAccount(
            id: "webdav-abc",
            displayName: "alex@cloud.example.com",
            provider: CloudProviderKind.webDAV.rawValue
        )
        CloudAccountStore.upsert(account)
        let provider = MockBrowserCloudProvider(id: CloudProviderKind.webDAV.rawValue)
        let session = CloudFileBrowserSession(providerID: CloudProviderKind.webDAV.rawValue) { _ in provider }

        session.adoptManualAccount(account)

        XCTAssertEqual(session.accounts, [account])
        XCTAssertEqual(session.selectedAccountID, account.id)
    }

    func testIdleBrowserSessionDoesNotCancelAnotherSessionsAuthentication() {
        let provider = MockBrowserCloudProvider()
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }

        session.cancelPendingAuthentication()

        XCTAssertEqual(provider.cancelPendingAuthenticationCallCount, 0)
    }

    func testBrowserSessionRejectsSelectionFromPreviousAccount() {
        let firstAccount = CloudAccount(id: "acct-1", displayName: "First", provider: "dropbox")
        let secondAccount = CloudAccount(id: "acct-2", displayName: "Second", provider: "dropbox")
        let provider = MockBrowserCloudProvider()
        CloudAccountStore.upsert(firstAccount)
        CloudAccountStore.upsert(secondAccount)
        let session = CloudFileBrowserSession(providerID: "dropbox") { _ in provider }
        session.accounts = [firstAccount, secondAccount]
        session.selectedAccountID = firstAccount.id
        XCTAssertEqual(session.selectionAccount(matching: firstAccount.id), firstAccount)

        session.selectedAccountID = secondAccount.id

        XCTAssertNil(session.selectionAccount(matching: firstAccount.id))
        XCTAssertEqual(session.selectionAccount(matching: secondAccount.id), secondAccount)
        session.accounts = []
        XCTAssertNil(session.selectionAccount(matching: secondAccount.id))
    }
}

private final class MockBrowserCloudProvider: CloudProvider, @unchecked Sendable {
    let id: String
    init(id: String = CloudProviderKind.dropbox.rawValue) { self.id = id }
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
    private(set) var lastListIncludesAllFiles: Bool?
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

    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] {
        lastListAccountID = accountId
        lastListPath = path
        lastListQuery = query
        lastListIncludesAllFiles = includesAllFiles

        if let listError {
            throw listError
        }

        return filesToReturn
    }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? { nil }

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

    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] {
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

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? { nil }

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

@MainActor
final class CloudNativeSelectionWorkflowTests: XCTestCase {
    private func selection(_ id: String, account: String = "A") -> CloudDatabaseSelection {
        CloudDatabaseSelection(
            provider: "googledrive",
            account: CloudAccount(id: account, displayName: account, provider: "googledrive"),
            file: CloudFile(id: id, name: id + ".kdbx", path: id, isFolder: false, modifiedDate: nil, size: nil)
        )
    }

    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testImportUsesNativeGrantAndKeepsMultipleSelectionsUntilExplicitChoice() async {
        let provider = NativeSelectionTestProvider()
        let files = [selection("one"), selection("two")]
        provider.select = { expected in
            XCTAssertEqual(expected, "A")
            return files
        }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        session.accounts = [files[0].account]
        session.selectedAccountID = "A"
        let result = await session.selectFiles(expectedAccountID: "A") { ASPresentationAnchor() }
        guard case .selected(let returned) = result else { return XCTFail("Expected explicit grant") }
        XCTAssertEqual(returned, files)
        XCTAssertEqual(session.selectedFiles, files)
        XCTAssertEqual(provider.authenticateCalls, 0)
        XCTAssertEqual(provider.listCalls, 0)
        XCTAssertEqual(session.consumeSelection(files[1].file, accountID: "A"), files[1])
        XCTAssertNil(session.consumeSelection(files[0].file, accountID: "A"), "A consumed presentation cannot replay selection")
    }

    func testReconnectRejectsDifferentAccountAndMixedAccountSelections() async {
        for files in [[selection("one", account: "B")], [selection("one"), selection("two", account: "B")]] {
            let provider = NativeSelectionTestProvider()
            provider.select = { _ in files }
            let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
            session.accounts = [selection("old").account]
            session.selectedAccountID = "A"
            let result = await session.selectFiles(expectedAccountID: "A") { ASPresentationAnchor() }
            guard case .failed(let error) = result else { return XCTFail("Must reject mismatched grant") }
            XCTAssertEqual(error as? CloudProviderError, .permissionDenied)
            XCTAssertEqual(session.selectedAccountID, "A")
            XCTAssertTrue(session.selectedFiles.isEmpty)
        }
    }

    func testAccountOnlyDestinationConnectNeverCallsNativePickerOrListing() async {
        let provider = NativeSelectionTestProvider()
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        let result = await session.authenticate { ASPresentationAnchor() }
        guard case .authenticated(let account) = result else { return XCTFail("Empty Drive account can connect") }
        XCTAssertEqual(account.id, "A")
        XCTAssertEqual(provider.authenticateCalls, 1)
        XCTAssertEqual(provider.selectionCalls, 0)
        XCTAssertEqual(provider.listCalls, 0)
    }

    func testLatePickerCannotPublishAfterCancelDisappearAccountChangeOrSignout() async {
        for action in ["cancel", "disappear", "account", "signout", "task"] {
            let provider = NativeSelectionTestProvider()
            let entered = AsyncGate()
            let release = AsyncGate()
            let files = [selection("late")]
            provider.select = { _ in entered.open(); await release.wait(); return files }
            let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
            session.accounts = [files[0].account]
            session.selectedAccountID = "A"
            let task = Task { await session.selectFiles(expectedAccountID: "A") { ASPresentationAnchor() } }
            await entered.wait()
            switch action {
            case "cancel": session.cancelPendingAuthentication()
            case "disappear": session.disappear()
            case "account": session.selectedAccountID = "B"
            case "signout": provider.signOut(accountId: "A")
            default: task.cancel()
            }
            release.open()
            let result = await task.value
            if action == "signout" {
                guard case .failed = result else { return XCTFail("Signed-out account must fail") }
            } else {
                guard case .cancelled = result else { return XCTFail("Superseded picker must cancel") }
            }
            XCTAssertTrue(session.selectedFiles.isEmpty)
            XCTAssertEqual(session.selectedAccountID, action == "account" ? "B" : "A")
            XCTAssertFalse(session.isAuthenticating)
        }
    }

    func testSupersededPickerCannotReplaceNewSelectionOrClearItsBusyState() async {
        let provider = NativeSelectionTestProvider()
        let entered = AsyncGate()
        let release = AsyncGate()
        let old = [selection("old")]
        let fresh = [selection("fresh")]
        provider.select = { _ in entered.open(); await release.wait(); return old }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        let first = Task { await session.selectFiles(expectedAccountID: nil) { ASPresentationAnchor() } }
        await entered.wait()
        provider.select = { _ in fresh }
        _ = await session.selectFiles(expectedAccountID: nil) { ASPresentationAnchor() }
        release.open()
        guard case .cancelled = await first.value else { return XCTFail("Old request must cancel") }
        XCTAssertEqual(session.selectedFiles, fresh)
        XCTAssertEqual(session.selectedAccountID, "A")
        XCTAssertFalse(session.isAuthenticating)
    }

    func testPublishedGrantAndFolderAccountBecomeUnselectableAfterSignout() async {
        let provider = NativeSelectionTestProvider()
        let files = [selection("selected")]
        provider.select = { _ in files }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        _ = await session.selectFiles(expectedAccountID: nil) { ASPresentationAnchor() }
        provider.signOut(accountId: "A")
        XCTAssertNil(session.selectionAccount(matching: "A"))
        XCTAssertNil(session.consumeSelection(files[0].file, accountID: "A"))
    }

    func testAccountOnlyConnectAndManualAdoptionRejectPostAuthenticationSignout() async {
        let provider = NativeSelectionTestProvider()
        let entered = AsyncGate()
        let release = AsyncGate()
        let account = selection("existing").account
        provider.accountAuthorization = {
            CloudAccountStore.upsert(account)
            entered.open()
            await release.wait()
            return account
        }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        let task = Task { await session.authenticate { ASPresentationAnchor() } }
        await entered.wait()
        provider.signOut(accountId: account.id)
        release.open()
        guard case .failed = await task.value else { return XCTFail("Signed-out account cannot be adopted") }
        XCTAssertNil(session.selectedAccountID)
        session.adoptManualAccount(account)
        XCTAssertNil(session.selectedAccountID)
    }

    func testRemovedAccountRowCannotAuthorizePreviouslyPublishedGrant() async {
        let provider = NativeSelectionTestProvider()
        let files = [selection("selected")]
        provider.select = { _ in files }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        _ = await session.selectFiles(expectedAccountID: nil) { ASPresentationAnchor() }
        CloudAccountStore.remove(provider: provider.id, accountId: "A")
        XCTAssertNil(session.consumeSelection(files[0].file, accountID: "A"))
    }

    func testIdleSessionDisappearanceCannotCancelAnotherWindowsPicker() async {
        let provider = NativeSelectionTestProvider()
        let entered = AsyncGate()
        let release = AsyncGate()
        let files = [selection("selected")]
        provider.select = { _ in entered.open(); await release.wait(); return files }
        let owner = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        let idle = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        let task = Task { await owner.selectFiles(expectedAccountID: nil) { ASPresentationAnchor() } }
        await entered.wait()
        idle.disappear()
        XCTAssertEqual(provider.cancellationCalls, 0)
        release.open()
        guard case .selected = await task.value else { return XCTFail("Idle window must not cancel owner") }
        XCTAssertEqual(owner.selectedFiles, files)
    }

    func testNativeListingCannotAuthorizeUnpickedFileAndCancelledPickerHasNoFallback() async {
        let provider = NativeSelectionTestProvider()
        provider.select = { _ in throw CloudProviderError.authenticationCancelled }
        let session = CloudFileBrowserSession(providerID: provider.id) { _ in provider }
        session.accounts = [selection("listed").account]
        session.selectedAccountID = "A"
        guard case .cancelled = await session.selectFiles(expectedAccountID: "A", presentationAnchor: { ASPresentationAnchor() }) else {
            return XCTFail("Cancellation must remain cancellation")
        }
        XCTAssertNil(session.consumeSelection(selection("listed").file, accountID: "A"))
        XCTAssertEqual(provider.listCalls, 0)
    }
}

private final class NativeSelectionTestProvider: CloudFileSelecting, @unchecked Sendable {
    let id = "googledrive"
    let displayName = "Google Drive"
    let iconName = "externaldrive"
    @MainActor var select: (String?) async throws -> [CloudDatabaseSelection] = { _ in [] }
    @MainActor var accountAuthorization: (() async throws -> CloudAccount)?
    @MainActor private(set) var authenticateCalls = 0
    @MainActor private(set) var selectionCalls = 0
    @MainActor private(set) var cancellationCalls = 0
    @MainActor func cancelPendingAuthentication() { cancellationCalls += 1 }
    private(set) var listCalls = 0
    private var connected = true
    @MainActor init() {}

    @MainActor func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        authenticateCalls += 1
        if let accountAuthorization { return try await accountAuthorization() }
        let account = CloudAccount(id: "A", displayName: "A", provider: id)
        CloudAccountStore.upsert(account)
        return account
    }
    @MainActor func selectFiles(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> [CloudDatabaseSelection] {
        selectionCalls += 1
        let selections = try await select(expectedAccountID)
        selections.forEach { CloudAccountStore.upsert($0.account) }
        return selections
    }
    func isAuthenticated(accountId: String) -> Bool { connected }
    func signOut(accountId: String) { connected = false }
    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] {
        listCalls += 1
        return []
    }
    func download(accountId: String, fileId: String, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata? { nil }
    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata { throw CloudProviderError.fileNotFound }
    func upload(accountId: String, fileId: String, data: Data, expectedRev: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata { throw CloudProviderError.writeScopeRequired }
}
