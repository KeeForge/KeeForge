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

        XCTAssertTrue(waitForDocumentPicker(), "Document picker did not appear after tapping Add Database")
    }

    func testSwipeToDeleteShowsRemoveAction() {
        let alphaRow = databaseRow(containing: "alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 10), "Alpha row not found")

        alphaRow.swipeLeft()

        let removeButton = app.buttons["Remove"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "Remove action did not appear")
    }

    func testEditModeShowsReorderHandles() {
        let editButton = app.buttons["database.edit.button"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "Edit button not found")
        editButton.tap()

        let firstHandle = reorderHandle(containing: "alpha")
        let secondHandle = reorderHandle(containing: "bravo")
        XCTAssertTrue(firstHandle.waitForExistence(timeout: 5), "Alpha reorder handle not found")
        XCTAssertTrue(secondHandle.waitForExistence(timeout: 5), "Bravo reorder handle not found")
    }

    private func databaseRow(containing text: String) -> XCUIElement {
        let cell = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        if cell.exists {
            return cell
        }

        return app.buttons.matching(
            NSPredicate(format: "identifier == 'database.row' AND label CONTAINS[c] %@", text)
        ).firstMatch
    }

    private func reorderHandle(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ AND label BEGINSWITH[c] 'Reorder'", text)

        let buttons = app.buttons.matching(predicate).firstMatch
        if buttons.exists {
            return buttons
        }

        let anyElements = app.descendants(matching: .any).matching(predicate).firstMatch
        return anyElements
    }
}
