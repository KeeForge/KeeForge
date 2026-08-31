import XCTest
@testable import KeeForge

@MainActor
final class AutoFillStatusServiceTests: XCTestCase {
    private let suiteName = "AutoFillStatusServiceTests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        AutoFillStatusService.defaults = testDefaults
        AutoFillStatusService.resetForTesting()
    }

    override func tearDown() {
        AutoFillStatusService.resetForTesting()
        AutoFillStatusService.defaults = .standard
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - tipDismissed

    func testTipDismissedStartsFalse() {
        XCTAssertFalse(AutoFillStatusService.tipDismissed)
    }

    func testTipDismissedPersists() {
        AutoFillStatusService.tipDismissed = true
        XCTAssertTrue(AutoFillStatusService.tipDismissed)
        XCTAssertTrue(testDefaults.bool(forKey: "KeeForge.autoFillTip.dismissed"))
    }

    func testResetClearsDismissedFlag() {
        AutoFillStatusService.tipDismissed = true

        AutoFillStatusService.resetForTesting()

        XCTAssertFalse(AutoFillStatusService.tipDismissed)
    }

    // MARK: - isAutoFillEnabled

    func testIsAutoFillEnabledReturnsProviderValue() async {
        AutoFillStatusService.enabledProvider = { true }
        let enabled = await AutoFillStatusService.isAutoFillEnabled()
        XCTAssertTrue(enabled)

        AutoFillStatusService.enabledProvider = { false }
        let disabled = await AutoFillStatusService.isAutoFillEnabled()
        XCTAssertFalse(disabled)
    }

    // MARK: - requestEnableAutoFill

    func testRequestEnableAutoFillReturnsRequesterResult() async {
        AutoFillStatusService.enableRequester = { true }
        let enabled = await AutoFillStatusService.requestEnableAutoFill()
        XCTAssertEqual(enabled, true)

        AutoFillStatusService.enableRequester = { false }
        let declined = await AutoFillStatusService.requestEnableAutoFill()
        XCTAssertFalse(declined)
    }

    // MARK: - UI-test suppression

    func testTipIsNotSuppressedOutsideUITesting() {
        // Unit tests run without the -ui-testing launch argument.
        XCTAssertFalse(AutoFillStatusService.isTipSuppressedForUITesting)
    }
}
