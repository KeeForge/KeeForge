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

    func testConcurrentProvidersPreserveEveryAccountAndCannotUndoSignOut() throws {
        let signedOut = CloudAccount(id: "signed-out", displayName: "Drive", provider: "googledrive")
        CloudAccountStore.upsert(signedOut)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 4) {
                CloudAccountStore.remove(provider: signedOut.provider, accountId: signedOut.id)
            }
            CloudAccountStore.upsert(CloudAccount(id: "account-\(index)", displayName: "Server \(index)", provider: "webdav"))
        }

        XCTAssertNil(CloudAccountStore.account(provider: signedOut.provider, accountId: signedOut.id))
        XCTAssertEqual(CloudAccountStore.accounts(for: "webdav").count, 64)
        let persisted = try XCTUnwrap(SharedVaultStore.cloudAccountDefaults.data(forKey: "KeeForge.cloudAccounts"))
        let reloaded = try JSONDecoder().decode([CloudAccount].self, from: persisted)
        XCTAssertFalse(reloaded.contains(signedOut))
        XCTAssertEqual(reloaded.count, 64)
    }

}
