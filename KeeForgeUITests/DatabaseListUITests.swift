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
}
