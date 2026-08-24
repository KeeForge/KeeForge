import XCTest

@MainActor
final class DatabaseListUITests: KeeForgeUITestCase {
    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        [
            .init(resourceName: "test", injectedFilename: "alpha.kdbx"),
            .init(resourceName: "test", injectedFilename: "bravo.kdbx"),
        ]
    }

    func testLaunchShowsDatabaseListForMultipleDatabases() {
        XCTAssertTrue(waitForDatabaseList(), "Database list did not appear")
        XCTAssertTrue(databaseRow(containing: "alpha").exists, "Alpha row missing")
        XCTAssertTrue(databaseRow(containing: "bravo").exists, "Bravo row missing")
    }

    func testAddDatabaseButtonPresentsDocumentPicker() {
        let addButton = app.buttons["database.add.button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "Add Database button not found")
        addButton.tap()

        let filesButton = menuButton(identifier: "database.add.files", label: "Files")
        XCTAssertTrue(filesButton.waitForExistence(timeout: 10), "Local Device option did not appear")
        filesButton.tap()

        XCTAssertTrue(waitForDocumentPicker(), "Document picker did not appear after tapping Add Database")
    }

    func testSwipeToDeleteShowsRemoveAction() {
        let alphaRow = databaseRow(containing: "alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 10), "Alpha row not found")

        alphaRow.swipeLeft()

        let removeButton = app.buttons["Remove"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "Remove action did not appear")
    }

    func testDatabaseDetailsAutoFillTogglePersistsAcrossReopen() {
        XCTAssertTrue(waitForDatabaseList(), "Database list did not appear")

        openDatabaseDetails(rowContaining: "alpha")

        let toggle = app.switches["database-details.autofill-toggle"]
        XCTAssertTrue(
            revealElement(toggle, in: scrollableContainer()),
            "AutoFill toggle was not visible in the database details sheet"
        )
        XCTAssertEqual(toggle.value as? String, "1", "AutoFill should default to enabled")

        setSwitch(toggle, isOn: false)

        closeDatabaseDetails()

        // Reopen the same row's details: the flag round-trips through
        // database-list.json, so the toggle must come back disabled.
        openDatabaseDetails(rowContaining: "alpha")
        XCTAssertTrue(
            revealElement(toggle, in: scrollableContainer()),
            "AutoFill toggle was not visible after reopening the details sheet"
        )
        XCTAssertEqual(
            toggle.value as? String,
            "0",
            "AutoFill toggle should stay off after closing and reopening the details sheet"
        )

        // Restore the seeded default. (The -ui-testing bootstrap reseeds
        // database-list.json on every launch, so later tests are safe either
        // way, but leave clean on-disk state rather than depending on it.)
        setSwitch(toggle, isOn: true)
        closeDatabaseDetails()
    }

    func testEditModeShowsReorderHandles() {
        let editButton = app.buttons["database.edit.button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Edit button not found")
        editButton.tap()

        // The system reorder control's accessibility label varies by iOS
        // version: "Reorder <row>" on iOS 26, but just "Reorder" on iOS 17.5.
        // Match on the "Reorder" prefix (not the row name) and assert one handle
        // appears per database row, which holds across both.
        let reorderHandles = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")
        )
        XCTAssertTrue(
            reorderHandles.firstMatch.waitForExistence(timeout: 5),
            "Reorder handles did not appear in edit mode"
        )
        XCTAssertGreaterThanOrEqual(
            reorderHandles.count,
            2,
            "Expected a reorder handle for each database row"
        )
    }

    func testReorderUpdatesTheListWithoutLeavingTheApp() {
        XCTAssertTrue(waitForDatabaseList(), "Database list did not appear")

        XCTAssertTrue(
            databaseRow(containing: "alpha").waitForExistence(timeout: 10),
            "Alpha row not found"
        )
        XCTAssertTrue(
            databaseRow(containing: "bravo").waitForExistence(timeout: 10),
            "Bravo row not found"
        )
        XCTAssertTrue(alphaIsAboveBravo(), "Alpha should start above bravo")

        let editButton = app.buttons["database.edit.button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Edit button not found")
        editButton.tap()

        let reorderHandles = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")
        )
        XCTAssertTrue(
            reorderHandles.firstMatch.waitForExistence(timeout: 5),
            "Reorder handles did not appear in edit mode"
        )

        let alphaHandle = reorderHandles.element(boundBy: 0)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dropTarget = databaseRow(containing: "bravo")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9))
        alphaHandle.press(
            forDuration: 1.0,
            thenDragTo: dropTarget,
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )

        let repaintedImmediately = waitFor(timeout: 5) { !self.alphaIsAboveBravo() }

        // Backgrounding and returning re-reads the stored order, which
        // separates "the drag never registered" from "the drag registered but
        // the list kept painting the old order" — the reported symptom.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 10)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        let persisted = waitFor(timeout: 10) { !self.alphaIsAboveBravo() }

        XCTAssertTrue(persisted, "The drag did not reorder the stored database list")
        XCTAssertTrue(
            repaintedImmediately,
            "The list kept the old order until the app was backgrounded and reopened"
        )
    }

    private func alphaIsAboveBravo() -> Bool {
        databaseRow(containing: "alpha").frame.minY < databaseRow(containing: "bravo").frame.minY
    }

    private func waitFor(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 0.3)
        } while Date() < deadline
        return condition()
    }
}
