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
}
