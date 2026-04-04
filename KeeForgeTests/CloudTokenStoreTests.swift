import XCTest
@testable import KeeForge

final class CloudTokenStoreTests: XCTestCase {
    override func tearDown() {
        cleanup(provider: "unit-cloud-token-a")
        cleanup(provider: "unit-cloud-token-b")
        super.tearDown()
    }

    func testSetGetAndDeleteTokenData() throws {
        let provider = "unit-cloud-token-a"
        let accountID = "acct-2"
        let data = Data("refresh-token".utf8)

        try requireTokenStoreWrite(data, provider: provider, accountId: accountID)
        XCTAssertEqual(CloudTokenStore.tokenData(provider: provider, accountId: accountID), data)
        XCTAssertEqual(CloudTokenStore.allAccountIDs(provider: provider), [accountID])
        XCTAssertTrue(CloudTokenStore.deleteToken(provider: provider, accountId: accountID))
        XCTAssertNil(CloudTokenStore.tokenData(provider: provider, accountId: accountID))
    }

    func testAllAccountIDsAreSortedAndScopedPerProvider() throws {
        try requireTokenStoreWrite(Data("b".utf8), provider: "unit-cloud-token-a", accountId: "b-account")
        try requireTokenStoreWrite(Data("a".utf8), provider: "unit-cloud-token-a", accountId: "a-account")
        try requireTokenStoreWrite(Data("other".utf8), provider: "unit-cloud-token-b", accountId: "z-account")

        XCTAssertEqual(
            CloudTokenStore.allAccountIDs(provider: "unit-cloud-token-a"),
            ["a-account", "b-account"]
        )
        XCTAssertEqual(
            CloudTokenStore.allAccountIDs(provider: "unit-cloud-token-b"),
            ["z-account"]
        )
    }

    private func cleanup(provider: String) {
        for accountID in CloudTokenStore.allAccountIDs(provider: provider) {
            _ = CloudTokenStore.deleteToken(provider: provider, accountId: accountID)
        }
    }

    private func requireTokenStoreWrite(_ data: Data, provider: String, accountId: String) throws {
        guard CloudTokenStore.setTokenData(data, provider: provider, accountId: accountId) else {
            throw XCTSkip("Keychain writes are unavailable in the current test host.")
        }
    }
}
