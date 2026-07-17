import Foundation
import XCTest
@testable import KeeForge

final class CloudProviderTests: XCTestCase {
    func testMessageReturnsCloudProviderDescription() {
        XCTAssertEqual(
            CloudProviderError.message(for: CloudProviderError.notAuthenticated),
            String(localized: "Please reconnect this cloud account.")
        )
    }

    func testMessageFallsBackToNSErrorLocalizedDescription() {
        let error = NSError(domain: "UnitTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unit failure"])

        XCTAssertEqual(CloudProviderError.message(for: error), "Unit failure")
    }

    func testIsLikelyOfflineReturnsTrueForCloudOfflineError() {
        XCTAssertTrue(CloudProviderError.isLikelyOffline(CloudProviderError.networkUnavailable))
    }

    func testIsLikelyOfflineReturnsTrueForURLError() {
        XCTAssertTrue(CloudProviderError.isLikelyOffline(URLError(.notConnectedToInternet)))
    }

    func testIsLikelyOfflineReturnsFalseForOtherErrors() {
        XCTAssertFalse(CloudProviderError.isLikelyOffline(CloudProviderError.fileNotFound))
    }
}
