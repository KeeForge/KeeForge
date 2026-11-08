import XCTest
@testable import KeeForge

@MainActor
final class CloudProviderIntegrationTests: XCTestCase {
    func testGoogleDriveResolvesOnBothPlatformsButIsNotOfferedForSynchronization() throws {
        let provider = try XCTUnwrap(CloudProviderRegistry.provider(for: "googledrive") as? GoogleDriveCloudProvider)
        XCTAssertEqual(CloudProviderKind(rawValue: provider.id), .googleDrive)
        XCTAssertEqual(provider.writeGuarantee(expectedRev: "observed-version", byteCount: 1024), .disabled)
        XCTAssertFalse(provider.isAvailableForSynchronization)
        XCTAssertFalse(CloudProviderKind.googleDrive.isAvailableOnCurrentPlatform)
        XCTAssertFalse(CloudProviderRegistry.availableProviders.contains(.googleDrive))
        XCTAssertFalse(DatabaseCreationDestinationChoice.availableChoices.contains { $0.cloudProviderKind == .googleDrive })
    }

    func testDefaultBuildDoesNotConfigureGoogleDriveOAuth() {
        XCTAssertNil(GoogleDriveConfiguration.load())
    }
}
