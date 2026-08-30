import XCTest
@testable import KeeForge

@MainActor
final class CloudProviderRegistryTests: XCTestCase {
    func testAvailableProvidersContainsCloudProviders() {
        #if os(macOS)
        // macOS ships WebDAV only: the Dropbox and OneDrive OAuth paths are
        // implemented but have never been validated end-to-end on a Mac, so
        // they stay out of the UI. Unhiding them is a later release's call.
        XCTAssertEqual(CloudProviderRegistry.availableProviders, [.webDAV])
        #else
        XCTAssertEqual(CloudProviderRegistry.availableProviders, [.dropbox, .oneDrive, .webDAV])
        #endif
    }

    func testCloudProviderPlatformAvailability() {
        #if os(macOS)
        XCTAssertFalse(CloudProviderKind.dropbox.isAvailableOnCurrentPlatform)
        XCTAssertFalse(CloudProviderKind.oneDrive.isAvailableOnCurrentPlatform)
        XCTAssertTrue(CloudProviderKind.webDAV.isAvailableOnCurrentPlatform)
        #else
        XCTAssertTrue(CloudProviderKind.dropbox.isAvailableOnCurrentPlatform)
        XCTAssertTrue(CloudProviderKind.oneDrive.isAvailableOnCurrentPlatform)
        XCTAssertTrue(CloudProviderKind.webDAV.isAvailableOnCurrentPlatform)
        #endif
    }

    func testProviderResolutionStaysUnfilteredForHiddenProviders() {
        #if os(macOS)
        // The Mac app does not compile either provider, so resolution is not
        // merely filtered — the types are absent. Nothing can have connected
        // one, because neither has ever been reachable from the Mac UI.
        XCTAssertNil(CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue))
        XCTAssertNil(CloudProviderRegistry.provider(for: CloudProviderKind.oneDrive.rawValue))
        #else
        // The UI gate must not affect provider(for:) resolution: an
        // already-connected Dropbox/OneDrive database must still resolve its
        // provider (and therefore stay openable) even on platforms where the
        // provider is hidden from the add/import UI.
        XCTAssertNotNil(CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue))
        XCTAssertNotNil(CloudProviderRegistry.provider(for: CloudProviderKind.oneDrive.rawValue))
        #endif
        XCTAssertNotNil(CloudProviderRegistry.provider(for: CloudProviderKind.webDAV.rawValue))
    }

    #if !os(macOS)
    func testProviderReturnsDropboxSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue)

        XCTAssertTrue(provider === DropboxCloudProvider.shared)
    }

    func testProviderReturnsOneDriveSharedInstance() {
        let provider = CloudProviderRegistry.provider(for: CloudProviderKind.oneDrive.rawValue)

        XCTAssertTrue(provider === OneDriveCloudProvider.shared)
    }
    #endif

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
