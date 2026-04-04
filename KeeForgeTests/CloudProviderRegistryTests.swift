import XCTest
@testable import KeeForge

@MainActor
final class CloudProviderRegistryTests: XCTestCase {
    func testAvailableProvidersContainsDropbox() {
        XCTAssertEqual(CloudProviderRegistry.availableProviders, [.dropbox])
    }

    func testProviderReturnsDropboxSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue)

        XCTAssertTrue(provider === DropboxCloudProvider.shared)
    }

    func testProviderReturnsNilForUnknownProvider() {
        XCTAssertNil(CloudProviderRegistry.provider(for: "unknown"))
    }

    func testHandleOpenURLReturnsFalseForNonDropboxURL() {
        let url = URL(string: "https://example.com/callback")!

        XCTAssertFalse(CloudProviderRegistry.handleOpenURL(url))
    }
}
