import XCTest

/// Arrow keys in search results. Every entry list (group, Library, tag,
/// search) is the one `MacEntryListViewController` table, so this case and
/// `MacSmokeUITests.testDownArrowMovesTheEntrySelection` stand for all of them;
/// which rows each mode shows is unit-tested in `MacEntryListModelTests`. It
/// asserts only that a keystroke moves the selection, never where it lands, so
/// it does not re-encode the fixture's sort order.
///
/// `kitchen-sink.kdbx`: it has several entries matching "Login".
@MainActor
final class MacListKeyboardNavigationUITests: MacUITestCase {
    override var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    func testDownArrowMovesTheSearchResultSelection() {
        unlockSuccessfully()

        typeCommandShortcut("f")
        app.typeText("Login")

        let count = searchResultCount()
        XCTAssertGreaterThanOrEqual(
            count,
            2,
            "The search needs at least two results for an arrow key to have somewhere to go"
        )

        // The row's identifier is on its title field, so the clicked text is the entry's title.
        let clicked = clickFirstRow(identifier: "search.entry.navlink")
        XCTAssertFalse(clicked.isEmpty, "Could not read the title of the clicked result")
        XCTAssertTrue(waitForDisplayText(clicked, identifier: "entry-detail.title"),
                      "Clicking a search result did not open it in the detail column")

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])

        XCTAssertNotNil(
            waitForDetailTitleToChange(from: clicked),
            "Arrow-key navigation did not move the selection within the search results"
        )
    }
}

/// A search result's Delete item raises the workspace host's confirmation,
/// and confirming it recycles the entry. The menu and its gates are unit-tested
/// (`MacEntryListViewControllerTests`); only the running app shows the table's
/// menu reaching the SwiftUI host's dialog and the result list updating.
@MainActor
final class MacSearchResultsDeleteUITests: MacUITestCase {
    /// `kitchen-sink.kdbx`: several entries match "Login", and it has a Recycle Bin.
    override var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    func testDeletingASearchResultConfirmsAndRecyclesTheEntry() {
        unlockSuccessfully()

        typeCommandShortcut("f")
        app.typeText("Login")
        XCTAssertGreaterThanOrEqual(searchResultCount(), 2, "Expected several matches for 'Login'")

        let row = firstHittableRow(identifier: "search.entry.navlink")
        let title = displayText(of: row)
        XCTAssertFalse(title.isEmpty, "Could not read the title of the row under test")
        row.rightClick()

        clickContextMenuItem(titled: "Delete")

        let confirmDelete = databaseWindow.buttons["Delete"].firstMatch
        XCTAssertTrue(
            confirmDelete.waitForExistence(timeout: 10),
            "Delete confirmation did not present from the search results"
        )
        confirmDelete.click()

        XCTAssertTrue(
            waitForRowToDisappear(title: title, identifier: "search.entry.navlink"),
            "Confirmed delete left '\(title)' in the search results"
        )

        // Clear the search, which wins over the sidebar, once the save that disables it ends.
        let searchField = databaseWindow.searchFields.firstMatch
        waitUntilEnabled(searchField, timeout: 30)
        searchField.click()
        typeCommandShortcut("a")
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["search.results.count"].waitForNonExistence(timeout: 10), "The search did not clear")
        // The bin is the sidebar's last row, below the fold of this tall sidebar.
        databaseWindow.outlines[Self.sidebarOutlineIdentifier].scroll(byDeltaX: 0, deltaY: -2000)
        openGroup(named: "Recycle Bin")
        XCTAssertTrue(waitForDisplayText(title, identifier: "entry.navlink"), "'\(title)' did not reach the Recycle Bin")
    }

    /// Clicks a row context-menu item by title.
    ///
    /// Matching on title alone is not enough: the menu bar carries its own
    /// items with the same titles (Edit ▸ Delete, and the app's ⌘⌫ Delete),
    /// which are present but disabled, and `firstMatch` picks one of those and
    /// clicks nothing — leaving the context menu open and the window modal.
    /// Only an enabled, hittable item can be the open menu's.
    private func clickContextMenuItem(
        titled title: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = app.menuItems
                .matching(NSPredicate(format: "title == %@", title))
                .allElementsBoundByIndex
            if let item = candidates.first(where: { $0.exists && $0.isEnabled && $0.isHittable }) {
                item.click()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("No enabled '\(title)' context-menu item within \(Int(timeout)) seconds", file: file, line: line)
    }

    private func firstHittableRow(
        identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = rowQuery(identifier: identifier).allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.height > 1
            }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("No hittable '\(identifier)' row within \(Int(timeout)) seconds", file: file, line: line)
        return rowQuery(identifier: identifier).firstMatch
    }

    private func waitForRowToDisappear(
        title: String,
        identifier: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = rowQuery(identifier: identifier).allElementsBoundByIndex
            if matches.contains(where: { displayText(of: $0) == title }) == false {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }
}
