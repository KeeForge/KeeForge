import XCTest

// Happy-path smoke coverage for the tag browser: view menu → Tags → that
// tag's entries → entry detail → the tag chip that got you there.
//
// Uses `kitchen-sink.kdbx` (password `testpassword123`, the default
// `unlockSuccessfully()` uses) because neither `test.kdbx` nor `demo.kdbx`
// carries a single tag. Its `shared` tag reaches four entries across three
// groups — two carry it themselves, two inherit it from `Projects` — so the
// count on the row is real data rather than a trivial "1".
// See `TestFixtures/README.md`.
@MainActor
final class TagBrowserUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    private let sharedTag = "shared"
    private let taggedEntryName = "Router Admin"
    /// `shared`'s second carrier, in a different group. Reaching it proves
    /// which tag a screen is showing: `Router Admin`'s other two tags each
    /// carry only `Router Admin` itself.
    private let otherSharedCarrierName = "Mail Account"

    func testBrowsingFromTheTagsViewReachesATaggedEntry() {
        unlockSuccessfully()

        // 1. The view menu offers the tag browser, which lists the fixture's
        //    eight distinct tags.
        selectDatabaseView(.tags)
        let tagRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'tag-list.row.'")
        )
        XCTAssertTrue(
            tagRows.firstMatch.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Tags view did not list any tag"
        )
        XCTAssertEqual(tagRows.count, 8, "Expected a row for each of the fixture's eight distinct tags")

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
            sharedRow.label.contains("4 entries"),
            "Expected the '\(sharedTag)' row to count its four carriers, got: \(sharedRow.label)"
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

        // Two own carriers in `Tagged`, plus the two that inherit `shared` from
        // `Projects`; the nested one shows its full path below the root.
        let folderCaptions = app.staticTexts.matching(identifier: "entry-row.folder").allElementsBoundByIndex
        XCTAssertEqual(
            folderCaptions.map(\.label).sorted(),
            ["Projects", "Projects / Client Work", "Tagged", "Tagged"],
            "Every shared-tag result should identify its containing folder"
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

    /// Tapping a chip must open *that* chip's tag.
    ///
    /// The chips share one list row, so when they were `NavigationLink`s the
    /// row owned the link rather than the chip: a tap opened the row's last
    /// destination (here `Personal Notes`) or pushed several screens at once.
    /// `shared` is deliberately the entry's *first* chip and the only one with
    /// a second carrier, so landing on the wrong tag cannot show
    /// `otherSharedCarrierName`.
    func testTappingATagChipOpensThatChipsTagAndNotAnother() {
        unlockSuccessfully()
        openTaggedEntryFromTheTagBrowser()

        let chip = app.descendants(matching: .any)
            .matching(identifier: "entry-detail.tag.\(sharedTag)")
            .firstMatch
        XCTAssertTrue(
            chip.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Entry detail did not show the '\(sharedTag)' tag chip"
        )
        XCTAssertTrue(revealElement(chip, in: scrollableContainer()), "Tag chip was not reachable")
        tapElement(chip)

        let otherCarrier = searchResult(named: otherSharedCarrierName)
        XCTAssertTrue(
            revealElement(otherCarrier, in: scrollableContainer()),
            "Tapping the '\(sharedTag)' chip did not open that tag: '\(otherSharedCarrierName)' carries "
                + "'\(sharedTag)' and nothing else on '\(taggedEntryName)', so a different tag opened"
        )

        // One push, not several: a single back lands on the entry, not on
        // another tag screen stacked in between.
        guard let backButton = app.navigationBars.buttons.allElementsBoundByIndex.first(where: {
            $0.exists && $0.isHittable && $0.identifier != "lock.button"
        }) else {
            return XCTFail("Tag entries screen had no back button")
        }
        backButton.tap()

        let chipAfterBack = app.descendants(matching: .any)
            .matching(identifier: "entry-detail.tag.\(sharedTag)")
            .firstMatch
        XCTAssertTrue(
            chipAfterBack.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Going back from the tag did not land on '\(taggedEntryName)', so the chip pushed more than one screen"
        )
    }

    func testHiddenGroupEntriesLeaveSearchButRemainInTheTagBrowser() {
        unlockSuccessfully()

        let taggedGroup = groupRow(named: "Tagged")
        XCTAssertTrue(revealElement(taggedGroup), "Tagged group was not visible")
        // A partly hittable last row can still have its center under the bottom search bar.
        scrollableContainer()?.swipeUp()
        XCTAssertTrue(revealElement(taggedGroup), "Tagged group was not visible after scrolling")
        taggedGroup.press(forDuration: 1.2)

        let hideAction = app.buttons["group-row.autofill-exclusion-context"]
        XCTAssertTrue(hideAction.waitForExistence(timeout: 5), "Hide from Search & AutoFill action was not visible")
        tapElement(hideAction)
        // `Tagged` sorts last in this fixture, and the list returns to the top
        // once the toggle saves, so the lazily-rendered row has to be brought
        // back on screen before its badge exists to assert on.
        XCTAssertTrue(revealElement(taggedGroup), "Tagged group was not visible after hiding")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "group-row.autofill-excluded").firstMatch
                .waitForExistence(timeout: Self.ciElementTimeout),
            "Hidden-group badge did not appear"
        )

        let searchField = activateSearchField()
        clearSearchField(searchField)
        searchField.typeText(taggedEntryName)
        XCTAssertTrue(app.staticTexts["search.no-results"].waitForExistence(timeout: 5))
        XCTAssertFalse(searchResult(named: taggedEntryName).exists, "Hidden group entry remained in search")

        dismissSearch()
        // Clearing the query leaves search focused; iOS 27 labels its dismiss control "close".
        let endSearch = app.buttons.matching(
            NSPredicate(format: "label ==[c] 'Close' OR label ==[c] 'Cancel'")
        ).firstMatch
        XCTAssertTrue(endSearch.waitForExistence(timeout: Self.ciElementTimeout), "Search dismiss control was not visible")
        XCTAssertTrue(endSearch.isHittable, "Search dismiss control was not tappable")
        endSearch.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: Self.ciElementTimeout),
            "Search keyboard did not dismiss before switching to Tags"
        )
        selectDatabaseView(.tags)

        let sharedRow = app.descendants(matching: .any).matching(identifier: "tag-list.row.\(sharedTag)").firstMatch
        XCTAssertTrue(sharedRow.waitForExistence(timeout: 5), "Shared tag disappeared with the hidden group")
        XCTAssertTrue(revealElement(sharedRow, in: scrollableContainer()), "Shared tag row was not reachable")
        if searchField.exists, sharedRow.frame.intersects(searchField.frame) {
            scrollableContainer()?.swipeUp()
        }
        let rowIsExposed = NSPredicate { [self] _, _ in
            guard sharedRow.exists, hasOnScreenFrame(sharedRow), sharedRow.isHittable else { return false }
            let frame = sharedRow.frame
            return app.windows.firstMatch.frame.contains(frame)
                && (!searchField.exists || !frame.intersects(searchField.frame))
                && !frame.intersects(app.navigationBars.firstMatch.frame)
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: rowIsExposed, object: nil)],
                timeout: Self.ciElementTimeout
            ),
            .completed,
            "Shared tag row did not settle clear of the search field and navigation bar"
        )
        sharedRow.tap()
        XCTAssertTrue(
            app.navigationBars[sharedTag].waitForExistence(timeout: Self.ciElementTimeout),
            "Shared tag row did not open its entries"
        )
        XCTAssertTrue(
            searchResult(named: taggedEntryName).waitForExistence(timeout: Self.ciElementTimeout),
            "Hidden group entry should remain available through the tag browser"
        )
    }

    /// Tags view → `shared` → `Router Admin`, the shared prefix of the
    /// browsing tests.
    private func openTaggedEntryFromTheTagBrowser() {
        selectDatabaseView(.tags)

        let sharedRow = app.descendants(matching: .any)
            .matching(identifier: "tag-list.row.\(sharedTag)")
            .firstMatch
        XCTAssertTrue(
            sharedRow.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Tag list did not show a row for the '\(sharedTag)' tag"
        )
        XCTAssertTrue(revealElement(sharedRow, in: scrollableContainer()), "Tag row was not reachable")
        tapElement(sharedRow)

        let taggedEntry = searchResult(named: taggedEntryName)
        XCTAssertTrue(
            revealElement(taggedEntry, in: scrollableContainer()),
            "Tag-filtered list did not show '\(taggedEntryName)'"
        )
        tapElement(taggedEntry)
    }
}
