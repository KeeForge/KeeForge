import XCTest

// Coverage for the vault root's tiles and the screens they open: All Entries,
// Verification Codes, and the Recycle Bin. The Tags screen is driven by
// `TagBrowserUITests`.
//
// Uses `kitchen-sink.kdbx` because it ships a nested group, an entry with a
// verification code, and a real recycle bin holding `Trashed Login`.
// See `TestFixtures/README.md`.
@MainActor
final class VaultHomeUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    private let nestedEntryName = "Beta Login"
    private let codeEntryName = "TOTP Login"
    private let recycledEntryName = "Trashed Login"

    func testTilesCountWhatTheirScreensList() {
        unlockSuccessfully()

        let expectedCounts: [(DatabaseView, String)] = [
            (.allEntries, "17"),
            (.verificationCodes, "1"),
            (.recycleBin, "1"),
        ]
        for (view, count) in expectedCounts {
            let tile = app.buttons["home-tile.\(view.rawValue)"]
            XCTAssertTrue(tile.waitForExistence(timeout: Self.ciElementTimeout), "The root did not show the '\(view.label)' tile")
            XCTAssertEqual(tile.label, view.label)
            XCTAssertEqual(tile.value as? String, count, "'\(view.label)' counted the wrong number of items")
        }
        XCTAssertTrue(app.buttons["home-tile.tags"].exists, "The root did not show the Tags tile")
    }

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
        // The title's subtitle from iOS 26, the list's footer before.
        let summaryText = "17 entries in 10 groups"
        if #available(iOS 26.0, *) {
            XCTAssertTrue(
                app.staticTexts[summaryText].waitForExistence(timeout: Self.ciElementTimeout),
                "All Entries did not show its summary under the title"
            )
        } else {
            let summary = app.staticTexts["group-list.summary"]
            XCTAssertTrue(revealElement(summary, in: list), "All Entries did not show its summary")
            XCTAssertEqual(summary.label, summaryText)
        }
        XCTAssertFalse(entryRow(named: recycledEntryName).exists, "All Entries listed a recycled entry")

        XCTAssertTrue(revealElement(nestedEntry, in: list, direction: .down), "Nested entry was not reachable")
        tapElement(nestedEntry)
        XCTAssertTrue(
            app.navigationBars[nestedEntryName].waitForExistence(timeout: Self.ciElementTimeout)
                || app.staticTexts["entry-detail.title"].waitForExistence(timeout: Self.ciElementTimeout),
            "Tapping an All Entries row did not open the entry"
        )
    }

    /// The code itself is time-dependent, so this proves the wiring only: the
    /// row shows six digits, offers to copy them, and opens its entry.
    func testVerificationCodesShowsTheCodeOfEachEntryThatHasOne() {
        unlockSuccessfully()

        selectDatabaseView(.verificationCodes)

        let codeEntry = entryRow(named: codeEntryName)
        XCTAssertTrue(revealElement(codeEntry), "Verification Codes did not list the entry with a code")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "entry.navlink").count,
            1,
            "Verification Codes listed entries without a code"
        )
        // The row reads its code digit by digit, as its value.
        let code = codeEntry.value as? String ?? ""
        XCTAssertNotNil(
            code.range(of: #"\d \d \d \d \d \d"#, options: .regularExpression),
            "Expected a six-digit code as the row's value, got: \(code)"
        )
        XCTAssertTrue(
            codeEntry.label.contains("totp-user · Secrets"),
            "Expected the row to name the entry's username and group, got: \(codeEntry.label)"
        )
        XCTAssertTrue(
            app.buttons["verification-code-row.copy"].isHittable,
            "The row did not offer to copy its code"
        )

        tapElement(codeEntry)
        XCTAssertTrue(
            app.staticTexts["entry.totp.code"].waitForExistence(timeout: Self.ciElementTimeout),
            "Tapping a code row did not open its entry"
        )
    }

    func testRecycleBinOpensFromItsTileAndNotFromTheGroupList() {
        unlockSuccessfully()

        // `Tagged` sorts last, where the bin used to be pinned below it.
        XCTAssertTrue(revealElement(groupRow(named: "Tagged")), "Root group list was not visible")
        // By identifier: `groupRow(named:)` would also match the bin's own tile.
        let recycleBinGroupRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'group.navlink' AND label CONTAINS %@", "Recycle Bin")
        ).firstMatch
        XCTAssertFalse(recycleBinGroupRow.exists, "The recycle bin was still listed as a group")

        selectDatabaseView(.recycleBin)

        XCTAssertTrue(revealElement(entryRow(named: recycledEntryName)), "Recycle Bin did not list its entry")
        XCTAssertFalse(
            app.buttons["entry-list.add-entry"].exists,
            "The recycle bin offered to create entries and groups in it"
        )

        selectDatabaseView(.groups)

        XCTAssertTrue(revealElement(groupRow(named: "Archive")), "The root's groups did not return")
        XCTAssertTrue(app.buttons["entry-list.add-entry"].exists, "Add menu did not return with the root")
    }
}

/// Larger text widens the bar's actions. iOS 27 folds items that no longer fit
/// beside the title into a "…" overflow button; Lock has to stay in the bar on
/// every screen the tiles open.
@MainActor
final class VaultLargeTextUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    /// UIKit's own identifier for the overflow button it adds to a crowded bar.
    private var overflowButton: XCUIElement {
        app.navigationBars.buttons["OverflowBarButtonItem"]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
    }

    func testEveryScreenKeepsItsBarActionsOutOfAnOverflowMenu() {
        unlockSuccessfully()

        let views: [DatabaseView] = [.groups, .allEntries, .verificationCodes, .tags, .recycleBin]
        for view in views {
            selectDatabaseView(view)
            XCTAssertFalse(overflowButton.exists, "'\(view.label)' folded bar items into an overflow menu")
            XCTAssertTrue(currentLockButton().isHittable, "'\(view.label)' did not keep Lock in the bar")
        }
    }
}
