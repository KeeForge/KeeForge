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

        let filesButton = app.buttons["database.add.files"].firstMatch
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

    private func openDatabaseDetails(
        rowContaining name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detailsAction = app.buttons["database-row.details"]
        for _ in 0..<4 where detailsAction.exists == false {
            let row = databaseRow(containing: name)
            if row.waitForExistence(timeout: 5) {
                row.press(forDuration: 1.2)
                if detailsAction.waitForExistence(timeout: 2) {
                    break
                }
            }
        }
        XCTAssertTrue(
            detailsAction.waitForExistence(timeout: 2),
            "Database Details context action was not visible for '\(name)'",
            file: file,
            line: line
        )
        tapElement(detailsAction)

        XCTAssertTrue(
            app.buttons["database-details.close"].waitForExistence(timeout: Self.ciElementTimeout),
            "Database details sheet did not appear",
            file: file,
            line: line
        )
    }

    private func closeDatabaseDetails(file: StaticString = #filePath, line: UInt = #line) {
        let closeButton = app.buttons["database-details.close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button was not visible", file: file, line: line)
        tapElement(closeButton)

        let deadline = Date().addingTimeInterval(10)
        while closeButton.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(closeButton.exists, "Database details sheet did not dismiss", file: file, line: line)
    }

    private func setSwitch(
        _ toggle: XCUIElement,
        isOn desiredValue: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let desiredRawValue = desiredValue ? "1" : "0"
        let deadline = Date().addingTimeInterval(5)

        while (toggle.value as? String) != desiredRawValue, Date() < deadline {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertEqual(
            toggle.value as? String,
            desiredRawValue,
            "Expected AutoFill toggle to be \(desiredValue ? "on" : "off")",
            file: file,
            line: line
        )
    }
}
