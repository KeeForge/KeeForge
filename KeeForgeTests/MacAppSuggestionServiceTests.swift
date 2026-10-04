import XCTest
@testable import KeeForge

@MainActor
final class MacAppSuggestionServiceTests: XCTestCase {
    private let suiteName = "MacAppSuggestionServiceTests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        MacAppSuggestionService.defaults = testDefaults
        MacAppSuggestionService.resetForTesting()
    }

    override func tearDown() {
        MacAppSuggestionService.resetForTesting()
        MacAppSuggestionService.defaults = .standard
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Platform

    /// The unit suites run on an iOS simulator and in the native Mac app,
    /// neither of which is the iOS app on a Mac.
    func testSuggestionIsUnavailableOnTheHostPlatform() {
        XCTAssertFalse(MacAppSuggestionService.isSuggestionAvailable)
    }

    func testSuggestionIsAvailableForTheiOSAppOnMac() {
        MacAppSuggestionService.isiOSAppOnMac = { true }

        XCTAssertTrue(MacAppSuggestionService.isSuggestionAvailable)
    }

    func testResetRestoresPlatformDetection() {
        MacAppSuggestionService.isiOSAppOnMac = { true }

        MacAppSuggestionService.resetForTesting()

        XCTAssertFalse(MacAppSuggestionService.isSuggestionAvailable)
    }

    // MARK: - isDismissed

    func testDismissalStartsFalse() {
        XCTAssertFalse(MacAppSuggestionService.isDismissed)
    }

    func testDismissalPersists() {
        MacAppSuggestionService.isDismissed = true

        XCTAssertTrue(MacAppSuggestionService.isDismissed)
        XCTAssertTrue(testDefaults.bool(forKey: "KeeForge.macAppSuggestion.dismissed"))
    }

    func testResetClearsDismissal() {
        MacAppSuggestionService.isDismissed = true

        MacAppSuggestionService.resetForTesting()

        XCTAssertFalse(MacAppSuggestionService.isDismissed)
    }

    // MARK: - Destination

    func testDestinationIsTheAppStoreListing() {
        XCTAssertEqual(
            MacAppSuggestionService.appStoreURL?.absoluteString,
            "https://apps.apple.com/app/id6759309295"
        )
    }
}
