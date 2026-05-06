import XCTest
@testable import KeeForge

@MainActor
final class CloudProviderRegistryTests: XCTestCase {
    func testAvailableProvidersContainsCloudProviders() {
        XCTAssertEqual(CloudProviderRegistry.availableProviders, [.dropbox, .oneDrive])
    }

    func testProviderReturnsDropboxSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue)

        XCTAssertTrue(provider === DropboxCloudProvider.shared)
    }

    func testProviderReturnsOneDriveSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.oneDrive.rawValue)

        XCTAssertTrue(provider === OneDriveCloudProvider.shared)
    }

    func testProviderReturnsNilForUnknownProvider() {
        XCTAssertNil(CloudProviderRegistry.provider(for: "unknown"))
    }

    func testHandleOpenURLReturnsFalseForNonDropboxURL() {
        let url = URL(string: "https://example.com/callback")!

        XCTAssertFalse(CloudProviderRegistry.handleOpenURL(url))
    }

    func testAppInfoPlistIncludesMSALBrokerQuerySchemes() throws {
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])

        XCTAssertTrue(schemes.contains("msauthv2"))
        XCTAssertTrue(schemes.contains("msauthv3"))
    }
}
