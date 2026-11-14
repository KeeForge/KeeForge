import AppKit
import XCTest

/// macOS smoke suite covering the slice-02 core Mac UX: unlock, browse,
/// search, entry detail, keyboard navigation, edit + save, menu-bar commands
/// (⌘L, ⌘N, ⌘F, ⌘,), and unlock-screen keyboard handling.
///
/// The reveal/copy-password authentication boundary lives in its own class
/// below, which launches the app with the pending-authentication stub.
@MainActor
final class MacSmokeUITests: MacUITestCase {
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Only `kitchen-sink.kdbx` has tags, a Recycle Bin and attachments, which the sidebar and
    /// entry detail cases need.
    override var databaseFixtures: [DatabaseFixture] {
        guard name.contains("testSidebarShowsItsSections") || name.contains("testEntryDetailShowsFields") else {
            return super.databaseFixtures
        }
        return [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    /// The popover and the panel are separate windows over the editor: only the running app shows
    /// Escape closing the popover alone, Use filling the editor's field, Escape then cancelling the
    /// editor and releasing the lists, and the menu opening the panel whose Copy goes through
    /// `ClipboardService`. Generation and saved options are `PasswordGeneratorModelTests`.
    func testPassphraseGeneratorFillsTheEditorAndThePanelCopies() throws {
        unlockSuccessfully()
        let window = databaseWindow
        openGroup(named: "Work")
        openEntry(named: "Email")
        typeCommandShortcut("n")
        let titleField = window.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "⌘N did not open the editor")
        let generator = window.buttons["entry-edit.password-generator-button"].firstMatch
        XCTAssertTrue(generator.waitForExistence(timeout: 10))
        generator.click()
        let use = app.buttons["password-generator.use"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 5), "Generate did not open the popover")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(use.waitForNonExistence(timeout: 5), "Escape did not close the generator popover")
        XCTAssertTrue(titleField.exists, "Escape in the popover also closed the editor")

        generator.click()
        XCTAssertTrue(use.waitForExistence(timeout: 5))
        let mode = app.radioButtons["Passphrase"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.click()
        let separator = app.textFields["password-generator.separator"].firstMatch
        XCTAssertTrue(separator.waitForExistence(timeout: 5))
        separator.click()
        typeCommandShortcut("a")
        app.typeText("::")
        app.buttons["password-generator.regenerate"].firstMatch.click()
        let phrase = suggestion()
        XCTAssertTrue((4...12).contains(phrase.components(separatedBy: "::").count), "Unexpected passphrase '\(phrase)'")
        use.click()
        XCTAssertTrue(use.waitForNonExistence(timeout: 5), "Use Password did not close the popover")
        // A new entry's password starts visible, so the field is plain text.
        let field = window.textFields["entry-edit.password-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, phrase)

        app.typeKey(.escape, modifierFlags: [])
        let discard = window.sheets.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Escape did not ask before discarding the edited entry")
        discard.click()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 10), "Discard Changes left the editor open")
        let search = window.searchFields.firstMatch
        waitUntilEnabled(search, timeout: 10)
        XCTAssertTrue(search.isEnabled, "The lists stayed frozen after the editor was cancelled")

        chooseMenuItem("Password Generator", inMenu: "Database")
        let panel = app.descendants(matching: .any).matching(identifier: "password-generator.panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Database > Password Generator did not open the panel")
        let copy = panel.buttons["password-generator.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let suggested = suggestion(in: panel)
        XCTAssertFalse(suggested.isEmpty, "The panel shows no suggestion")
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), suggested)
        XCTAssertNotNil(NSPasteboard.general.data(forType: concealedType))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Escape did not close the Password Generator panel")
    }

    /// The generator's suggestion: its label names it, its value is the text.
    private func suggestion(in container: XCUIElement? = nil) -> String {
        let root: XCUIElement = container ?? app
        let element = root.descendants(matching: .any).matching(identifier: "password-generator.password").firstMatch
        guard element.waitForExistence(timeout: 5) else { return "" }
        return element.value as? String ?? ""
    }

    func testRestoreEntryFromRecycleBinContextMenu() {
        unlockSuccessfully()
        openGroup(named: "Social")
        titledRow(identifier: "entry.navlink", named: "Discord").rightClick()
        clickRestoreTestMenu("entry-row.delete-context")
        let delete = databaseWindow.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        openGroup(named: "Deleted Entries")
        titledRow(identifier: "entry.navlink", named: "Discord").rightClick()
        clickRestoreTestMenu("entry-row.restore-context")
        openGroup(named: "Social")
        XCTAssertTrue(titledRow(identifier: "entry.navlink", named: "Discord").waitForExistence(timeout: 10))
    }

    func testRestoreGroupFromRecycleBinContextMenu() {
        unlockSuccessfully()
        titledRow(identifier: "group.navlink", named: "Work").rightClick()
        clickRestoreTestMenu("group-row.delete-context")
        let delete = databaseWindow.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        // A deleted group is a row of its own in the sidebar's Recycle Bin section,
        // which appears once the delete has rebuilt the sidebar.
        let outline = databaseWindow.outlines[Self.sidebarOutlineIdentifier]
        let binHeader = outline.staticTexts.matching(NSPredicate(format: "value == 'Recycle Bin'")).firstMatch
        XCTAssertTrue(binHeader.waitForExistence(timeout: 10), "The delete did not add a Recycle Bin section")
        let deletedWork = NSPredicate { [self] _, _ in
            titledRow(identifier: "group.navlink", named: "Work").frame.minY > binHeader.frame.minY
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: deletedWork, object: nil)], timeout: 10),
                       .completed, "The deleted group has no row in the Recycle Bin section")
        titledRow(identifier: "group.navlink", named: "Work").rightClick()
        clickRestoreTestMenu("group-row.restore-context")
        openGroup(named: "Work")
        XCTAssertTrue(titledRow(identifier: "entry.navlink", named: "Email").waitForExistence(timeout: 10))
    }

    /// The sidebar or entry row titled `name`: its title field, which carries the row identifier.
    private func titledRow(identifier: String, named name: String) -> XCUIElement {
        let rows = rowQuery(identifier: identifier).matching(NSPredicate(format: "value == %@", name))
        return rows.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 1 } ?? rows.firstMatch
    }

    private func clickRestoreTestMenu(_ identifier: String) {
        let query = app.menuItems.matching(identifier: identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        let item = query.allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable }
        XCTAssertNotNil(item, "Context action missing: \(identifier)")
        item?.click()
    }

    // The inline editor's focus, its Set Up sheet, File > Save (⌘S), the table's row insertion
    // and the detail column following the new selection meet only in the running app.
    func testNewEntryIsSelectedAfterSaving() {
        unlockSuccessfully()
        let window = databaseWindow
        openGroup(named: "Work")
        openEntry(named: "Email")
        typeCommandShortcut("n")
        let titleField = window.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForKeyboardFocus(titleField), "The new entry's title field was not focused")
        let search = window.searchFields.firstMatch
        XCTAssertFalse(search.isEnabled, "The search field stayed enabled while the editor was open")

        let setUp = window.buttons["entry-edit.totp.enter-link"].firstMatch
        scrollIntoView(setUp)
        setUp.click()
        let linkField = window.sheets.textViews["entry-edit.totp.link-field"].firstMatch
        XCTAssertTrue(linkField.waitForExistence(timeout: 5), "Set Up… did not open its sheet")
        XCTAssertTrue(waitForKeyboardFocus(linkField), "The Set Up sheet did not focus its field")
        // A sheet over the editor keeps File > Save from saving the entry behind it.
        typeCommandShortcut("s")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(linkField.exists, "⌘S closed the Set Up sheet")
        XCTAssertTrue(titleField.exists, "⌘S saved the entry behind the Set Up sheet")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(linkField.waitForNonExistence(timeout: 5), "Escape did not close the Set Up sheet")
        XCTAssertTrue(titleField.exists, "Escape in the Set Up sheet also closed the editor")

        titleField.click()
        app.typeText("ZZZ Newly Saved Entry")
        typeCommandShortcut("s")
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 15), "⌘S did not save the new entry")
        XCTAssertTrue(waitForDisplayText("ZZZ Newly Saved Entry", identifier: "entry.navlink"),
                      "The saved entry has no row in its group")
        XCTAssertTrue(waitForDisplayText("ZZZ Newly Saved Entry", identifier: "entry-detail.title"),
                      "The saved entry is not the selected one")
        waitUntilEnabled(search, timeout: 10)
        XCTAssertTrue(search.isEnabled, "The lists stayed frozen after the save")
    }

    /// A live drag session has no unit seam: `MacEntryDropTests` and the
    /// controller tests cover the payload and the drop decision, but only the
    /// running app starts a drag from the table and drops it on an outline row.
    func testDraggingAnEntryOntoASidebarGroupMovesIt() {
        unlockSuccessfully()
        openGroup(named: "Social")
        let discord = titledRow(identifier: "entry.navlink", named: "Discord")
        XCTAssertTrue(discord.waitForExistence(timeout: 10), "Entry 'Discord' is not listed")
        let work = titledRow(identifier: "group.navlink", named: "Work")
        XCTAssertTrue(work.waitForExistence(timeout: 5), "Group 'Work' has no sidebar row")

        discord.click(forDuration: 0.6, thenDragTo: work)

        XCTAssertTrue(waitForRowToDisappear("Discord"), "Dropping 'Discord' on 'Work' left it in 'Social'")
        openGroup(named: "Work")
        XCTAssertTrue(waitForDisplayText("Discord", identifier: "entry.navlink"), "'Discord' did not reach 'Work'")
    }

    private func waitForRowToDisappear(_ title: String, timeout: TimeInterval = 15) -> Bool {
        let gone = NSPredicate { [self] _, _ in
            rowQuery(identifier: "entry.navlink").allElementsBoundByIndex.contains { displayText(of: $0) == title } == false
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: timeout) == .completed
    }

    // MARK: - Unlock

    func testUnlockFailsWithWrongPassword() {
        unlock(password: "definitely-wrong-password")

        let errorLabel = app.staticTexts["unlock.error.label"]
        XCTAssertTrue(errorLabel.waitForExistence(timeout: 30), "Unlock error was not surfaced")
        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        XCTAssertFalse(groupLink.exists, "Vault must not unlock with a wrong password")
    }

    // MARK: - Browse

    // Only the native split view can establish whether a recreated workspace
    // restores the divider position after locking. XCUITest drags do not move
    // split-view dividers on macOS 27, so the drag itself is a manual check and
    // Native split-item constraints are covered by MacWorkspaceSplitViewControllerTests.
    func testSidebarWidthSurvivesRepeatedLockUnlockCycles() throws {
        unlockSuccessfully()
        let window = databaseWindow
        let originalWindowSize = window.frame.size
        let divider = try XCTUnwrap(sidebarDivider(), "The workspace sidebar divider is missing")
        let sidebarPosition = divider.frame.midX - window.frame.minX

        for _ in 0..<3 {
            typeCommandShortcut("l")
            XCTAssertTrue(app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 15))
            XCTAssertFalse(rowQuery(identifier: "group.navlink").firstMatch.exists)
            unlockSuccessfully()

            let restored = NSPredicate { [self] _, _ in
                guard let divider = sidebarDivider() else { return false }
                return abs(divider.frame.midX - window.frame.minX - sidebarPosition) <= 2
            }
            let restoredExpectation = XCTNSPredicateExpectation(predicate: restored, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [restoredExpectation], timeout: 10), .completed,
                           "Unlocking reset the sidebar width")
            XCTAssertEqual(window.frame.width, originalWindowSize.width, accuracy: 2)
            XCTAssertEqual(window.frame.height, originalWindowSize.height, accuracy: 2)
        }
    }

    private func sidebarDivider() -> XCUIElement? {
        app.splitters.allElementsBoundByIndex
            .filter { $0.frame.height > 100 && $0.frame.width < 20 }
            .min { $0.frame.minX < $1.frame.minX }
    }

    // `MacSidebarSnapshotTests` owns which rows appear; only the running app
    // shows the outline rendering them and the entry table following a Library row.
    func testSidebarShowsItsSectionsAndAllEntriesListsEveryGroup() throws {
        unlockSuccessfully()
        let outline = databaseWindow.outlines[Self.sidebarOutlineIdentifier]
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "The sidebar outline is missing")

        func header(_ title: String) -> XCUIElement {
            outline.staticTexts.matching(NSPredicate(format: "value == %@", title)).firstMatch
        }
        for title in ["Library", "Groups", "Tags", "Recycle Bin"] {
            XCTAssertTrue(header(title).exists, "Section header '\(title)' is missing")
        }
        for identifier in ["sidebar.collection.allEntries", "sidebar.collection.verificationCodes",
                           "sidebar.collection.passkeys", "tag-list.row.shared"] {
            XCTAssertTrue(outline.descendants(matching: .any)[identifier].exists, "Sidebar row '\(identifier)' is missing")
        }
        let groupRows = outline.descendants(matching: .any).matching(identifier: "group.navlink")
        for group in ["Tagged", "Projects", "Client Work", "Deleted Entries"] {
            XCTAssertTrue(groupRows.matching(NSPredicate(format: "value == %@", group)).firstMatch.exists,
                          "Group row '\(group)' is missing")
        }
        // The bin's own row sits under the Recycle Bin header, after every group.
        let binRow = try XCTUnwrap(groupRows.matching(NSPredicate(format: "value == 'Deleted Entries'"))
            .allElementsBoundByIndex.first)
        let lastRow = try XCTUnwrap(groupRows.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY })
        XCTAssertEqual(displayText(of: lastRow), "Deleted Entries", "Deleted Entries is not the last sidebar row")
        XCTAssertLessThan(header("Recycle Bin").frame.minY, binRow.frame.minY, "Deleted Entries is above its header")
        XCTAssertGreaterThan(header("Recycle Bin").frame.minY, header("Tags").frame.minY,
                             "The Recycle Bin section is not the last one")

        clickFirstRow(identifier: "sidebar.collection.allEntries")
        for entry in ["Alpha Login", "Beta Login", "Custom Badge"] {
            XCTAssertTrue(waitForDisplayText(entry, identifier: "entry.navlink"), "All Entries did not list '\(entry)'")
        }
        XCTAssertFalse(rowQuery(identifier: "entry.navlink").allElementsBoundByIndex.contains {
            displayText(of: $0) == "Trashed Login"
        }, "All Entries listed a recycled entry")
        XCTAssertTrue(waitForDisplayText("All Entries", identifier: "entry-list.header.title"),
                      "The list header does not name All Entries")
    }

    /// The detail's model and copy feedback are unit-tested (`MacEntryDetailModelTests`,
    /// `MacCopyFeedbackTests`); only the running app shows the row's tick replacing the copy
    /// button and Quick Look's system panel opening from a row and closing on Space.
    func testEntryDetailShowsFieldsAndCopyUsernamePutsValueOnPasteboard() {
        unlockSuccessfully()
        openGroup(named: "Attachments")
        openEntry(named: "Multi Attachment Entry")

        let copyUsername = app.buttons["entry.copy.username"].firstMatch
        XCTAssertTrue(copyUsername.waitForExistence(timeout: 15), "Entry detail did not show the username row")
        let reveal = app.buttons["entry.password.reveal"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 15), "Password reveal button missing")
        reveal.click()
        let plaintext = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "entry-password-1", "entry-password-1")
        ).firstMatch
        XCTAssertTrue(plaintext.waitForExistence(timeout: 10), "Reveal did not expose the fixture password")

        let changeCountBefore = NSPasteboard.general.changeCount
        copyUsername.click()

        let deadline = Date().addingTimeInterval(10)
        while NSPasteboard.general.changeCount == changeCountBefore, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertGreaterThan(NSPasteboard.general.changeCount, changeCountBefore, "Copy Username did not write to the pasteboard")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "multi-user", "Copy Username must copy the fixture entry's username")
        XCTAssertNotNil(
            NSPasteboard.general.string(forType: concealedType),
            "Copies must carry org.nspasteboard.ConcealedType so clipboard managers skip them"
        )
        XCTAssertTrue(waitForLabel("Username copied", of: copyUsername, timeout: 2), "The row did not show the copy tick")
        XCTAssertTrue(waitForLabel("Copy Username", of: copyUsername, timeout: 5), "The copy tick did not go away")

        let quickLook = app.buttons["entry.attachment.quick-look.0"].firstMatch
        scrollIntoView(quickLook)
        let windowsBefore = topLevelWindowCount()
        quickLook.click()
        let opened = NSPredicate { [self] _, _ in topLevelWindowCount() > windowsBefore }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opened, object: nil)], timeout: 10),
                       .completed, "Quick Look did not open a panel")
        app.typeKey(.space, modifierFlags: [])
        let closed = NSPredicate { [self] _, _ in topLevelWindowCount() == windowsBefore }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 10),
                       .completed, "Space did not close the Quick Look panel")
    }

    private func topLevelWindowCount() -> Int {
        app.windows.count + app.dialogs.count
    }

    private func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let matches = NSPredicate { _, _ in element.exists && element.label == label }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: timeout) == .completed
    }

    /// The panel is a borderless window that takes key status; only the running app routes a real
    /// key press, click and menu command to it (`MacLargeTypePanelControllerTests` call
    /// `sendEvent` directly).
    func testLargeTypeShowsThePasswordAndAnyKeyCloses() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")
        let button = app.buttons["entry.password.large-type"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The password row has no Large Type button")
        let panel = app.descendants(matching: .any).matching(identifier: "large-type.panel").firstMatch

        button.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Show in Large Type did not open the panel")
        let header = panel.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                            "13 characters", "13 characters")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "The panel does not count the password's 13 characters")
        app.typeKey("x", modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "A key press did not close Large Type")

        button.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        panel.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "A click on the panel did not close Large Type")

        chooseMenuItem("Show in Large Type", inMenu: "View")
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "View > Show in Large Type did not open the panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Escape did not close Large Type")
    }

    /// The sidebar and entry list are native tables, so the arrow keys are
    /// AppKit's. Only the running app shows a real click making the table first
    /// responder and the detail column following the moved selection.
    func testDownArrowMovesTheEntrySelection() {
        unlockSuccessfully()
        openGroup(named: "Work")
        // Title-ascending is the default sort, so Email precedes GitHub.
        openEntry(named: "Email")

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

        // Left and Right fold and unfold the selected group, as in any source list.
        openGroup(named: "Work")
        let nested = rowQuery(identifier: "group.navlink").matching(NSPredicate(format: "value == 'Internal'")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 5), "'Work' did not start expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertTrue(nested.waitForNonExistence(timeout: 5), "Left arrow did not collapse 'Work'")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(nested.waitForExistence(timeout: 5), "Right arrow did not expand 'Work'")
    }

    // MARK: - Search (⌘F)

    func testSearchViaCommandFShowsResultCount() {
        unlockSuccessfully()

        typeCommandShortcut("f")
        app.typeText("GitHub")

        XCTAssertTrue(waitForDisplayText("GitHub", identifier: "search.entry.navlink"),
                      "The search results did not list 'GitHub'")
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
        XCTAssertTrue(waitForDisplayText("Search", identifier: "entry-list.header.title"),
                      "The list header does not show the search")
    }

    // MARK: - Edit + save

    /// Protect Field swaps the value for a secure field, the save writes the protection, and the
    /// detail then gates the value; the reverse removes the reveal. Opens through the header's Edit.
    func testCustomFieldProtectionPersistsInTheNativeEditor() {
        unlockSuccessfully()
        openGroup(named: "Social")
        openEntry(named: "Discord")
        let edit = app.buttons["entry-detail.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "The detail header has no Edit button")
        edit.click()
        let add = app.buttons["entry-edit.custom-field.add"].firstMatch
        scrollIntoView(add)
        add.click()
        let name = app.textFields["entry-edit.custom-field.name-field.0"].firstMatch
        scrollIntoView(name)
        name.click()
        app.typeText("PIN")
        let value = app.textFields["entry-edit.custom-field.value-field.0"].firstMatch
        scrollIntoView(value)
        value.click()
        app.typeText("1234")
        let protect = app.buttons["entry-edit.custom-field.protection.0"].firstMatch
        scrollIntoView(protect)
        XCTAssertFalse(protect.isSelected)
        protect.click()
        XCTAssertTrue(app.secureTextFields["entry-edit.custom-field.value-field.0"].firstMatch.waitForExistence(timeout: 5),
                      "Protect Field did not conceal the value")
        let save = app.buttons["entry-edit.save"].firstMatch
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 15))
        let reveal = app.buttons["entry.protected-field.pin.reveal"].firstMatch
        scrollIntoView(reveal)
        // macOS exposes static text as its value, not its label.
        let plaintext = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "1234", "1234")).firstMatch
        XCTAssertFalse(plaintext.exists)
        reveal.click()
        XCTAssertTrue(plaintext.waitForExistence(timeout: 5))
        edit.click()
        scrollIntoView(protect)
        XCTAssertTrue(protect.isSelected, "The saved field did not reopen protected")
        protect.click()
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 15))
        XCTAssertTrue(reveal.waitForNonExistence(timeout: 5), "The unprotected field still offers a reveal")
    }

    /// The table's `doubleAction` opens the clicked row in the workspace's one editor: unit tests
    /// reach `openEntry(atRow:)` but cannot synthesize `clickedRow`. Only a real window shows the
    /// title field taking focus, Tab moving on without the editor taking it back, the lists frozen
    /// while it is open, and ⌘S from the generator popover saving the entry.
    func testEditEntryTitleAndSavePersists() {
        unlockSuccessfully()
        let window = databaseWindow
        openGroup(named: "Social")
        let row = titledRow(identifier: "entry.navlink", named: "Discord")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Entry 'Discord' is not listed")
        row.doubleClick()

        let titleField = window.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 15), "Double-clicking the entry row did not open the editor")
        XCTAssertEqual(titleField.value as? String, "Discord", "The editor opened another entry")
        XCTAssertTrue(waitForKeyboardFocus(titleField), "The editor did not focus its title field")
        app.typeKey(.tab, modifierFlags: [])
        let username = window.textFields["entry-edit.username-field"].firstMatch
        XCTAssertTrue(waitForKeyboardFocus(username), "Tab did not move from the title to the username")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(username.value(forKey: "hasKeyboardFocus") as? Bool, true,
                       "A content update took focus away from the username field")
        XCTAssertFalse(window.searchFields.firstMatch.isEnabled, "The search field stayed enabled while editing")

        titleField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Discord Renamed")
        window.buttons["entry-edit.password-generator-button"].firstMatch.click()
        let use = app.buttons["password-generator.use"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 5), "Generate did not open the popover")
        typeCommandShortcut("s")
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 15), "⌘S in the generator popover did not save the entry")
        XCTAssertFalse(use.exists, "The popover outlived its editor")

        // The table reconfigures the row in place; its title field carries the new title.
        XCTAssertTrue(
            waitForDisplayText("Discord Renamed", identifier: "entry.navlink", timeout: 30),
            "Renamed entry did not appear after save"
        )
        XCTAssertFalse(rowQuery(identifier: "entry.navlink").allElementsBoundByIndex.contains {
            displayText(of: $0) == "Discord"
        }, "The old title is still listed")
        XCTAssertTrue(waitForDisplayText("Discord Renamed", identifier: "entry-detail.title"),
                      "The detail did not return after the save")
    }

    // MARK: - Menu-bar commands

    /// ⌘W closes the database window when nothing is unsaved, and its vault
    /// locks without the app quitting: the Databases window reopens it on the
    /// unlock screen. `MacWindowCloseGuard` proxies the window delegate so it
    /// can hold a close open for unsaved work; this is the check that an
    /// ordinary close still passes straight through that proxy.
    ///
    /// The decision itself is unit-tested (`MacWindowCloseGuardTests`,
    /// `DatabaseViewModelTests`'s window-close section, both headless). What no
    /// unit test can reach is AppKit routing a real close into
    /// `windowShouldClose(_:)` on a window this app actually put on screen.
    func testCommandWClosesTheWindowAndLeavesTheAppRunning() {
        unlockSuccessfully()
        let window = databaseWindow

        typeCommandShortcut("w")

        XCTAssertTrue(window.waitForNonExistence(timeout: 15), "⌘W did not close the database window")
        XCTAssertEqual(databaseWindows.count, 0)
        XCTAssertEqual(app.state, .runningForeground, "Closing a database window must not quit the app")

        let reopened = openDatabase(named: "test")
        XCTAssertTrue(waitForLockedState(in: reopened), "The closed window's database did not lock")
    }

    func testSettingsWindowOpensViaCommandComma() {
        openFirstDatabaseFromListIfNeeded()

        typeCommandShortcut(",")

        let settingsWindow = self.settingsWindow
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 15), "⌘, did not open the Settings window")

        // The window reopens on whichever tab was used last, which persists in
        // the app's preferences across launches; pick Security explicitly.
        selectSettingsTab(named: "Security")

        let lockPolicyPicker = app.descendants(matching: .any)
            .matching(identifier: "settings.lock-policy.picker")
            .firstMatch
        XCTAssertTrue(lockPolicyPicker.waitForExistence(timeout: 15), "Settings window did not show the lock-policy picker")
    }

    /// Real settings-window keystrokes prove that disabling the SwiftUI
    /// recorder removes its AppKit monitor; a controller test cannot reach it.
    func testDisablingMenuBarDuringShortcutRecordingRestoresWindowCommands() throws {
        typeCommandShortcut(",")
        let settingsWindow = self.settingsWindow
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 15))
        XCTAssertTrue(selectSettingsTab(named: "Menu Bar"))

        let toggleQuery = settingsWindow.descendants(matching: .any)
            .matching(identifier: "settings.menu-bar.toggle")
        XCTAssertTrue(toggleQuery.firstMatch.waitForExistence(timeout: 10))
        let toggle = try XCTUnwrap(toggleQuery.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.height > 1
                && ($0.elementType == .checkBox || $0.elementType == .switch || $0.elementType == .button)
        }, "The menu-bar toggle did not expose a clickable native control")
        let recorder = settingsWindow.buttons["settings.menu-bar.shortcut-recorder"].firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        let wasEnabled = recorder.isEnabled
        if !wasEnabled { toggle.click() }
        XCTAssertTrue(recorder.isEnabled)
        let originalShortcut = displayText(of: recorder)
        recorder.click()
        XCTAssertTrue(waitForDisplayText("Type Shortcut…", identifier: "settings.menu-bar.shortcut-recorder"))

        toggle.click()

        XCTAssertTrue(waitForDisplayText(originalShortcut, identifier: "settings.menu-bar.shortcut-recorder"))
        XCTAssertFalse(recorder.isEnabled)
        typeCommandShortcut("w")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settingsWindow)
        waitForExpectations(timeout: 10)

        if wasEnabled {
            typeCommandShortcut(",")
            XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10))
            XCTAssertTrue(selectSettingsTab(named: "Menu Bar"))
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
        }
    }

    /// This verifies SwiftUI observes the deferred route after the inline editor
    /// settles a lock request (Lock, ⌘W and Close Database); routing unit tests
    /// cover the decision itself.
    func testCloseDatabaseWaitsForDirtyEditorAndClosesTheWindowAfterDiscard() {
        unlockSuccessfully()
        let window = databaseWindow
        typeCommandShortcut("n")
        let titleField = window.textFields["entry-edit.title-field"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 15))
        titleField.click()
        app.typeText("Unsaved Close Database Entry")

        let keepEditing = window.sheets.buttons["Keep Editing"].firstMatch
        let commands: [(key: String, modifiers: XCUIElement.KeyModifierFlags, name: String)] = [
            ("l", .command, "Lock"), ("w", .command, "⌘W"), ("w", [.command, .shift], "Close Database"),
        ]
        for (key, modifiers, command) in commands {
            typeCommandShortcut(key, modifiers: modifiers)
            XCTAssertTrue(keepEditing.waitForExistence(timeout: 10), "\(command) did not prompt for the dirty editor")
            if command == "Close Database" { break }
            XCTAssertTrue(keepEditing.isHittable)
            keepEditing.click()
            XCTAssertTrue(keepEditing.waitForNonExistence(timeout: 5))
            XCTAssertEqual(titleField.value as? String, "Unsaved Close Database Entry", "\(command) changed the editor")
            XCTAssertTrue(window.exists, "Keep Editing after \(command) closed the database window")
            XCTAssertTrue(rowQuery(identifier: "group.navlink").firstMatch.exists, "Keep Editing after \(command) locked")
        }

        let discard = window.sheets.buttons["Discard and Lock"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        XCTAssertTrue(discard.isHittable)
        discard.click()

        XCTAssertTrue(window.waitForNonExistence(timeout: 15), "Discarding the editor did not complete Close Database")
        XCTAssertEqual(databaseWindows.count, 0)
        XCTAssertTrue(databaseRow(containing: "test").waitForExistence(timeout: 10), "The Databases window was not shown")
    }

    // MARK: - Unlock keyboard handling

    // `MacUnlockPasswordFieldTests` covers the focus lifecycle headlessly; only a
    // real sidebar click and real key events prove the hand-off users hit.
    // Neither test clicks the field: that would hide a focus failure.

    func testOpeningDatabaseFocusesPasswordField() {
        openFirstDatabaseFromListIfNeeded()

        let passwordField = databaseWindow.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForKeyboardFocus(passwordField), "Password field was not focused after opening the database")

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
        XCTAssertFalse(unlockButton.isEnabled, "Unlock button must start disabled with an empty password")

        app.typeText("x")

        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: unlockButton)
        waitForExpectations(timeout: 5)
    }

    func testEscapeInUnlockClosesTheWindowAndShowsDatabases() {
        openFirstDatabaseFromListIfNeeded()
        let window = databaseWindow

        let passwordField = window.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForKeyboardFocus(passwordField), "Password field was not focused after opening the database")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(window.waitForNonExistence(timeout: 10), "Escape did not close the database window")
        XCTAssertTrue(databaseRow(containing: "test").waitForExistence(timeout: 10), "The Databases window was not shown after Escape")
    }

}

/// Reveal/copy-password authentication boundary.
///
/// The real device-owner prompt is a system dialog XCUITest cannot dismiss, so
/// the app skips the gate entirely under `-ui-testing`. Launching with
/// `UI_TEST_DEVICE_OWNER_AUTH_PENDING` re-arms it with a stub that never
/// completes — exactly the state a user is in while the prompt is on screen —
/// so these tests can assert that authentication is requested and that nothing
/// is disclosed until it succeeds.
@MainActor
final class MacPasswordAuthBoundaryUITests: MacUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_DEVICE_OWNER_AUTH_PENDING"] = "1"
    }

    func testRevealPasswordRequiresAuthentication() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")

        let reveal = app.buttons["entry.password.reveal"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 15), "Password reveal button missing")
        let plaintext = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "githubpass789", "githubpass789")
        ).firstMatch
        XCTAssertFalse(plaintext.exists, "Password was visible before reveal")
        reveal.click()

        // The reveal button disables while authentication is in flight, which
        // is the observable proof that the click went to the device-owner gate
        // rather than straight to the plaintext.
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
        XCTAssertFalse(
            plaintext.waitForExistence(timeout: 3),
            "Password was revealed while device-owner authentication was still pending"
        )
        XCTAssertFalse(app.buttons["entry.password.large-type"].firstMatch.isEnabled,
                       "Large Type stayed available while authentication was pending")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "large-type.panel").firstMatch.exists,
                       "Large Type showed the password while authentication was pending")
    }

    func testCopyPasswordDoesNotCopyWithoutAuthentication() {
        unlockSuccessfully()
        openGroup(named: "Work")
        openEntry(named: "GitHub")

        let copyPassword = app.buttons["entry.copy.password"].firstMatch
        XCTAssertTrue(copyPassword.waitForExistence(timeout: 15), "Copy password button missing")

        let changeCountBefore = NSPasteboard.general.changeCount
        copyPassword.click()

        // Nothing may land on the pasteboard while authentication is pending.
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

    /// A single click only selects; Return opens. Removing a database whose
    /// window is open closes that window and leaves the other row.
    func testDatabaseListShowsSeededDatabasesAndRemovesOne() {
        let testRow = databaseRow(containing: "test")
        let demoRow = databaseRow(containing: "demo")
        XCTAssertTrue(testRow.waitForExistence(timeout: 15), "Seeded test.kdbx row missing")
        XCTAssertTrue(demoRow.waitForExistence(timeout: 15), "Seeded demo.kdbx row missing")

        selectDatabaseRow(containing: "demo")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(databaseWindows.count, 0, "A single click on a database row opened it")

        app.typeKey(.return, modifierFlags: [])
        let demoWindow = databaseWindow(named: "demo")
        XCTAssertTrue(
            demoWindow.secureTextFields["unlock.password.field"].waitForExistence(timeout: 15),
            "Return did not open the selected database in its own window"
        )

        showDatabasesWindow()
        selectDatabaseRow(containing: "demo")?.rightClick()

        let removeMenuItem = app.menuItems.matching(identifier: "database-row.remove").firstMatch
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 10), "Remove context-menu item missing")
        removeMenuItem.click()

        // Scope to the window so the query cannot match Touch Bar elements
        // (which XCUITest refuses to click).
        let confirmRemove = databasesWindow.buttons["databases.remove.confirm"].firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 10), "Remove confirmation did not appear")
        confirmRemove.click()

        let deadline = Date().addingTimeInterval(15)
        while demoRow.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(demoRow.exists, "demo.kdbx row was not removed")
        XCTAssertTrue(testRow.exists, "test.kdbx row must survive the removal")
        XCTAssertTrue(demoWindow.waitForNonExistence(timeout: 15), "The removed database's window stayed open")
    }
}

@MainActor
final class MacCustomIconManagementUITests: MacUITestCase {
    override var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    func testRenameCancelAndDeleteStoredIcon() {
        let uuid = "4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77"
        unlockSuccessfully()
        openGroup(named: "Icons")
        openEntry(named: "Custom Badge")
        let iconButton = app.buttons["entry-detail.icon-button"]
        XCTAssertTrue(iconButton.waitForExistence(timeout: 10))
        iconButton.click()
        let manage = app.buttons["entry-icon-picker.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.click()
        let rename = app.buttons["custom-icons.rename.\(uuid)"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        rename.click()
        let name = app.textFields["custom-icons.rename-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("Website Badge")
        app.buttons["custom-icons.rename-save"].click()
        XCTAssertTrue(waitForDisplayText("Website Badge", identifier: "custom-icons.name.\(uuid)"))
        let delete = app.buttons["custom-icons.delete.\(uuid)"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        delete.click()
        let cancel = app.buttons["custom-icons.delete-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(rename.exists)
        delete.click()
        let confirm = app.buttons["custom-icons.confirm-delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(rename.waitForNonExistence(timeout: 15))
    }
}
