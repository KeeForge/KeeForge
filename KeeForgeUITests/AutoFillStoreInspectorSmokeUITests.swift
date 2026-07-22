import XCTest

/// Default-suite smoke coverage for the DEBUG-only AutoFill store inspector
/// (epic: 2026-07-20-autofill-store-validation-harness, slice 01). Safe on
/// unprovisioned simulators: it only pins that the `-autofill-store-inspector`
/// launch argument presents the inspector at the app root and that the store
/// reads "disabled" when KeeForge is not the enabled system AutoFill provider.
/// It does not extend `KeeForgeUITestCase` because the inspector replaces the
/// normal database-list root, so no fixture injection or unlock flow applies.
@MainActor
final class AutoFillStoreInspectorSmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testInspectorPresentsAndReadsDisabledOnUnprovisionedSimulator() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-autofill-store-inspector"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)

        let enabledState = app.staticTexts["autofill-inspector.enabled-state"]
        XCTAssertTrue(
            enabledState.waitForExistence(timeout: 30),
            "Inspector enabled-state element did not appear at the app root"
        )
        XCTAssertEqual(
            enabledState.value as? String,
            "disabled",
            "On an unprovisioned simulator the system store must read disabled"
        )

        // Enumeration is available on the iOS 17.4+ harness runtime even while
        // the provider is disabled; the refresh control is always present.
        XCTAssertTrue(
            app.buttons["autofill-inspector.refresh"].exists,
            "Refresh control missing from the inspector"
        )
    }
}
