import XCTest
@testable import KeeForge

@MainActor
final class WhatsNewPresentationServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WhatsNewPresentationServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testReleaseIsPresentedOnlyOnceForTheSameVersion() {
        let firstPresentation = WhatsNewPresentationService.releaseToPresent(
            currentVersion: "1.10.1",
            platform: .iOS,
            defaults: defaults,
            uiTestingPresentationOverride: nil
        )
        let secondPresentation = WhatsNewPresentationService.releaseToPresent(
            currentVersion: "1.10.1",
            platform: .iOS,
            defaults: defaults,
            uiTestingPresentationOverride: nil
        )

        XCTAssertEqual(firstPresentation?.version, "1.10.1")
        XCTAssertNil(secondPresentation)
    }

    func testPreviouslyPresentedVersionStaysClaimedAfterAnotherVersion() {
        let history = WhatsNewPresentationHistory(defaults: defaults)

        XCTAssertTrue(history.claimPresentation(for: "1.10.1"))
        XCTAssertTrue(history.claimPresentation(for: "1.11.0"))
        XCTAssertFalse(history.claimPresentation(for: "1.10.1"))
    }

    func testVersionWithoutFeatureContentDoesNotPresent() {
        XCTAssertNil(
            WhatsNewPresentationService.releaseToPresent(
                currentVersion: "9.9.9",
                platform: .iOS,
                defaults: defaults,
                uiTestingPresentationOverride: nil
            )
        )
    }

    func testCatalogFiltersPlatformSpecificFeatures() throws {
        let iOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.10.1", platform: .iOS)
        )
        let macOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.10.1", platform: .macOS)
        )

        XCTAssertEqual(iOSRelease.features.count, 3)
        XCTAssertEqual(macOSRelease.features.count, 2)
        XCTAssertFalse(macOSRelease.features.contains { $0.id == "autofill-setup" })
    }

    func testVersion112CatalogHasFourHighlightsAndKeepsPasskeyRegistrationIOSOnly() throws {
        let iOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.12.0", platform: .iOS)
        )
        let macOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.12.0", platform: .macOS)
        )

        XCTAssertEqual(
            iOSRelease.features.map(\.id),
            [
                "group-editor",
                "passkey-registration",
                "entry-folder-context",
                "french-spanish-localization",
            ]
        )
        XCTAssertEqual(
            macOSRelease.features.map(\.id),
            [
                "group-editor",
                "entry-folder-context",
                "french-spanish-localization",
            ]
        )
    }

    func testVersion111CatalogDoesNotClaimLaterLocalizations() throws {
        let release = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.11.0", platform: .iOS)
        )

        XCTAssertFalse(release.features.contains { $0.id == "french-localization" })
        XCTAssertFalse(release.features.contains { $0.id == "spanish-localization" })
    }

    func testUITestingCanSuppressOrForcePresentation() {
        XCTAssertNil(
            WhatsNewPresentationService.releaseToPresent(
                currentVersion: "1.10.1",
                platform: .macOS,
                defaults: defaults,
                uiTestingPresentationOverride: false
            )
        )

        XCTAssertNotNil(
            WhatsNewPresentationService.releaseToPresent(
                currentVersion: "1.10.1",
                platform: .macOS,
                defaults: defaults,
                uiTestingPresentationOverride: true
            )
        )
    }
}
