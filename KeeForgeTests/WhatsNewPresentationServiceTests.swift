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

    func testVersion118LeadsWithRecoveryGuidanceAndFiltersPlatformFeatures() throws {
        for platform in [WhatsNewPlatform.iOS, .macOS] {
            let release = try XCTUnwrap(WhatsNewCatalog.release(version: "1.18.0", platform: platform))
            let first = try XCTUnwrap(release.features.first)
            XCTAssertEqual(first.id, "prevent-database-corruption")
            let detail = String(localized: first.detail)
            XCTAssertTrue(detail.contains("does not repair already damaged files"))
            XCTAssertTrue(detail.contains("saving entry notes"))
            XCTAssertTrue(detail.contains("readable backup"))
            XCTAssertEqual(first.link?.url.absoluteString, "https://github.com/KeeForge/kdbx-recovery")

            let ids = release.features.map(\.id)
            XCTAssertEqual(ids.count, platform == .iOS ? 6 : 7)
            XCTAssertEqual(ids.contains("database-view-menu"), platform == .iOS)
            XCTAssertEqual(ids.contains("mac-menu-bar-search"), platform == .macOS)
            XCTAssertEqual(ids.contains("mac-apple-watch-unlock"), platform == .macOS)
        }
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

    func testVersion116CatalogShowsEachPlatformItsOwnWordingInApprovedOrder() throws {
        let iOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.16.0", platform: .iOS)
        )
        let macOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.16.0", platform: .macOS)
        )

        XCTAssertEqual(
            iOSRelease.features.map(\.id),
            ["native-mac-app", "duplicate-entry", "copy-from-list"]
        )
        XCTAssertEqual(
            macOSRelease.features.map(\.id),
            ["native-mac-app-mac", "duplicate-entry-mac", "copy-from-list-mac"]
        )

        let iOSDetails = iOSRelease.features.map { String(localized: $0.detail) }
        let macDetails = macOSRelease.features.map { String(localized: $0.detail) }
        XCTAssertTrue(iOSDetails[0].contains("Mac App Store"))
        XCTAssertFalse(macDetails.contains { $0.contains("Mac App Store") })
        XCTAssertFalse(macDetails.contains { $0.contains("Touch and hold") })
        XCTAssertFalse(iOSDetails.contains { $0.contains("Right-click") })
    }

    func testVersion116IsPresentedForTheShippedMarketingVersion() {
        let release = WhatsNewPresentationService.releaseToPresent(
            currentVersion: "1.16.0",
            platform: .macOS,
            defaults: defaults,
            uiTestingPresentationOverride: nil
        )

        XCTAssertEqual(release?.version, "1.16.0")
    }

    func testVersion117CatalogKeepsExperimentalYubiKeyUnlockIOSOnly() throws {
        let iOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.17.0", platform: .iOS)
        )
        let macOSRelease = try XCTUnwrap(
            WhatsNewCatalog.release(version: "1.17.0", platform: .macOS)
        )

        XCTAssertEqual(
            iOSRelease.features.map(\.id),
            [
                "ftp-databases",
                "yubikey-unlock",
                "edit-custom-fields",
                "autofill-save-group",
                "japanese-localization",
            ]
        )
        XCTAssertEqual(
            macOSRelease.features.map(\.id),
            [
                "ftp-databases",
                "edit-custom-fields",
                "autofill-save-group",
                "japanese-localization",
            ]
        )

        let yubiKeyFeature = try XCTUnwrap(
            iOSRelease.features.first { $0.id == "yubikey-unlock" }
        )
        XCTAssertTrue(String(localized: yubiKeyFeature.title).contains("experimental"))
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
