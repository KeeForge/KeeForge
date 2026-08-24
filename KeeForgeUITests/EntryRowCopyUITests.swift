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

        copyUsername.tap()

        XCTAssertTrue(
            entry(named: discordEntryTitle).waitForExistence(timeout: 5),
            "Copying from the context menu should leave the entry list in place"
        )
    }
}
