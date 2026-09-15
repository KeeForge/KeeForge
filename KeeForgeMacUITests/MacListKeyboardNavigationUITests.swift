import XCTest

/// Keyboard navigation in the two macOS content-column lists that are not a
/// group's entries: search results and the tag browser.
///
/// Both used to render the shared iOS `EntryListView`, whose rows are `Button`s
/// — and a button consumes the click a native `List(selection:)` needs to move
/// its selection, so the list never became first responder and the arrow keys
/// went nowhere. They now render `MacEntriesList`. These tests are what catch a
/// regression back to the button rows: they assert only that a keystroke moves
/// the selection, never which entry it lands on, so they do not re-encode the
/// fixture's sort order.
///
/// `kitchen-sink.kdbx` rather than the default `test.kdbx`: it is the only
/// bundled database with entry tags, so it is the only one whose sidebar has a
/// Tags section to browse (`TestFixtures/README.md`).
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

        clickFirstRow(identifier: "search.entry.navlink")

        let firstTitle = waitForAnyDetailTitle()
        XCTAssertFalse(firstTitle.isEmpty, "Clicking a search result did not open it in the detail column")

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])

        XCTAssertNotNil(
            waitForDetailTitleToChange(from: firstTitle),
            "Arrow-key navigation did not move the selection within the search results"
        )
    }

    func testDownArrowMovesTheTagResultSelection() {
        unlockSuccessfully()

        // `shared` is carried by two entries in the fixture, which is the
        // minimum for a downward move to land anywhere.
        let tagRow = app.descendants(matching: .any)
            .matching(identifier: "tag-list.row.shared")
            .firstMatch
        XCTAssertTrue(
            tagRow.waitForExistence(timeout: 15),
            "The macOS sidebar did not show the 'shared' tag row"
        )
        tagRow.click()

        clickFirstRow(identifier: "search.entry.navlink")

        let firstTitle = waitForAnyDetailTitle()
        XCTAssertFalse(firstTitle.isEmpty, "Clicking a tag result did not open it in the detail column")

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])

        XCTAssertNotNil(
            waitForDetailTitleToChange(from: firstTitle),
            "Arrow-key navigation did not move the selection within the tag results"
        )
    }
}

/// Deleting from the two content-column lists that render `MacEntriesList`.
///
/// Both render inline in the workspace's content column, which already hosts a
/// `PendingDeletion`, so the list must raise its confirmation there instead of
/// adding a second `.alert(item:)` — two siblings on one presentation context
/// collide and SwiftUI silently drops one. That is what broke the same flow on
/// iOS (#118); on macOS it would have shipped the row's Delete doing nothing.
/// Each case asserts the confirmation actually appears, because the failure is
/// silent rather than an error.
@MainActor
final class MacSearchResultsDeleteUITests: MacUITestCase {
    /// `kitchen-sink.kdbx` for the same reason the class above uses it: it is
    /// the only bundled database with entry tags, so the only one whose sidebar
    /// has a Tags section to delete from.
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

        let confirmDelete = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(
            confirmDelete.waitForExistence(timeout: 10),
            "Delete confirmation did not present from the search results"
        )
        confirmDelete.click()

        XCTAssertTrue(
            waitForRowToDisappear(title: title, identifier: "search.entry.navlink"),
            "Confirmed delete left '\(title)' in the search results"
        )
    }

    func testDeletingATagResultConfirmsAndRecyclesTheEntry() {
        unlockSuccessfully()

        let tagRow = app.descendants(matching: .any)
            .matching(identifier: "tag-list.row.own-tag")
            .firstMatch
        XCTAssertTrue(tagRow.waitForExistence(timeout: 15), "The macOS sidebar did not show the 'own-tag' row")
        tagRow.click()

        let row = firstHittableRow(identifier: "search.entry.navlink")
        row.rightClick()

        clickContextMenuItem(titled: "Delete")

        let confirmDelete = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(
            confirmDelete.waitForExistence(timeout: 10),
            "Delete confirmation did not present from the tag browser"
        )
        confirmDelete.click()

        // The tag's only carrier is gone, so the browser falls to its empty state.
        XCTAssertTrue(
            waitForNoRow(identifier: "search.entry.navlink"),
            "Confirmed delete left the entry in the tag results"
        )
    }

    func testCancellingADeleteFromSearchResultsKeepsTheEntry() {
        unlockSuccessfully()

        typeCommandShortcut("f")
        app.typeText("Login")
        XCTAssertGreaterThanOrEqual(searchResultCount(), 2, "Expected several matches for 'Login'")

        let row = firstHittableRow(identifier: "search.entry.navlink")
        let title = displayText(of: row)
        XCTAssertFalse(title.isEmpty, "Could not read the title of the row under test")
        row.rightClick()

        clickContextMenuItem(titled: "Delete")

        let cancelButton = app.windows.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10), "Delete confirmation did not present")
        cancelButton.click()

        XCTAssertTrue(
            waitForDisplayText(title, identifier: "search.entry.navlink"),
            "Cancelling the confirmation removed '\(title)' anyway"
        )
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

    private func waitForNoRow(identifier: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let remaining = rowQuery(identifier: identifier).allElementsBoundByIndex
                .filter { $0.exists && $0.frame.height > 1 }
            if remaining.isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
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
