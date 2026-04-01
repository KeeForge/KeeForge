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
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
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

    private func makeViewModel() throws -> DatabaseViewModel {
        DatabaseViewModel(databaseReference: try makeReference())
    }

    private func makeReference() throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(for: fixtureURL())
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
}
