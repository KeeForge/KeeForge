import XCTest
@testable import KeeForge

final class CloudAccountStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testUpsertAddsAndFetchesAccount() {
        let account = CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: "dropbox")

        CloudAccountStore.upsert(account)

        XCTAssertEqual(CloudAccountStore.accounts, [account])
        XCTAssertEqual(CloudAccountStore.account(provider: "dropbox", accountId: "acct-1"), account)
        XCTAssertTrue(CloudAccountStore.isConnected(provider: "dropbox", accountId: "acct-1"))
    }

    func testUpsertReplacesExistingAccountWithSameProviderAndID() {
        CloudAccountStore.upsert(CloudAccount(id: "acct-1", displayName: "Old Name", provider: "dropbox"))
        CloudAccountStore.upsert(CloudAccount(id: "acct-1", displayName: "New Name", provider: "dropbox"))

        XCTAssertEqual(CloudAccountStore.accounts.count, 1)
        XCTAssertEqual(CloudAccountStore.accounts.first?.displayName, "New Name")
    }

    func testAccountsForProviderFiltersAndSortsByDisplayName() {
        CloudAccountStore.upsert(CloudAccount(id: "2", displayName: "zoe@example.com", provider: "dropbox"))
        CloudAccountStore.upsert(CloudAccount(id: "1", displayName: "alex@example.com", provider: "dropbox"))
        CloudAccountStore.upsert(CloudAccount(id: "3", displayName: "drive@example.com", provider: "google-drive"))

        XCTAssertEqual(
            CloudAccountStore.accounts(for: "dropbox").map(\.displayName),
            ["alex@example.com", "zoe@example.com"]
        )
    }

    func testRemoveDeletesOnlyMatchingAccount() {
        CloudAccountStore.upsert(CloudAccount(id: "acct-1", displayName: "Alex", provider: "dropbox"))
        CloudAccountStore.upsert(CloudAccount(id: "acct-2", displayName: "Taylor", provider: "dropbox"))

        CloudAccountStore.remove(provider: "dropbox", accountId: "acct-1")

        XCTAssertNil(CloudAccountStore.account(provider: "dropbox", accountId: "acct-1"))
        XCTAssertNotNil(CloudAccountStore.account(provider: "dropbox", accountId: "acct-2"))
    }

    func testClearAllRemovesStoredAccounts() {
        CloudAccountStore.upsert(CloudAccount(id: "acct-1", displayName: "Alex", provider: "dropbox"))

        CloudAccountStore.clearAll()

        XCTAssertTrue(CloudAccountStore.accounts.isEmpty)
    }

    // MARK: - macOS group-suite migration (platform-independent, injected defaults)

    private static let migrationStorageKey = "KeeForge.cloudAccounts"

    private func makeIsolatedDefaults(_ label: String) throws -> UserDefaults {
        let suiteName = "CloudAccountStoreTests.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func encodedAccounts(_ accounts: [CloudAccount]) throws -> Data {
        try JSONEncoder().encode(accounts)
    }

    func testMigrateAccountsCopiesLegacyValueAndScrubsSource() throws {
        let source = try makeIsolatedDefaults("source")
        let destination = try makeIsolatedDefaults("destination")
        let legacy = try encodedAccounts(
            [CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: "dropbox")]
        )
        source.set(legacy, forKey: Self.migrationStorageKey)

        CloudAccountStore.migrateAccounts(from: source, to: destination)

        XCTAssertNil(source.data(forKey: Self.migrationStorageKey), "legacy PII should be scrubbed from the group suite")
        XCTAssertEqual(destination.data(forKey: Self.migrationStorageKey), legacy)
    }

    func testMigrateAccountsDoesNotClobberExistingDestinationValue() throws {
        let source = try makeIsolatedDefaults("source")
        let destination = try makeIsolatedDefaults("destination")
        let legacy = try encodedAccounts(
            [CloudAccount(id: "old", displayName: "old@example.com", provider: "dropbox")]
        )
        let current = try encodedAccounts(
            [CloudAccount(id: "new", displayName: "new@example.com", provider: "webdav")]
        )
        source.set(legacy, forKey: Self.migrationStorageKey)
        destination.set(current, forKey: Self.migrationStorageKey)

        CloudAccountStore.migrateAccounts(from: source, to: destination)

        XCTAssertEqual(destination.data(forKey: Self.migrationStorageKey), current, "existing destination value must win")
        XCTAssertNil(source.data(forKey: Self.migrationStorageKey), "legacy PII should still be scrubbed from the group suite")
    }

    func testMigrateAccountsIsNoOpWhenSourceHasNoValue() throws {
        let source = try makeIsolatedDefaults("source")
        let destination = try makeIsolatedDefaults("destination")
        let current = try encodedAccounts(
            [CloudAccount(id: "new", displayName: "new@example.com", provider: "webdav")]
        )
        destination.set(current, forKey: Self.migrationStorageKey)

        CloudAccountStore.migrateAccounts(from: source, to: destination)

        XCTAssertEqual(destination.data(forKey: Self.migrationStorageKey), current)
        XCTAssertNil(source.data(forKey: Self.migrationStorageKey))
    }
}
