import XCTest
@testable import KeeForge

@MainActor
final class CloudProviderRegistryTests: XCTestCase {
    func testAvailableProvidersContainsCloudProviders() {
        XCTAssertEqual(CloudProviderRegistry.availableProviders, [.dropbox, .oneDrive, .webDAV])
    }

    func testProviderReturnsDropboxSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue)

        XCTAssertTrue(provider === DropboxCloudProvider.shared)
    }

    func testProviderReturnsOneDriveSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.oneDrive.rawValue)

        XCTAssertTrue(provider === OneDriveCloudProvider.shared)
    }

    func testProviderReturnsWebDAVSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.webDAV.rawValue)

        XCTAssertTrue(provider === WebDAVCloudProvider.shared)
    }

    func testProviderReturnsNilForUnknownProvider() {
        XCTAssertNil(CloudProviderRegistry.provider(for: "unknown"))
    }

    func testHandleOpenURLReturnsFalseForNonDropboxURL() {
        let url = URL(string: "https://example.com/callback")!

        XCTAssertFalse(CloudProviderRegistry.handleOpenURL(url))
    }

    // #if os(iOS): `LSApplicationQueriesSchemes` is the iOS-only `canOpenURL`
    // allowlist required by the MSAL broker (Microsoft Authenticator). It is
    // meaningless on macOS, where the Mac Info.plist intentionally omits it;
    // the macOS MSAL auth flow lands in slice 03 of the macOS port.
    #if os(iOS)
    func testAppInfoPlistIncludesMSALBrokerQuerySchemes() throws {
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])

        XCTAssertTrue(schemes.contains("msauthv2"))
        XCTAssertTrue(schemes.contains("msauthv3"))
    }
    #endif
}
