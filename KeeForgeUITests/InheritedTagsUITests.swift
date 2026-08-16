import XCTest

// Coverage for the inherited group tags the entry detail screen draws next to
// an entry's own — the chips that explain why the tag browser listed an entry
// that stores no such tag itself.
//
// Uses `kitchen-sink.kdbx` (password `testpassword123`), the only bundled
// database with group `<Tags>`: `Projects` carries `team;shared`, its
// `Client Work` subgroup adds `billable`, and `Client Work/Beta Login` stores
// `own-tag` of its own. The `Tagged` group the rest of the tag coverage uses is
// deliberately untagged, so entries there draw no inherited chips at all.
// See `TestFixtures/README.md`.
@MainActor
final class InheritedTagsUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    /// An entry with no tags of its own still explains its tag-browser hits.
    func testEntryWithNoOwnTagsShowsItsGroupsTagsAsInheritedChips() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Projects", entryName: "Alpha Login")

        for tag in ["team", "shared"] {
            let chip = inheritedTagChip(tag)
            XCTAssertTrue(
                chip.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
                "Entry detail did not show '\(tag)' as a tag inherited from the Projects group"
            )
            XCTAssertTrue(revealElement(chip, in: scrollableContainer()), "Inherited tag chip was not reachable")
            XCTAssertFalse(
                ownTagChip(tag).exists,
                "'\(tag)' comes from the group, so it must not draw an own-tag chip the Edit button implies is editable"
            )
        }
    }

    /// An inherited chip is the same shortcut its own-tag siblings are.
    func testTappingAnInheritedTagChipOpensThatTagsEntries() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Projects", entryName: "Alpha Login")

        let chip = inheritedTagChip("team")
        XCTAssertTrue(
            chip.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Entry detail did not show the inherited 'team' chip"
        )
        XCTAssertTrue(revealElement(chip, in: scrollableContainer()), "Inherited tag chip was not reachable")
        tapElement(chip)

        // `Beta Login` sits one group deeper and inherits `team` too, so
        // reaching it proves the tag's own list opened rather than the screen
        // standing still on `Alpha Login`.
        let otherCarrier = searchResult(named: "Beta Login")
        XCTAssertTrue(
            revealElement(otherCarrier, in: scrollableContainer()),
            "Tapping the inherited 'team' chip did not open that tag's entries"
        )
    }

    /// The two strips stay apart on an entry that has both.
    func testEntryWithItsOwnTagsKeepsThemApartFromTheInheritedOnes() {
        unlockSuccessfully()
        openGroup(named: "Projects")
        openGroup(named: "Client Work")
        openEntry(named: "Beta Login")

        let ownChip = ownTagChip("own-tag")
        XCTAssertTrue(
            ownChip.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "Entry detail did not show the entry's own 'own-tag' chip"
        )
        XCTAssertTrue(revealElement(ownChip, in: scrollableContainer()), "Own tag chip was not reachable")
        XCTAssertFalse(
            inheritedTagChip("own-tag").exists,
            "A tag the entry stores itself must never be drawn as inherited"
        )

        let inheritedStrip = app.descendants(matching: .any)
            .matching(identifier: "entry-detail.inherited-tags")
            .firstMatch
        XCTAssertTrue(
            revealElement(inheritedStrip, in: scrollableContainer()),
            "Entry detail did not show the inherited-tags strip"
        )

        // Root-most first: `Projects` grants `team` and `shared`, `Client Work`
        // adds `billable`.
        for tag in ["team", "shared", "billable"] {
            let chip = inheritedTagChip(tag)
            XCTAssertTrue(
                revealElement(chip, in: scrollableContainer()),
                "Entry detail did not show '\(tag)' as inherited from an ancestor group"
            )
        }
    }

    private func ownTagChip(_ tag: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "entry-detail.tag.\(tag)").firstMatch
    }

    private func inheritedTagChip(_ tag: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "entry-detail.inherited-tag.\(tag)").firstMatch
    }
}
