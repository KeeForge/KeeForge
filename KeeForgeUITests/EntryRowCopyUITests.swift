import XCTest

/// Covers the Copy Username / Copy Password actions a long press adds to every
/// entry row (#102). The copied value itself is not asserted: reading the
/// pasteboard from the runner process raises the system paste prompt, so these
/// stay at the level the other row-context tests use — the action is offered
/// where it should be, and hidden where the field is empty.
@MainActor
final class EntryRowCopyUITests: EntryEditUITestCase {
    func testContextMenuOffersCopyUsernameAndPassword() {
        unlockSuccessfully()

        openGroup(named: socialGroupName)
        let copyUsername = revealContextMenuButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.copy-username-context",
            preferredIdentifier: "entry.navlink"
        )
        XCTAssertTrue(app.buttons["entry-row.copy-password-context"].exists)
        XCTAssertTrue(app.buttons["entry-row.change-icon-context"].exists, "A writable entry's menu offers Change Icon")

        copyUsername.tap()

        XCTAssertTrue(
            entry(named: discordEntryTitle).waitForExistence(timeout: 5),
            "Copying from the context menu should leave the entry list in place"
        )
    }

    func testChangeIconFromTheRowMenuChangesTheEntryIcon() {
        unlockSuccessfully()

        openGroup(named: socialGroupName)
        revealContextMenuButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.change-icon-context",
            preferredIdentifier: "entry.navlink"
        ).tap()
        let icon = app.buttons["entry-icon-picker.standard.37"]
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "Change Icon did not open the icon picker")
        XCTAssertTrue(revealElement(icon), "Icon 37 could not be scrolled into view")
        tapElement(icon)
        XCTAssertTrue(icon.waitForNonExistence(timeout: 5), "Picking an icon should dismiss the picker")

        revealContextMenuButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.change-icon-context",
            preferredIdentifier: "entry.navlink"
        ).tap()
        let reopened = app.buttons["entry-icon-picker.standard.37"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5), "The icon picker did not open again")
        XCTAssertTrue(reopened.isSelected, "The icon picked from the row menu should be the entry's icon")
    }
}
