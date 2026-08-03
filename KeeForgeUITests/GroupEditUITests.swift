import XCTest

/// Coverage for the group editor reached from a group row's context menu:
/// rename, tags, notes, icon, Search & AutoFill visibility, cancel/discard,
/// protected-group behavior, the duplicate-name error, and the read-only
/// database offering no entry point at all.
@MainActor
final class GroupEditUITests: EntryEditUITestCase {
    private let renamedGroupName = "UI Renamed Group"
    private let discardedGroupName = "UI Discarded Group"
    private let addedTag = "uitag"

    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        if name.contains("testReadOnly") {
            app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = "1"
        }
    }

    func testEditGroupContextActionOpensTheEditorOnThatGroup() {
        unlockSuccessfully()

        openGroupEditor(forGroupNamed: socialGroupName)

        let nameField = app.textFields["group-edit.name-field"]
        XCTAssertEqual(
            nameField.value as? String,
            socialGroupName,
            "The editor should open on the long-pressed group's current name"
        )
        XCTAssertTrue(app.buttons["group-edit.cancel"].exists, "Editor is missing its Cancel action")
        XCTAssertTrue(app.buttons["group-edit.save"].exists, "Editor is missing its Save action")
    }

    func testRenamingAGroupUpdatesTheRow() {
        unlockSuccessfully()

        openGroupEditor(forGroupNamed: socialGroupName)
        replaceText(in: app.textFields["group-edit.name-field"], with: renamedGroupName)
        saveGroupEditor()

        XCTAssertTrue(
            waitForGroupRow(named: renamedGroupName),
            "Renamed group did not appear in the list"
        )
        XCTAssertFalse(
            groupNavRow(named: socialGroupName).exists,
            "The old group name should be gone after the rename"
        )
    }

    /// A group tag has no row-level display, so reopening the editor is the only
    /// observable proof that the tag reached the group and was read back out.
    func testAddingATagPersistsAndIsVisibleWhenTheEditorReopens() {
        unlockSuccessfully()

        openGroupEditor(forGroupNamed: workGroupName)

        let tagsField = app.textFields["group-edit.tags-field"]
        XCTAssertTrue(tagsField.waitForExistence(timeout: 5), "Tags field was not visible")
        replaceText(in: tagsField, with: addedTag)
        tagsField.typeText("\n")

        let tagChip = app.buttons["group-edit.tag.\(addedTag)"]
        XCTAssertTrue(tagChip.waitForExistence(timeout: 5), "Committing the tag did not add a pill")

        saveGroupEditor()

        openGroupEditor(forGroupNamed: workGroupName)
        XCTAssertTrue(
            app.buttons["group-edit.tag.\(addedTag)"].waitForExistence(timeout: Self.ciElementTimeout),
            "The saved tag did not come back when the editor reopened"
        )
    }

    func testNotesIconAndVisibilitySaveTogether() {
        let notes = "Group editor UI notes"

        unlockSuccessfully()
        openGroupEditor(forGroupNamed: workGroupName)

        let iconButton = app.buttons["group-edit.icon-button"]
        XCTAssertTrue(iconButton.waitForExistence(timeout: 5), "Icon button was not visible")
        tapElement(iconButton)
        let iconButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'group-icon-picker.icon.'")
        )
        XCTAssertTrue(iconButtons.firstMatch.waitForExistence(timeout: 5), "Icon picker did not present")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let replacementIcon = app.buttons["group-icon-picker.icon.37"]
        XCTAssertTrue(replacementIcon.waitForExistence(timeout: 5), "Replacement icon was not visible")
        XCTAssertTrue(replacementIcon.isHittable, "Replacement icon was not hittable after the picker settled")
        tapElement(replacementIcon)

        let notesField = app.textViews["group-edit.notes-field"]
        XCTAssertTrue(revealElement(notesField, in: scrollableContainer()), "Notes field was not reachable")
        replaceText(in: notesField, with: notes)

        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let doneButton = app.buttons["group-edit.keyboard-done"]
            XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Keyboard Done button was not available")
            tapElement(doneButton)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Keyboard did not dismiss before editing visibility")
        }

        let visibilityToggle = app.switches["group-edit.autofill-toggle"]
        XCTAssertTrue(revealElement(visibilityToggle, in: scrollableContainer()), "Visibility toggle was not reachable")
        setSwitch(visibilityToggle, isOn: true)

        saveGroupEditor()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "group-row.autofill-excluded").firstMatch
                .waitForExistence(timeout: Self.ciElementTimeout),
            "Saved visibility change did not mark the group as hidden"
        )

        openGroupEditor(forGroupNamed: workGroupName)
        let reopenedIconButton = app.buttons["group-edit.icon-button"]
        XCTAssertTrue(reopenedIconButton.waitForExistence(timeout: 5), "Icon button was not visible")
        XCTAssertEqual(reopenedIconButton.value as? String, "37", "Saved icon did not persist")

        let reopenedNotes = app.textViews["group-edit.notes-field"]
        XCTAssertTrue(revealElement(reopenedNotes, in: scrollableContainer()), "Saved notes field was not reachable")
        XCTAssertEqual(reopenedNotes.value as? String, notes)
    }

    func testCancellingDiscardsTheRename() {
        unlockSuccessfully()

        openGroupEditor(forGroupNamed: socialGroupName)
        replaceText(in: app.textFields["group-edit.name-field"], with: discardedGroupName)

        tapElement(app.buttons["group-edit.cancel"])

        let discardAlert = app.alerts["Discard changes?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5), "Discard confirmation did not appear")
        discardAlert.buttons["Discard Changes"].tap()

        XCTAssertTrue(
            waitForGroupRow(named: socialGroupName),
            "The original group name should survive a discarded edit"
        )
        XCTAssertFalse(
            groupNavRow(named: discardedGroupName).exists,
            "A discarded rename must not reach the list"
        )
    }

    func testRenamingToASiblingsNameSurfacesAnErrorAndKeepsBothGroups() {
        unlockSuccessfully()

        openGroupEditor(forGroupNamed: socialGroupName)
        replaceText(in: app.textFields["group-edit.name-field"], with: workGroupName)

        let saveButton = app.buttons["group-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button was not visible")
        tapElement(saveButton)

        // Curly apostrophe: the alert title is "Couldn’t Update Group".
        let errorAlert = app.alerts["Couldn\u{2019}t Update Group"]
        XCTAssertTrue(
            errorAlert.waitForExistence(timeout: Self.ciElementTimeout),
            "Renaming onto a sibling's name should surface the update error"
        )
        errorAlert.buttons["OK"].tap()

        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "The editor should stay open after a rejected rename"
        )
        tapElement(app.buttons["group-edit.cancel"])
        let discardAlert = app.alerts["Discard changes?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5), "Discard confirmation did not appear")
        discardAlert.buttons["Discard Changes"].tap()

        XCTAssertTrue(waitForGroupRow(named: socialGroupName), "The renamed-from group disappeared")
        XCTAssertTrue(waitForGroupRow(named: workGroupName), "The sibling group disappeared")
    }

    func testReadOnlyDatabaseOffersNoEditGroupContextAction() {
        unlockSuccessfully()

        XCTAssertTrue(
            readOnlyIndicator().waitForExistence(timeout: Self.ciElementTimeout),
            "Read-only indicator did not appear"
        )

        let row = groupNavRow(named: socialGroupName)
        XCTAssertTrue(revealElement(row), "Group '\(socialGroupName)' was not visible")
        row.press(forDuration: 1.2)

        XCTAssertFalse(
            app.buttons["group-row.edit-context"].waitForExistence(timeout: 3),
            "A read-only database must not offer Edit Group"
        )
    }

    func testRecycleBinOffersNoEditGroupContextAction() {
        unlockSuccessfully()
        createRecycleBinByDeletingEmptyGroup()

        let row = groupNavRow(named: recycleBinGroupName)
        XCTAssertTrue(revealElement(row), "Recycle Bin group was not visible")
        row.press(forDuration: 1.2)

        XCTAssertFalse(
            app.buttons["group-row.edit-context"].waitForExistence(timeout: 3),
            "Recycle Bin must not offer Edit Group"
        )
    }

    // MARK: - Helpers

    /// Long-presses the group row and taps "Edit Group", retrying the press
    /// because XCTest can report a row as hittable just before the gesture is
    /// swallowed by list settling or a saving overlay.
    private func openGroupEditor(
        forGroupNamed name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let editAction = app.buttons["group-row.edit-context"]
        for _ in 0..<4 where editAction.exists == false {
            let row = groupNavRow(named: name)
            if revealElement(row), row.isHittable {
                row.press(forDuration: 1.2)
                if editAction.waitForExistence(timeout: 2) {
                    break
                }
            }
        }
        XCTAssertTrue(
            editAction.waitForExistence(timeout: 2),
            "Edit Group was not in the '\(name)' context menu",
            file: file,
            line: line
        )
        tapElement(editAction)

        XCTAssertTrue(
            app.textFields["group-edit.name-field"].waitForExistence(timeout: Self.ciElementTimeout),
            "Group editor did not open for '\(name)'",
            file: file,
            line: line
        )
    }

    private func saveGroupEditor(file: StaticString = #filePath, line: UInt = #line) {
        let saveButton = app.buttons["group-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button was not visible", file: file, line: line)
        tapElement(saveButton)
        XCTAssertTrue(
            waitForSaveCompletion(saveButton: saveButton, timeout: 15, dismissConflict: true),
            "Group editor did not dismiss after save",
            file: file,
            line: line
        )
    }

    /// Group rows only, unlike the inherited `firstRowMatching`, which also
    /// matches any button or cell whose label contains the name — too loose for
    /// the "this name is gone" assertions.
    private func groupNavRow(named name: String) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'group.navlink' AND label CONTAINS[c] %@", name)
        )
        let candidates = query.allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
            ?? candidates.first(where: { $0.exists })
            ?? query.firstMatch
    }

    private func waitForGroupRow(
        named name: String,
        timeout: TimeInterval = KeeForgeUITestCase.ciElementTimeout
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if groupNavRow(named: name).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return groupNavRow(named: name).exists
    }

    private func createRecycleBinByDeletingEmptyGroup(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emptyGroup = group(named: "Empty")
        XCTAssertTrue(revealElement(emptyGroup), "Empty group was not visible", file: file, line: line)

        let deleteButton = revealSwipeDeleteButton(
            on: emptyGroup,
            identifier: "group-row.delete-swipe",
            file: file,
            line: line
        )
        deleteButton.tap()

        let alert = app.alerts["Delete Group?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete group alert was not visible", file: file, line: line)
        alert.buttons["Delete"].tap()
        waitForAutosaveAttempt()
    }
}
