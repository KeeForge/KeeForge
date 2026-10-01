import XCTest

// Coverage for the view menu in the database root's title: Groups, All
// Entries, Verification Codes, and the Recycle Bin. The Tags view is driven by
// `TagBrowserUITests`.
//
// Uses `kitchen-sink.kdbx` because it ships a nested group, an entry with a
// verification code, and a real recycle bin holding `Trashed Login`.
// See `TestFixtures/README.md`.
@MainActor
final class ViewMenuUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    private let nestedEntryName = "Beta Login"
    private let codeEntryName = "TOTP Login"
    private let recycledEntryName = "Trashed Login"

    func testAllEntriesListsEntriesFromEveryGroupWithTheirFolder() {
        unlockSuccessfully()

        selectDatabaseView(.allEntries)

        // The flat list has no group rows, and every entry says where it lives.
        XCTAssertTrue(
            entryRow(named: "Alpha Login").waitForExistence(timeout: Self.ciElementTimeout),
            "All Entries did not list any entry"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "group.navlink").count,
            0,
            "All Entries still listed group rows"
        )
        // Scrolled through the list itself: in the regular-width workspace it
        // is the sidebar, and a swipe on the window would land on the detail.
        let list = app.collectionViews.firstMatch
        let nestedEntry = entryRow(named: nestedEntryName)
        XCTAssertTrue(
            revealElement(nestedEntry, in: list),
            "All Entries did not list an entry from a nested group"
        )
        XCTAssertTrue(
            nestedEntry.label.contains("Projects / Client Work"),
            "Expected the row to name the entry's folder, got: \(nestedEntry.label)"
        )

        // Seventeen live entries over the nine root groups plus `Client Work`;
        // `Trashed Login` and the recycle bin count towards neither.
        let summary = app.staticTexts["group-list.summary"]
        XCTAssertTrue(revealElement(summary, in: list), "All Entries did not show its summary")
        XCTAssertEqual(summary.label, "17 entries in 10 groups")
        XCTAssertFalse(entryRow(named: recycledEntryName).exists, "All Entries listed a recycled entry")

        XCTAssertTrue(revealElement(nestedEntry, in: list, direction: .down), "Nested entry was not reachable")
        tapElement(nestedEntry)
        XCTAssertTrue(
            app.navigationBars[nestedEntryName].waitForExistence(timeout: Self.ciElementTimeout)
                || app.staticTexts["entry-detail.title"].waitForExistence(timeout: Self.ciElementTimeout),
            "Tapping an All Entries row did not open the entry"
        )
    }

    func testVerificationCodesListsOnlyEntriesWithACode() {
        unlockSuccessfully()

        selectDatabaseView(.verificationCodes)

        let codeEntry = entryRow(named: codeEntryName)
        XCTAssertTrue(revealElement(codeEntry), "Verification Codes did not list the entry with a code")
        XCTAssertTrue(
            codeEntry.label.contains("Secrets"),
            "Expected the row to name the entry's folder, got: \(codeEntry.label)"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "entry.navlink").count,
            1,
            "Verification Codes listed entries without a code"
        )
        XCTAssertEqual(app.staticTexts["group-list.summary"].label, "1 entry")
    }

    func testRecycleBinOpensFromTheViewMenuAndNotFromTheGroupList() {
        unlockSuccessfully()

        // `Tagged` sorts last, where the bin used to be pinned below it.
        XCTAssertTrue(revealElement(groupRow(named: "Tagged")), "Root group list was not visible")
        XCTAssertFalse(groupRow(named: "Recycle Bin").exists, "The recycle bin was still listed as a group")

        selectDatabaseView(.recycleBin)

        XCTAssertTrue(revealElement(entryRow(named: recycledEntryName)), "Recycle Bin did not list its entry")
        XCTAssertFalse(
            app.buttons["entry-list.add-entry"].exists,
            "The recycle bin offered to create entries and groups in it"
        )

        selectDatabaseView(.groups)

        XCTAssertTrue(revealElement(groupRow(named: "Archive")), "Groups view did not return")
        XCTAssertTrue(app.buttons["entry-list.add-entry"].exists, "Add menu did not return with the Groups view")
    }
}
