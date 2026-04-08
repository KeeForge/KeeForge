@preconcurrency import SwiftyDropbox
import XCTest
@testable import KeeForge

final class DropboxCloudProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudAccountStore.clearAll()
    }

    override func tearDown() {
        CloudAccountStore.clearAll()
        super.tearDown()
    }

    func testAuthenticateRequestsWriteScope() {
        let scopeRequest = DropboxCloudProvider.makeScopeRequest()

        XCTAssertEqual(scopeRequest.scopes, DropboxCloudProvider.requestedScopes)
        XCTAssertTrue(scopeRequest.scopes.contains("files.content.write"))
        XCTAssertEqual(scopeRequest.includeGrantedScopes, false)
    }

    func testHasWriteScopeReflectsStoredUpgradeState() {
        let provider = DropboxCloudProvider.shared
        let accountID = "acct-1"

        XCTAssertFalse(provider.hasWriteScope(accountId: accountID))

        CloudAccountStore.setDropboxWriteScope(true, accountId: accountID)
        XCTAssertTrue(provider.hasWriteScope(accountId: accountID))

        CloudAccountStore.setDropboxWriteScope(false, accountId: accountID)
        XCTAssertFalse(provider.hasWriteScope(accountId: accountID))
    }
}
