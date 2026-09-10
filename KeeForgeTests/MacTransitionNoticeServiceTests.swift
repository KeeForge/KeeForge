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
                legacyState: .listPresent
            )
        )
    }

    func testDoesNotPresentAgainOnALaterLaunch() {
        _ = MacTransitionNoticeService.claimPresentation(
            defaults: defaults,
            legacyState: .listPresent
        )

        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                legacyState: .listPresent
            )
        )
    }

    func testDoesNotPresentOnAFreshInstall() {
        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                legacyState: .freshInstall
            )
        )
    }

    /// A fresh install spends the claim on its first launch, so a
    /// `database-list.json` this app writes later can never trigger the notice.
    func testFreshInstallConsumesTheClaim() {
        _ = MacTransitionNoticeService.claimPresentation(
            defaults: defaults,
            legacyState: .freshInstall
        )

        XCTAssertFalse(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                legacyState: .listPresent
            )
        )
    }

    /// The case the whole trigger exists for: two builds sharing a bundle
    /// identifier can leave the App Group denied, and `containerURL` then
    /// returns nil. A fresh install always gets its group, so an unavailable
    /// container can only mean the user is looking at an empty list they
    /// should not be — exactly when the instructions matter.
    func testPresentsWhenTheAppGroupIsUnavailable() {
        XCTAssertTrue(
            MacTransitionNoticeService.claimPresentation(
                defaults: defaults,
                legacyState: .containerUnavailable
            )
        )
    }
}
#endif
