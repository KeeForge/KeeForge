#if os(macOS)
import XCTest
@testable import KeeForge

/// The notice is the whole of the iPad-on-Mac transition, so the only things
/// worth pinning are that it appears for an upgrading install, never for a
/// fresh one, and never twice.
@MainActor
final class MacTransitionNoticeServiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MacTransitionNoticeServiceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testPresentsOnceWhenLegacyDatabaseListExists() {
        XCTAssertTrue(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                hasLegacyDatabaseList: true
            )
        )
    }

    func testDoesNotPresentAgainOnALaterLaunch() {
        _ = MacTransitionNoticeService.claimPresentation(
            defaults: defaults,
            hasLegacyDatabaseList: true
        )

        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                hasLegacyDatabaseList: true
            )
        )
    }

    func testDoesNotPresentOnAFreshInstall() {
        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                hasLegacyDatabaseList: false
            )
        )
    }

    /// A fresh install spends the claim on its first launch, so a
    /// `database-list.json` this app writes later can never trigger the notice.
    func testFreshInstallConsumesTheClaim() {
        _ = MacTransitionNoticeService.claimPresentation(
            defaults: defaults,
            hasLegacyDatabaseList: false
        )

        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                hasLegacyDatabaseList: true
            )
        )
    }
}
#endif
