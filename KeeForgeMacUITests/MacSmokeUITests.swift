import AppKit
import XCTest

/// macOS smoke suite covering the slice-02 core Mac UX: unlock, browse,
/// search, entry detail, reveal/copy auth boundaries, edit + save, menu-bar
/// commands (⌘L, ⌘N, ⌘F, ⌘,), and unlock-screen keyboard handling.
///
/// Reveal/copy-password authentication cannot be completed from XCUITest (the
/// device-owner prompt is a system dialog outside the app process), so those
/// tests assert up to the prompt boundary: the app must NOT reveal or copy
/// without authentication completing.
@MainActor
final class MacSmokeUITests: MacUITestCase {
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // MARK: - Unlock

    func testUnlockSucceedsWithCorrectPassword() {
        unlockSuccessfully()
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        XCTAssertTrue(groupLink.exists, "Unlocked vault did not show the root group list")
    }

    func testUnlockFailsWithWrongPassword() {
        unlock(password: "definitely-wrong-password")

        let errorLabel = app.staticTexts["unlock.error.label"]
        XCTAssertTrue(errorLabel.waitForExistence(timeout: 30), "Unlock error was not surfaced")
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        XCTAssertFalse(groupLink.exists, "Vault must not unlock with a wrong password")
    }

    // MARK: - Browse

    func testBrowseGroupsShowsFixtureGroups() {
        unlockSuccessfully()

        for groupName in ["Social", "Work", "Empty"] {
            let group = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == 'group.navlink' AND (label CONTAINS[c] %@ OR value CONTAINS[c] %@)",
                    groupName, groupName
                )
            ).firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 15), "Group '\(groupName)' missing from root group list")
        }
    }

    func testEntryDetailShowsFieldsAndCopyUsernamePutsValueOnPasteboard() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")

        let copyUsername = app.buttons["entry.copy.username"].firstMatch
        XCTAssertTrue(copyUsername.waitForExistence(timeout: 15), "Entry detail did not show the username row")

        let changeCountBefore = NSPasteboard.general.changeCount
        copyUsername.click()

        let deadline = Date().addingTimeInterval(10)
        while NSPasteboard.general.changeCount == changeCountBefore, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertGreaterThan(NSPasteboard.general.changeCount, changeCountBefore, "Copy Username did not write to the pasteboard")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.isEmpty, false, "Copied username was empty")
        XCTAssertNotNil(
            NSPasteboard.general.string(forType: concealedType),
            "Copies must carry org.nspasteboard.ConcealedType so clipboard managers skip them"
        )
    }

    // MARK: - Keyboard navigation

    /// The vault columns are native `List(selection:)`, so the arrow keys are
    /// AppKit's, not something the app implements. These two tests are what
    /// catch a regression back to hand-rolled button rows, where nothing moved.
    func testDownArrowMovesTheEntrySelection() {
        unlockSuccessfully()
        openGroup(named: "Work")
        // Title-ascending is the default sort, so Email precedes GitHub.
        openEntry(named: "Email")

        XCTAssertTrue(
            waitForDisplayText("Email", identifier: "entry-detail.title"),
            "Entry detail did not open on 'Email'"
        )

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])

        XCTAssertTrue(
            waitForDisplayText("GitHub", identifier: "entry-detail.title"),
            "Arrow-key navigation did not move the entry selection"
        )
    }

    func testDownArrowMovesTheSidebarGroupSelection() {
        unlockSuccessfully()
        // 'Empty' has no entries and sorts before 'Social' and 'Work', so any
        // downward move lands on a group that does have some.
        openGroup(named: "Empty")

        let entryRow = rowQuery(identifier: "entry.navlink").firstMatch
        XCTAssertFalse(entryRow.exists, "The 'Empty' group should show no entry rows")

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])

        XCTAssertTrue(
            entryRow.waitForExistence(timeout: 10),
            "Arrow-key navigation did not move the sidebar selection to the next group"
        )
    }

    // MARK: - Reveal / copy password auth boundary

    func testRevealPasswordRequiresAuthentication() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")

        let reveal = app.buttons["entry.password.reveal"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 15), "Password reveal button missing")
        reveal.click()

        // Boundary assertion: the reveal button disables while the
        // device-owner authentication prompt is up; the password must not
        // reveal without it. (The prompt itself is a system dialog that
        // XCUITest cannot automate; the app terminates in teardown, which
        // dismisses it.)
        let deadline = Date().addingTimeInterval(8)
        var sawAuthInFlight = false
        while Date() < deadline {
            if reveal.exists, reveal.isEnabled == false {
                sawAuthInFlight = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(
            sawAuthInFlight,
            "Reveal did not enter the authenticating state — password may have been revealed without device-owner authentication"
        )
    }

    func testCopyPasswordDoesNotCopyWithoutAuthentication() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")

        let copyPassword = app.buttons["entry.copy.password"].firstMatch
        XCTAssertTrue(copyPassword.waitForExistence(timeout: 15), "Copy password button missing")

        let changeCountBefore = NSPasteboard.general.changeCount
        copyPassword.click()

        // Boundary assertion: nothing may land on the pasteboard while the
        // authentication prompt is pending.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertEqual(
                NSPasteboard.general.changeCount,
                changeCountBefore,
                "Password was copied without device-owner authentication"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    // MARK: - Search (⌘F)

    func testSearchViaCommandFShowsResultCount() {
        unlockSuccessfully()

        typeCommandShortcut("f")
        app.typeText("GitHub")

        let resultsCount = app.staticTexts["search.results.count"]
        XCTAssertTrue(resultsCount.waitForExistence(timeout: 15), "Search results count overlay missing")

        // macOS StaticText exposes the text as `value` (label is empty).
        func countText() -> String {
            (resultsCount.value as? String) ?? resultsCount.label
        }

        let deadline = Date().addingTimeInterval(10)
        while countText() != "results:1", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(countText(), "results:1", "Expected exactly one result for 'GitHub'")
    }

    // MARK: - Edit + save

    func testEditEntryTitleAndSavePersists() {
        unlockSuccessfully()
        openGroup(named: "Social")
        openEntry(named: "Discord")

        // The Edit toolbar button may collapse into the macOS toolbar overflow.
        clickToolbarButton(identifier: "entry-detail.edit", overflowLabel: "Edit")

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 15), "Entry edit form did not appear")
        titleField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Discord Renamed")

        let saveButton = app.buttons["entry-edit.save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button missing")
        saveButton.click()

        // The renamed entry surfaces as a content-column row. Matching is done
        // in Swift over the identifier query rather than with a CONTAINS
        // predicate: a broad `descendants(.any)` + CONTAINS scan over the
        // three-column hierarchy times out the accessibility query on macOS.
        XCTAssertTrue(
            waitForDisplayText("Discord Renamed", identifier: "entry.navlink", timeout: 30),
            "Renamed entry did not appear after save"
        )
    }

    // MARK: - Menu-bar commands

    func testLockViaCommandLReturnsToUnlockScreen() {
        unlockSuccessfully()

        typeCommandShortcut("l")

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "⌘L did not lock the database")
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        XCTAssertFalse(groupLink.exists, "Vault content should be gone after ⌘L")
    }

    func testNewEntryCommandOpensEditor() {
        unlockSuccessfully()

        typeCommandShortcut("n")

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 15), "⌘N did not open the entry editor")

        let cancelButton = app.buttons["entry-edit.cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Entry editor cancel button missing")
        cancelButton.click()

        let deadline = Date().addingTimeInterval(10)
        while titleField.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(titleField.exists, "Entry editor did not dismiss after Cancel")
    }

    func testSettingsWindowOpensViaCommandComma() {
        openFirstDatabaseFromListIfNeeded()

        typeCommandShortcut(",")

        let lockPolicyPicker = app.descendants(matching: .any)
            .matching(identifier: "settings.lock-policy.picker")
            .firstMatch
        XCTAssertTrue(lockPolicyPicker.waitForExistence(timeout: 15), "Settings window did not show the lock-policy picker")
    }

    // MARK: - Unlock keyboard handling

    func testEscapeInUnlockReturnsToDatabaseList() {
        openFirstDatabaseFromListIfNeeded()

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))

        app.typeKey(.escape, modifierFlags: [])

        let placeholder = app.staticTexts["Select a Database"]
        let deadline = Date().addingTimeInterval(10)
        while passwordField.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(passwordField.exists, "Escape did not leave the unlock screen")
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), "Database-list placeholder did not appear after Escape")
    }
}

/// Database-list management smoke coverage (two seeded databases).
@MainActor
final class MacDatabaseListUITests: MacUITestCase {
    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "test", injectedFilename: "test.kdbx"),
            DatabaseFixture(resourceName: "demo", injectedFilename: "demo.kdbx"),
        ]
    }

    func testDatabaseListShowsSeededDatabasesAndRemovesOne() {
        let testRow = databaseRow(containing: "test")
        let demoRow = databaseRow(containing: "demo")
        XCTAssertTrue(testRow.waitForExistence(timeout: 15), "Seeded test.kdbx row missing")
        XCTAssertTrue(demoRow.waitForExistence(timeout: 15), "Seeded demo.kdbx row missing")

        demoRow.rightClick()

        let removeMenuItem = app.menuItems["Remove"].firstMatch
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 10), "Remove context-menu item missing")
        removeMenuItem.click()

        // Confirmation dialog. Scope to the window so the query cannot match
        // Touch Bar elements (which XCUITest refuses to click).
        let confirmRemove = app.windows.buttons["Remove"].firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 10), "Remove confirmation did not appear")
        confirmRemove.click()

        let deadline = Date().addingTimeInterval(15)
        while demoRow.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(demoRow.exists, "demo.kdbx row was not removed")
        XCTAssertTrue(testRow.exists, "test.kdbx row must survive the removal")
    }
}
