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
