import XCTest

// Happy-path smoke coverage for the tag browser: root Tags row → tag list →
// that tag's entries → entry detail → the tag chip that got you there.
//
// Uses `tag-browser.kdbx` (password `testpassword123`, the default
// `unlockSuccessfully()` uses) because neither `test.kdbx` nor `demo.kdbx`
// carries a single tag. Its `shared` tag is on two entries in two different
// groups, so the count on the row is real data rather than a trivial "1".
// See `TestFixtures/README.md`.
@MainActor
final class TagBrowserUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "tag-browser" }

    private let sharedTag = "shared"
    private let taggedEntryName = "Router Admin"

    func testBrowsingFromTheRootTagsRowReachesATaggedEntry() {
        unlockSuccessfully()

        // 1. The root list offers the tag browser, with the fixture's five
        //    distinct tags counted on the row.
        let tagsRow = app.descendants(matching: .any).matching(identifier: "group-list.tags-row").firstMatch
        XCTAssertTrue(
            tagsRow.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Root group list did not show the Tags row"
        )
        XCTAssertTrue(revealElement(tagsRow, in: scrollableContainer()), "Tags row was not reachable")
        // SwiftUI folds a row's title and caption into one accessibility label,
        // the same way the group rows expose their "N entries" caption.
        XCTAssertTrue(
            tagsRow.label.contains("5 tags"),
            "Expected the Tags row to count the fixture's five distinct tags, got: \(tagsRow.label)"
        )
        tapElement(tagsRow)

        // 2. The tag list shows the known tag with its entry count.
        let sharedRow = app.descendants(matching: .any)
            .matching(identifier: "tag-list.row.\(sharedTag)")
            .firstMatch
        XCTAssertTrue(
            sharedRow.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Tag list did not show a row for the '\(sharedTag)' tag"
        )
        XCTAssertTrue(revealElement(sharedRow, in: scrollableContainer()), "Tag row was not reachable")
        // SwiftUI folds the row's name and count captions into one label.
        XCTAssertTrue(
            sharedRow.label.contains("2 entries"),
            "Expected the '\(sharedTag)' row to count its two carriers, got: \(sharedRow.label)"
        )
        tapElement(sharedRow)

        // 3. The tag's entries list carries the fixture entry. `TagEntriesView`
        //    reuses `EntryListView`, so its rows keep that view's existing
        //    `search.entry.navlink` identifier — which is what `searchResult`
        //    already matches.
        let taggedEntry = searchResult(named: taggedEntryName)
        XCTAssertTrue(
            revealElement(taggedEntry, in: scrollableContainer()),
            "Tag-filtered list did not show '\(taggedEntryName)'"
        )
        tapElement(taggedEntry)

        // 4. Entry detail shows the chip that leads back into the same tag.
        let chip = app.descendants(matching: .any)
            .matching(identifier: "entry-detail.tag.\(sharedTag)")
            .firstMatch
        XCTAssertTrue(
            chip.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Entry detail did not show the '\(sharedTag)' tag chip"
        )
        XCTAssertTrue(revealElement(chip, in: scrollableContainer()), "Tag chip was not reachable")
    }
}
