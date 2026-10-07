import XCTest

/// Default-suite smoke coverage for the DEBUG-only AutoFill store inspector
/// Safe on unprovisioned simulators: provider readiness is independent of
/// identity enumeration, which may remain pending on the system store.
/// It does not extend `KeeForgeUITestCase` because the inspector replaces the
/// normal database-list root, so no fixture injection or unlock flow applies.
@MainActor
final class AutoFillStoreInspectorSmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    func testInspectorPresentsAndReadsProviderState() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-autofill-store-inspector"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        let enabledState = app.staticTexts["autofill-inspector.enabled-state"]
        XCTAssertTrue(
            enabledState.waitForExistence(timeout: 30),
            "Inspector enabled-state did not appear; read status: \(app.staticTexts["autofill-inspector.read-status"].value ?? "<missing>")"
        )
        XCTAssertTrue(
            ["enabled", "disabled"].contains(enabledState.value as? String ?? ""),
            "Inspector must report the real system provider state on this destination"
        )

        let incrementalState = app.staticTexts["autofill-inspector.incremental-updates"]
        XCTAssertTrue(incrementalState.exists)
        XCTAssertTrue(["supported", "unsupported"].contains(incrementalState.value as? String ?? ""))
        let status = app.staticTexts["autofill-inspector.read-status"]
        XCTAssertTrue(status.exists)
        let evidence = XCTAttachment(string: app.debugDescription)
        evidence.name = "Inspector readiness and read phase"
        evidence.lifetime = .keepAlways
        add(evidence)

        XCTAssertTrue(
            app.buttons["autofill-inspector.refresh"].exists,
            "Refresh control missing from the inspector"
        )
    }
}
