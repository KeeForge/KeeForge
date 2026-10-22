import XCTest

/// Covers the Duplicate action a long press adds to every entry row (#104): it
/// opens a New Entry form already filled in from the entry it was raised on,
/// with a destination group the user can change before saving.
@MainActor
final class EntryDuplicateUITests: EntryEditUITestCase {
    private let duplicatedEntryTitle = "AAC UI Duplicated Entry"

    func testDuplicateOpensAPrefilledNewEntryFormAndSavesACopy() {
        unlockSuccessfully()

        openGroup(named: socialGroupName)
        revealContextMenuButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.duplicate-context",
            preferredIdentifier: "entry.navlink"
        ).tap()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Duplicate did not open the entry form")
        XCTAssertTrue(
            (titleField.value as? String ?? "").hasPrefix(discordEntryTitle),
            "The copy's title should start from the entry it was duplicated from"
        )
        XCTAssertTrue(
            app.buttons["entry-edit.group"].exists,
            "A New Entry form should offer the group it will be saved into"
        )

        replaceText(in: titleField, with: duplicatedEntryTitle)
        app.buttons["entry-edit.save"].tap()

        let title = app.staticTexts["entry-detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, duplicatedEntryTitle)
        if app.windows.firstMatch.frame.width < 700 {
            tapBackButton()
        } else {
            revealSidebarIfNeeded()
        }

        XCTAssertTrue(
            entry(named: duplicatedEntryTitle).waitForExistence(timeout: 10),
            "The duplicated entry should appear in the group it was created in"
        )
        XCTAssertTrue(
            entry(named: discordEntryTitle).exists,
            "Duplicating must leave the original entry in place"
        )
    }

    func testDuplicateFromSearchResultsOpensTheSavedCopy() {
        unlockSuccessfully()

        searchForEntries(matching: discordEntryTitle)
        revealContextMenuButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.duplicate-context",
            preferredIdentifier: "search.entry.navlink"
        ).tap()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Duplicate did not open the entry form")
        replaceText(in: titleField, with: duplicatedEntryTitle)
        app.buttons["entry-edit.save"].tap()

        let title = app.staticTexts["entry-detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Saving the duplicate did not open its detail")
        XCTAssertEqual(title.label, duplicatedEntryTitle)
    }
}
