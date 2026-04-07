import AuthenticationServices
import CryptoKit
import SwiftUI
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseViewModelTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        CredentialIdentityStoreManager.populateObserver = nil
        try await super.tearDown()
    }

    func testInitialStateIsLockedWithSavedDatabaseReference() throws {
        let vm = try makeViewModel()

        XCTAssertState(vm.state, is: .locked)
        XCTAssertTrue(vm.hasSavedFile)
        XCTAssertFalse(vm.canUseBiometrics)
        XCTAssertEqual(vm.lockCycleID, 0)
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testUnlockWithCorrectPasswordTransitionsToUnlocked() async throws {
        let vm = try makeViewModel()

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.rootGroup)
        XCTAssertFalse(vm.rootGroup?.allEntries.isEmpty ?? true)
    }

    func testUnlockCachesPerDatabaseCopy() async throws {
        let reference = try makeReference()
        let vm = DatabaseViewModel(databaseReference: reference)
        let sourceURL = try fixtureURL()

        await vm.unlock(password: fixturePassword)

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(cachedURL.lastPathComponent, "\(reference.id.uuidString).kdbx")
        XCTAssertEqual(try Data(contentsOf: cachedURL), try Data(contentsOf: sourceURL))
    }

    func testUnlockCapturesOpenTimeSHA512() async throws {
        let vm = try makeViewModel()
        let expectedHash = KDBXCrypto.sha512(try Data(contentsOf: fixtureURL()))

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.openTimeSHA512, expectedHash)
    }

    func testUnlockFallsBackToCachedCopyWhenBookmarkCannotBeResolved() async throws {
        var reference = try makeReference()
        reference.bookmarkData = Data("invalid-bookmark".utf8)

        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL()), for: reference.id)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.rootGroup)
    }

    func testForegroundRefreshRepopulatesCredentialStoreWhenUnlocked() async throws {
        let vm = try makeViewModel()

        let refreshExpectation = expectation(description: "Credential store repopulated after refresh")
        var populateCallCount = 0
        CredentialIdentityStoreManager.populateObserver = { _ in
            populateCallCount += 1
            if populateCallCount == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)
        vm.refreshSharedDatabaseCacheIfPossible()

        await fulfillment(of: [refreshExpectation], timeout: 30)
        XCTAssertEqual(populateCallCount, 2)
    }

    func testCredentialStoreEntriesIncludePasskeyOnlyEntries() {
        let sessionKey = SymmetricKey(size: .bits256)
        let passwordEntry = KPEntry(
            title: "Password Entry",
            username: "alice",
            password: try! EncryptedValue.encrypt("secret", using: sessionKey),
            url: "https://example.com"
        )
        let passkeyEntry = KPEntry(
            title: "Passkey Entry",
            username: "",
            password: .empty,
            url: "https://example.com",
            customFields: passkeyFields()
        )
        let noteEntry = KPEntry(title: "Note Entry", username: "", password: .empty, url: "")
        let root = KPGroup(name: "Root", entries: [passwordEntry, passkeyEntry, noteEntry])

        let identities = DatabaseViewModel.credentialStoreEntries(from: root)

        XCTAssertEqual(Set(identities.map(\.id)), Set([passwordEntry.id, passkeyEntry.id]))
    }

    func testUnlockWithWrongPasswordTransitionsToError() async throws {
        let vm = try makeViewModel()

        await vm.unlock(password: "wrong-password")

        guard case .error(let message) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(vm.rootGroup)
    }

    func testCloudUnlockShowsProviderSpecificSyncMessageBeforeDecryption() async throws {
        let reference = makeCloudReference()
        let data = try Data(contentsOf: fixtureURL())
        let syncStarted = expectation(description: "Cloud sync started")
        let gate = AsyncGate()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                await gate.pause(started: syncStarted)
                return CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: data,
                    status: .downloaded
                )
            }
        )

        let unlockTask = Task {
            await vm.unlock(password: fixturePassword)
        }

        await fulfillment(of: [syncStarted], timeout: 1)
        await gate.waitUntilPaused()

        XCTAssertState(vm.state, is: .unlocking)
        XCTAssertEqual(vm.unlockStatusMessage, "Syncing with Dropbox...")

        await gate.resume()
        await unlockTask.value

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.unlockStatusMessage, "Decrypting your database securely...")
    }

    func testCloudUnlockShowsOfflineBannerWhenCachedCopyDecryptsSuccessfully() async throws {
        let reference = makeCloudReference()
        let data = try Data(contentsOf: fixtureURL())
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: data,
                    status: .offlineCached
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.cloudSyncBannerText, "Using the cached copy offline.")
    }

    func testCloudUnlockTransitionsToErrorWhenSyncFails() async {
        let vm = DatabaseViewModel(
            databaseReference: makeCloudReference(),
            cloudSyncOperation: { _, _ in
                throw CloudProviderError.fileNotFound
            }
        )

        await vm.unlock(password: fixturePassword)

        guard case .error(let message) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertEqual(message, CloudProviderError.fileNotFound.localizedDescription)
        XCTAssertNil(vm.rootGroup)
    }

    func testCloudUnlockTransitionsToErrorWhenDownloadedDataCannotBeParsed() async {
        let reference = makeCloudReference()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: Data("not-a-kdbx".utf8),
                    status: .downloaded
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        guard case .error(let message) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(vm.cloudSyncBannerText)
    }

    func testSearchResultsMatchesEntryFieldsCaseInsensitively() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        guard case .unlocked = vm.state else {
            XCTFail("Expected unlocked state before search")
            return
        }

        let allEntries = vm.rootGroup?.allEntries ?? []
        let entryByTitle = allEntries.first(where: { !$0.title.isEmpty })
        let entryByUsername = allEntries.first(where: { !$0.username.isEmpty })
        let entryByURL = allEntries.first(where: { !$0.url.isEmpty })
        let entryByNotes = allEntries.first(where: { !$0.notes.isEmpty })

        if let entryByTitle {
            vm.searchText = mixedCasePrefix(from: entryByTitle.title)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByTitle.id }))
        }

        if let entryByUsername {
            vm.searchText = mixedCasePrefix(from: entryByUsername.username)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByUsername.id }))
        }

        if let entryByURL {
            vm.searchText = mixedCasePrefix(from: entryByURL.url)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByURL.id }))
        }

        if let entryByNotes {
            vm.searchText = mixedCasePrefix(from: entryByNotes.notes)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByNotes.id }))
        }

        vm.searchText = ""
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "___no_match___"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testLockClearsSensitiveAndNavigationState() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        vm.searchText = "query"
        vm.navigationPath.append("pushed")

        vm.lock()

        XCTAssertState(vm.state, is: .locked)
        XCTAssertNil(vm.rootGroup)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    func testSaveOnCleanDraftIsNoOp() async throws {
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        let originalHash = vm.openTimeSHA512
        vm.draft = try makeCleanDraft(from: vm)

        try await vm.save()

        XCTAssertFalse(localSaverCalls.didCall)
        XCTAssertEqual(vm.openTimeSHA512, originalHash)
        XCTAssertNotNil(vm.draft)
    }

    func testSaveOnDirtyDraftReplacesRootClearsDraft() async throws {
        let savedHash = Data("saved-hash".utf8)
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _ in
                .saved(newSHA512: savedHash)
            }
        )

        await vm.unlock(password: fixturePassword)
        let dirtyDraft = try makeDirtyDraft(from: vm, entryTitle: "Saved Entry")
        let expectedTitles = dirtyDraft.rootGroup.allEntries.map(\.title).sorted()
        vm.draft = dirtyDraft

        try await vm.save()

        XCTAssertEqual(vm.rootGroup?.allEntries.map(\.title).sorted(), expectedTitles)
        XCTAssertNil(vm.draft)
        XCTAssertEqual(vm.openTimeSHA512, savedHash)
    }

    func testSaveOnConflictSetsSaveConflictDoesNotClearDraft() async throws {
        let remoteData = Data("remote".utf8)
        let remoteHash = KDBXCrypto.sha512(remoteData)
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _ in
                .conflict(remoteSHA512: remoteHash, remoteData: remoteData)
            }
        )

        await vm.unlock(password: fixturePassword)
        let dirtyDraft = try makeDirtyDraft(from: vm, entryTitle: "Conflicted Entry")
        vm.draft = dirtyDraft

        try await vm.save()

        XCTAssertEqual(
            vm.saveConflict,
            SaveConflict(remoteSHA512: remoteHash, remoteData: remoteData)
        )
        XCTAssertNotNil(vm.draft)
    }

    func testSaveWhenReadOnlyThrowsDatabaseIsReadOnlyDoesNotEncrypt() async throws {
        var reference = try makeReference()
        reference.isReadOnly = true

        let localSaverCalls = CallTracker()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Read Only Entry")

        do {
            try await vm.save()
            XCTFail("Expected save to throw when the database is read-only.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testAcknowledgeEditingIfNeededLocalUnsyncedReturnsAcknowledgedImmediately() async throws {
        var reference = try makeReference()
        reference.bookmarkData = nil

        let vm = DatabaseViewModel(
            databaseReference: reference,
            syncedFolderDetector: { _ in
                XCTFail("Synced folder detection should not run when there is no bookmark.")
                return .dropbox
            }
        )

        let result = await vm.acknowledgeEditingIfNeeded()

        XCTAssertEqual(result, .acknowledged)
        XCTAssertNil(vm.syncedFolderWarning)
    }

    func testAcknowledgeEditingIfNeededAlreadyAcknowledgedReturnsAcknowledgedImmediately() async throws {
        var reference = try makeReference()
        reference.editsAcknowledgedAt = Date(timeIntervalSince1970: 10)

        let vm = DatabaseViewModel(
            databaseReference: reference,
            syncedFolderDetector: { _ in
                XCTFail("Synced folder detection should not run after acknowledgment.")
                return .dropbox
            },
            syncedFolderWarningHandler: { _ in
                XCTFail("Warning handler should not run after acknowledgment.")
                return .continueEditing
            }
        )

        let result = await vm.acknowledgeEditingIfNeeded()

        XCTAssertEqual(result, .acknowledged)
    }

    func testAcknowledgeEditingIfNeededDropboxPromptsAndPersistsAcknowledgment() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)

        var capturedWarning: SyncedFolderWarning?
        let vm = DatabaseViewModel(
            databaseReference: reference,
            syncedFolderDetector: { _ in .dropbox },
            syncedFolderWarningHandler: { warning in
                capturedWarning = warning
                return .continueEditing
            }
        )

        let result = await vm.acknowledgeEditingIfNeeded()
        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))

        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(capturedWarning?.title, "This database file is stored in Dropbox.")
        XCTAssertNotNil(updatedReference.editsAcknowledgedAt)
        XCTAssertNil(vm.syncedFolderWarning)
    }

    func testAcknowledgeEditingIfNeededDropboxKeepReadOnlySetsFlagReturnsKeptReadOnly() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)

        let vm = DatabaseViewModel(
            databaseReference: reference,
            syncedFolderDetector: { _ in .dropbox },
            syncedFolderWarningHandler: { _ in .keepReadOnly }
        )

        let result = await vm.acknowledgeEditingIfNeeded()
        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))

        XCTAssertEqual(result, .keptReadOnly)
        XCTAssertTrue(updatedReference.isReadOnly)
        XCTAssertTrue(vm.isReadOnly)
    }

    private func makeViewModel(
        reference: DatabaseReference? = nil,
        cloudSyncOperation: @escaping DatabaseViewModel.CloudSyncOperation = { reference, progress in
            try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                progress: progress
            )
        },
        localSaveOperation: @escaping DatabaseViewModel.LocalSaveOperation = { draft, reference, compositeKey, openTimeSHA512 in
            try await LocalDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512
            )
        },
        syncedFolderDetector: @escaping DatabaseViewModel.SyncedFolderDetectionOperation = { _ in
            .notSynced
        },
        syncedFolderWarningHandler: @escaping DatabaseViewModel.SyncedFolderWarningHandler = { _ in
            .continueEditing
        }
    ) throws -> DatabaseViewModel {
        let resolvedReference = if let reference {
            reference
        } else {
            try makeReference()
        }

        return DatabaseViewModel(
            databaseReference: resolvedReference,
            cloudSyncOperation: cloudSyncOperation,
            localSaveOperation: localSaveOperation,
            syncedFolderDetector: syncedFolderDetector,
            syncedFolderWarningHandler: syncedFolderWarningHandler
        )
    }

    private func makeCloudReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }

    private func makeReference() throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(for: fixtureURL())
    }

    private func makeCleanDraft(from viewModel: DatabaseViewModel) throws -> DatabaseDraft {
        guard let rootGroup = viewModel.rootGroup else {
            throw TestError.missingRootGroup
        }
        guard let sessionKey = viewModel.sessionKey else {
            throw TestError.missingSessionKey
        }

        return DatabaseDraft(
            rootGroup: rootGroup,
            meta: KPMeta(
                recycleBinUUID: rootGroup.recycleBinUUID,
                hasRecycleBinUUIDElement: rootGroup.recycleBinUUID != nil
            ),
            sessionKey: sessionKey
        )
    }

    private func makeDirtyDraft(
        from viewModel: DatabaseViewModel,
        entryTitle: String
    ) throws -> DatabaseDraft {
        let cleanDraft = try makeCleanDraft(from: viewModel)
        return try cleanDraft.apply(
            .createEntry(
                parentGroupID: cleanDraft.rootGroup.id,
                draft: EntryDraftPayload(
                    title: entryTitle,
                    password: "secret-\(entryTitle)"
                )
            )
        )
    }

    private func fixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: DatabaseViewModelTests.self))
    }

    private func passkeyFields() -> [String: String] {
        [
            PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.privateKeyPEMKey: "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
    }

    private func mixedCasePrefix(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(4))
        guard !prefix.isEmpty else { return source }
        return prefix.uppercased()
    }

    private func XCTAssertState(_ state: DatabaseViewModel.State, is expected: ExpectedState, file: StaticString = #filePath, line: UInt = #line) {
        switch (state, expected) {
        case (.locked, .locked), (.unlocking, .unlocking), (.unlocked, .unlocked):
            return
        case (.error, .error):
            return
        default:
            XCTFail("Unexpected state: \(state)", file: file, line: line)
        }
    }

    private enum ExpectedState {
        case locked
        case unlocking
        case unlocked
        case error
    }

    private enum TestError: Error {
        case missingRootGroup
        case missingSessionKey
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isPaused = false

    func pause(started: XCTestExpectation) async {
        isPaused = true
        started.fulfill()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async {
        while isPaused == false {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class CallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var didCall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callCount > 0
    }

    func recordCall() {
        lock.lock()
        callCount += 1
        lock.unlock()
    }
}

final class CloudSyncCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testSyncDownloadsFreshCopyWhenRemoteMetadataChanges() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)
        let progressRecorder = ProgressRecorder()

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider },
            progress: { progressRecorder.append($0) }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(resolution.data, Data("fresh-cloud-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertEqual(progressRecorder.values, [1])
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteContentHash, "new-hash")
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))),
            Data("fresh-cloud-copy".utf8)
        )
    }

    func testSyncReturnsCurrentWhenRemoteMetadataMatchesCachedCopy() async throws {
        let modifiedDate = Date(timeIntervalSince1970: 200)
        let reference = makeCloudReference(
            remoteContentHash: "same-hash",
            remoteModifiedAt: modifiedDate
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-current-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: modifiedDate,
                contentHash: "same-hash",
                size: 128
            )
        )

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .current)
        XCTAssertEqual(resolution.data, Data("cached-current-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
    }

    func testSyncFallsBackToCachedCopyWhenOffline() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-offline-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.networkUnavailable)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .offlineCached)
        XCTAssertEqual(resolution.data, Data("cached-offline-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, "Using the cached copy offline.")
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.networkUnavailable.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenProviderIsUnavailable() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-disconnected-copy".utf8), for: reference)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in nil }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-disconnected-copy".utf8))
        XCTAssertEqual(
            resolution.bannerMessage,
            "Using the cached copy. Reconnect this cloud account to refresh."
        )
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenAccountIsSignedOut() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-signed-out-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.authenticated = false

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-signed-out-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 0)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesCachedCopyWithErrorForNonOfflineFailures() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-error-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(
            resolution.status,
            .cachedWithError(CloudProviderError.fileNotFound.localizedDescription)
        )
        XCTAssertEqual(resolution.data, Data("cached-error-copy".utf8))
        XCTAssertEqual(
            resolution.bannerMessage,
            CloudProviderError.fileNotFound.localizedDescription
        )
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.fileNotFound.localizedDescription
        )
    }

    func testSyncThrowsWhenCachedFallbackIsDisabled() async {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try? DatabaseListStore.cacheDatabaseCopy(Data("cached-but-disabled".utf8), for: reference)
        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        do {
            _ = try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                allowCachedFallback: false,
                providerResolver: { _ in provider }
            )
            XCTFail("Expected sync to throw when cached fallback is disabled.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeCloudReference(
        remoteContentHash: String?,
        remoteModifiedAt: Date?
    ) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: remoteContentHash,
                    remoteModifiedAt: remoteModifiedAt,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }
}

private final class MockCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    var authenticated = true
    var metadataResult: Result<CloudFileMetadata, Error> = .failure(CloudProviderError.fileNotFound)
    var downloadedData = Data()
    private(set) var metadataCallCount = 0
    private(set) var downloadCallCount = 0

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        XCTFail("authenticate(from:) should not be called in CloudSyncCoordinatorTests")
        throw CloudProviderError.authenticationCancelled
    }

    func isAuthenticated(accountId: String) -> Bool {
        authenticated
    }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        XCTFail("listFiles(accountId:path:query:) should not be called in CloudSyncCoordinatorTests")
        return []
    }

    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloadCallCount += 1
        try downloadedData.write(to: localURL)
        progress(1)
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        metadataCallCount += 1
        return try metadataResult.get()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
