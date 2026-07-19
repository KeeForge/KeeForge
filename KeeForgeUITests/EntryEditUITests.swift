import XCTest

@MainActor
class EntryEditUITestCase: KeeForgeUITestCase {
    let workGroupName = "Work"
    let socialGroupName = "Social"
    let recycleBinGroupName = "Recycle Bin"

    let discordEntryTitle = "Discord"
    let twitterEntryTitle = "Twitter"

    let createdEntryTitle = "AAA UI Created Entry"
    let generatedPasswordEntryTitle = "AAB Generated Password Entry"
    let editedDiscordTitle = "Discord UI Edited"
    let firstConflictDiscordTitle = "Discord Conflict Pass 1"
    let secondConflictDiscordTitle = "Discord Conflict Pass 2"

    override func configureLaunch(app: XCUIApplication) throws {
        if name.contains("testSaveConflictOffersReloadAndConflictCopy") {
            app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "2"
        }
        if name.contains("testReadOnlyDatabase") {
            app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = "1"
        }
    }

    func openAddMenu(file: StaticString = #filePath, line: UInt = #line) {
        let addButton = app.buttons["entry-list.add-entry"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add menu button was not visible", file: file, line: line)

        // Right after a create/save the workspace is briefly disabled behind the
        // saving overlay, so the first tap can be swallowed. Retry until the menu
        // items actually appear.
        let newEntryItem = app.buttons["New Entry"]
        let newGroupItem = app.buttons["New Group"]
        for _ in 0..<4 {
            addButton.tap()
            if newEntryItem.waitForExistence(timeout: 2) || newGroupItem.exists {
                return
            }
        }
        XCTAssertTrue(
            newEntryItem.waitForExistence(timeout: 2) || newGroupItem.exists,
            "Add menu did not open",
            file: file,
            line: line
        )
    }

    func tapAddEntry(file: StaticString = #filePath, line: UInt = #line) {
        openAddMenu(file: file, line: line)

        let newEntryButton = app.buttons["New Entry"]
        XCTAssertTrue(newEntryButton.waitForExistence(timeout: 5), "New Entry action was not visible", file: file, line: line)
        newEntryButton.tap()
    }

    func createGroup(
        named name: String,
        expectSuccess: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openAddMenu(file: file, line: line)

        let newGroupButton = app.buttons["New Group"]
        XCTAssertTrue(newGroupButton.waitForExistence(timeout: 5), "New Group action was not visible", file: file, line: line)
        newGroupButton.tap()

        let nameField = app.textFields["group-create.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Group name field was not visible", file: file, line: line)
        replaceText(in: nameField, with: name)

        let createButton = app.buttons["group-create.confirm"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create group button was not visible", file: file, line: line)
        createButton.tap()

        if expectSuccess {
            XCTAssertTrue(waitForElementToDisappear(createButton, timeout: 5), "Group prompt did not dismiss after creation", file: file, line: line)
        }
    }

    func createEntry(
        title: String,
        username: String?,
        password: String?,
        expectDismissAfterSave: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapAddEntry(file: file, line: line)

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Title field was not visible", file: file, line: line)
        replaceText(in: titleField, with: title)

        if let username {
            let usernameField = app.textFields["entry-edit.username-field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 5), "Username field was not visible", file: file, line: line)
            replaceText(in: usernameField, with: username)
        }

        if let password {
            let passwordField = app.textFields["entry-edit.password-field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field was not visible", file: file, line: line)
            replaceText(in: passwordField, with: password)
        }

        let saveButton = app.buttons["entry-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Entry editor save button was not visible", file: file, line: line)
        saveButton.tap()
        XCTAssertTrue(
            waitForSaveCompletion(saveButton: saveButton, timeout: 10, dismissConflict: true) == expectDismissAfterSave,
            expectDismissAfterSave ? "Entry editor did not dismiss after save" : "Entry editor unexpectedly dismissed after save",
            file: file,
            line: line
        )
    }

    func editCurrentEntryTitle(to title: String, file: StaticString = #filePath, line: UInt = #line) {
        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Edit button was not visible", file: file, line: line)
        editButton.tap()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Title field was not visible", file: file, line: line)
        replaceText(in: titleField, with: title)

        let saveButton = app.buttons["entry-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Entry editor save button was not visible", file: file, line: line)
        saveButton.tap()
        XCTAssertTrue(waitForSaveCompletion(saveButton: saveButton, timeout: 10), "Entry editor did not dismiss after save", file: file, line: line)
    }

    func lockAndReopenVault(file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible", file: file, line: line)
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after locking", file: file, line: line)
        unlockSuccessfully(file: file, line: line)
    }

    func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let group = firstRowMatching(name: name, preferredIdentifier: "group.navlink")
        XCTAssertTrue(revealElement(group), "Group '\(name)' was not visible", file: file, line: line)
        tapElement(group)

        // A freshly rebuilt list — e.g. immediately after `reloadDiscardingDraft`
        // resets the navigation stack — can swallow the first tap. Confirm we
        // actually pushed into the group (its title becomes the nav bar) and
        // retry once if the tap did not register.
        if app.navigationBars[name].waitForExistence(timeout: 5) == false {
            let retry = firstRowMatching(name: name, preferredIdentifier: "group.navlink")
            if revealElement(retry) {
                tapElement(retry)
            }
        }
    }

    /// Swipes a row open and waits for its trailing delete action, retrying the
    /// swipe because a single `swipeLeft()` occasionally fails to reveal the
    /// action under load.
    @discardableResult
    func revealSwipeDeleteButton(
        on row: XCUIElement,
        identifier: String,
        attempts: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deleteButton = app.buttons[identifier]
        for _ in 0..<attempts {
            row.swipeLeft()
            if deleteButton.waitForExistence(timeout: 2) {
                return deleteButton
            }
        }
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 2),
            "Swipe delete action '\(identifier)' was not visible",
            file: file,
            line: line
        )
        return deleteButton
    }

    /// Opens a row context menu and waits for its delete action, retrying the
    /// long press because XCTest can report a row as hittable just before the
    /// gesture is swallowed by list settling or the saving overlay.
    @discardableResult
    func revealContextDeleteButton(
        rowNamed name: String,
        identifier: String,
        preferredIdentifier: String,
        attempts: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deleteButton = app.buttons[identifier]
        for _ in 0..<attempts {
            let row = firstRowMatching(name: name, preferredIdentifier: preferredIdentifier)
            if revealElement(row) {
                row.press(forDuration: 1.2)
                if deleteButton.waitForExistence(timeout: 2) {
                    return deleteButton
                }
            }
        }
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 2),
            "Context delete action '\(identifier)' was not visible for row '\(name)'",
            file: file,
            line: line
        )
        return deleteButton
    }

    func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = firstRowMatching(name: name, preferredIdentifier: "entry.navlink")
        XCTAssertTrue(revealElement(entry), "Entry '\(name)' was not visible", file: file, line: line)
        tapElement(entry)
    }

    func openEntry(named entryName: String, inGroup groupName: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.navigationBars[groupName].exists == false {
            openGroup(named: groupName, file: file, line: line)
        }
        openEntry(named: entryName, file: file, line: line)
    }

    func entry(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'entry.navlink' AND label CONTAINS[c] %@", name)
        ).firstMatch
    }

    func group(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'group.navlink' AND label CONTAINS[c] %@", name)
        ).firstMatch
    }

    func readOnlyIndicator() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "database.read-only-indicator").firstMatch
    }

    func waitForUnsavedIndicator(
        isPresent: Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        let indicator = app.descendants(matching: .any).matching(identifier: "database.unsaved-indicator").firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if indicator.exists == isPresent {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return indicator.exists == isPresent
    }

    /// Wait for the save to complete. Returns true if the save button disappears
    /// (normal save) or a conflict alert appears (conflict save).
    func waitForSaveCompletion(
        saveButton: XCUIElement,
        timeout: TimeInterval = 10,
        dismissConflict: Bool = false
    ) -> Bool {
        let conflictCancelButton = app.buttons["save-conflict.cancel"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if saveButton.exists == false { return true }
            if conflictCancelButton.exists {
                if dismissConflict {
                    conflictCancelButton.tap()
                    return waitForElementToDisappear(saveButton, timeout: 5)
                }
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return saveButton.exists == false
    }

    func waitForSaveConflictAlert(timeout: TimeInterval = 10) -> Bool {
        app.alerts["Save Conflict"].waitForExistence(timeout: timeout)
    }

    func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if element.exists == false {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return element.exists == false
    }

    func waitForAutosaveAttempt(timeout: TimeInterval = 2) {
        RunLoop.current.run(until: Date().addingTimeInterval(timeout))
    }

    func tapBackButton(file: StaticString = #filePath, line: UInt = #line) {
        let excludedIdentifiers = Set([
            "entry-list.add-entry",
            "lock.button",
            "sort.menu",
            "settings.button",
            "entry-detail.edit",
            "entry-edit.cancel",
            "entry-edit.save",
        ])
        let excludedLabels = Set(["Edit", "Cancel", "Save"])

        let deadline = Date().addingTimeInterval(5)
        repeat {
            for navigationBar in app.navigationBars.allElementsBoundByIndex
            where navigationBar.exists && navigationBar.isHittable {
                if let backButton = navigationBar.buttons.allElementsBoundByIndex.first(where: {
                    $0.exists
                        && $0.isHittable
                        && excludedIdentifiers.contains($0.identifier) == false
                        && excludedLabels.contains($0.label) == false
                }) {
                    backButton.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline

        XCTFail("Back button was not found", file: file, line: line)
    }

    func firstRowMatching(name: String, preferredIdentifier: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", name)
        let preferredQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@", preferredIdentifier, name)
        )
        let buttonQuery = app.buttons.matching(predicate)
        let cellQuery = app.cells.matching(predicate)

        let candidates = preferredQuery.allElementsBoundByIndex + buttonQuery.allElementsBoundByIndex + cellQuery.allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
            ?? candidates.first(where: { $0.exists })
            ?? preferredQuery.firstMatch
    }
}

@MainActor
final class EntryCreateSmokeUITests: EntryEditUITestCase {
    func testCreateEntryInWorkGroupSavesAndShowsInList() {
        unlockSuccessfully()

        openGroup(named: workGroupName)
        createEntry(
            title: createdEntryTitle,
            username: "ui-created-user",
            password: nil
        )

        tapBackButton()
        openGroup(named: workGroupName)
        XCTAssertTrue(
            revealElement(entry(named: createdEntryTitle)),
            "Created entry was not visible in the Work group after saving"
        )
        openEntry(named: createdEntryTitle)
        XCTAssertTrue(app.staticTexts["ui-created-user"].waitForExistence(timeout: 5))
    }

    func testCreateGroupInWorkGroupSavesAndShowsInList() {
        unlockSuccessfully()

        openGroup(named: workGroupName)
        createGroup(named: "UI Created Group")
        waitForAutosaveAttempt()

        XCTAssertTrue(
            revealElement(firstRowMatching(name: "UI Created Group", preferredIdentifier: "group.navlink")),
            "Created group was not visible in the Work group after saving"
        )
    }
}

@MainActor
final class EntryEditSmokeUITests: EntryEditUITestCase {
    func testEditSocialDiscordSavesNewValue() {
        unlockSuccessfully()

        openEntry(named: discordEntryTitle, inGroup: socialGroupName)
        editCurrentEntryTitle(to: editedDiscordTitle)

        XCTAssertTrue(app.navigationBars[editedDiscordTitle].waitForExistence(timeout: 5))
        tapBackButton()
        tapBackButton()
        openGroup(named: socialGroupName)
        XCTAssertTrue(
            revealElement(entry(named: editedDiscordTitle)),
            "Edited entry title was not visible in the Social group after saving"
        )
    }

    func testRevealedPasswordUpdatesAfterEditing() {
        let updatedPassword = "updated-visible-password"

        unlockSuccessfully()
        openEntry(named: discordEntryTitle, inGroup: socialGroupName)

        let revealButton = app.buttons["entry.password.reveal"]
        XCTAssertTrue(revealButton.waitForExistence(timeout: Self.ciElementTimeout))
        revealButton.tap()
        XCTAssertTrue(app.staticTexts["discordpass!@#"].waitForExistence(timeout: Self.ciElementTimeout))

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()

        let passwordField = app.textFields["entry-edit.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        replaceText(in: passwordField, with: updatedPassword)

        let saveButton = app.buttons["entry-edit.save"]
        saveButton.tap()
        XCTAssertTrue(waitForSaveCompletion(saveButton: saveButton, timeout: 10))

        XCTAssertTrue(
            app.staticTexts[updatedPassword].waitForExistence(timeout: Self.ciElementTimeout),
            "The already-revealed password did not refresh after the edit was saved"
        )
    }
}

@MainActor
final class EntryDeleteSmokeUITests: EntryEditUITestCase {
    func testDeleteSocialTwitterSoftDeleteMovesToRecycleBin() {
        unlockSuccessfully()

        openGroup(named: socialGroupName)
        let twitterEntry = entry(named: twitterEntryTitle)
        XCTAssertTrue(revealElement(twitterEntry), "Twitter entry was not visible in Social")
        twitterEntry.swipeLeft()

        let deleteButton = app.buttons["entry-row.delete-swipe"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()
        app.alerts.buttons["Delete"].tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(entry(named: twitterEntryTitle).exists)

        tapBackButton()
        openGroup(named: recycleBinGroupName)
        XCTAssertTrue(
            revealElement(entry(named: twitterEntryTitle)),
            "Twitter entry was not moved into the recycle bin"
        )
    }

    func testContextMenuDeleteSocialDiscordSoftDeleteMovesToRecycleBin() {
        unlockSuccessfully()

        openGroup(named: socialGroupName)
        let deleteButton = revealContextDeleteButton(
            rowNamed: discordEntryTitle,
            identifier: "entry-row.delete-context",
            preferredIdentifier: "entry.navlink"
        )
        deleteButton.tap()

        let alertDeleteButton = app.alerts.buttons["Delete"]
        XCTAssertTrue(alertDeleteButton.waitForExistence(timeout: 5))
        alertDeleteButton.tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(entry(named: discordEntryTitle).exists)

        tapBackButton()
        openGroup(named: recycleBinGroupName)
        XCTAssertTrue(
            revealElement(entry(named: discordEntryTitle)),
            "Discord entry was not moved into the recycle bin"
        )
    }

    func testDeleteWorkGroupSoftDeleteMovesToRecycleBin() {
        unlockSuccessfully()

        let workGroup = group(named: workGroupName)
        XCTAssertTrue(revealElement(workGroup), "Work group was not visible")
        workGroup.swipeLeft()

        let deleteButton = app.buttons["group-row.delete-swipe"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let alert = app.alerts["Delete Group?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let confirmationText = alert.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                workGroupName,
                "3 entries",
                "1 nested group"
            )
        ).firstMatch
        XCTAssertTrue(
            confirmationText.waitForExistence(timeout: 2),
            "Group delete confirmation did not include the group name and subtree counts"
        )
        alert.buttons["Delete"].tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(group(named: workGroupName).exists)

        openGroup(named: recycleBinGroupName)
        XCTAssertTrue(
            revealElement(group(named: workGroupName)),
            "Work group was not moved into the recycle bin"
        )
    }

    func testContextMenuDeleteEmptyGroupSoftDeleteMovesToRecycleBin() {
        unlockSuccessfully()

        let deleteButton = revealContextDeleteButton(
            rowNamed: "Empty",
            identifier: "group-row.delete-context",
            preferredIdentifier: "group.navlink"
        )
        deleteButton.tap()

        let alert = app.alerts["Delete Group?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(group(named: "Empty").exists)

        openGroup(named: recycleBinGroupName)
        XCTAssertTrue(
            revealElement(group(named: "Empty")),
            "Empty group was not moved into the recycle bin"
        )
    }

    func testDeleteGroupInsideRecycleBinDeletesPermanently() {
        unlockSuccessfully()

        createRecycleBinByDeletingEmptyGroup()

        openGroup(named: recycleBinGroupName)
        let recycledEmptyGroup = group(named: "Empty")
        XCTAssertTrue(revealElement(recycledEmptyGroup), "Recycled Empty group was not visible")

        let deleteButton = revealSwipeDeleteButton(on: recycledEmptyGroup, identifier: "group-row.delete-swipe")
        deleteButton.tap()

        let alert = app.alerts["Delete Permanently?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete Permanently"].tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(group(named: "Empty").exists)
    }

    func testRecycleBinGroupHasNoDeleteSwipeAction() {
        unlockSuccessfully()

        createRecycleBinByDeletingEmptyGroup()

        let recycleBinGroup = group(named: recycleBinGroupName)
        XCTAssertTrue(revealElement(recycleBinGroup), "Recycle Bin group was not visible")
        recycleBinGroup.swipeLeft()
        XCTAssertFalse(app.buttons["group-row.delete-swipe"].waitForExistence(timeout: 2))
    }

    func testRecycleBinGroupHasNoDeleteContextAction() {
        unlockSuccessfully()

        createRecycleBinByDeletingEmptyGroup()

        let recycleBinGroup = group(named: recycleBinGroupName)
        XCTAssertTrue(revealElement(recycleBinGroup), "Recycle Bin group was not visible")
        recycleBinGroup.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["group-row.delete-context"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["group-row.delete-permanent"].exists)
    }

    private func createRecycleBinByDeletingEmptyGroup(file: StaticString = #filePath, line: UInt = #line) {
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

@MainActor
final class EntryEditEdgeUITests: EntryEditUITestCase {
    func testCreateGroupDuplicateShowsErrorAndDoesNotAddSecondGroup() {
        unlockSuccessfully()

        openGroup(named: workGroupName)
        createGroup(named: "UI Duplicate Group")
        waitForAutosaveAttempt()

        createGroup(named: "ui duplicate group", expectSuccess: false)

        let duplicateAlert = app.alerts["Couldn’t Create Group"]
        XCTAssertTrue(duplicateAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(duplicateAlert.staticTexts["\"ui duplicate group\" already exists in this group."].exists)
        duplicateAlert.buttons["OK"].tap()

        app.buttons["group-create.cancel"].tap()

        let createdGroups = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'group.navlink' AND label CONTAINS[c] %@", "UI Duplicate Group")
        ).allElementsBoundByIndex.filter(\.exists)
        XCTAssertEqual(createdGroups.count, 1)
    }

    func testDiscardUnsavedEditPromptsConfirmation() {
        unlockSuccessfully()

        openGroup(named: workGroupName)
        tapAddEntry()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: "Discard Me")

        let cancelButton = app.buttons["entry-edit.cancel"]
        cancelButton.tap()

        let discardAlert = app.alerts["Discard changes?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Keep Editing"].tap()

        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Discard Changes"].tap()

        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(waitForUnsavedIndicator(isPresent: true, timeout: 1))
        XCTAssertFalse(revealElement(entry(named: "Discard Me")))
    }

    func testPasswordGeneratorProducesNonEmptyPassword() {
        unlockSuccessfully()

        openGroup(named: workGroupName)
        tapAddEntry()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: generatedPasswordEntryTitle)

        let generatorButton = app.buttons["entry-edit.password-generator-button"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 5))
        generatorButton.tap()

        // The generator sheet is a tall Form; on compact devices (iPhone SE)
        // the Regenerate / Use Password buttons sit below the fold and aren't
        // in the accessibility tree until scrolled into view.
        let regenerateButton = app.buttons["password-generator.regenerate"]
        XCTAssertTrue(revealElement(regenerateButton), "Regenerate button was not reachable")
        regenerateButton.tap()

        let useButton = app.buttons["password-generator.use"]
        XCTAssertTrue(revealElement(useButton), "Use Password button was not reachable")
        useButton.tap()

        let passwordField = app.textFields["entry-edit.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        let passwordValue = passwordField.value as? String
        XCTAssertNotNil(passwordValue)
        XCTAssertFalse(passwordValue?.isEmpty ?? true)

        app.buttons["entry-edit.save"].tap()
        XCTAssertTrue(waitForElementToDisappear(app.buttons["entry-edit.save"], timeout: 10))

        lockAndReopenVault()
        openEntry(named: generatedPasswordEntryTitle, inGroup: workGroupName)
        XCTAssertTrue(app.buttons["entry.password.reveal"].waitForExistence(timeout: 5))
    }

    func testSaveConflictOffersReloadAndConflictCopy() {
        unlockSuccessfully()

        openEntry(named: discordEntryTitle, inGroup: socialGroupName)
        editCurrentEntryTitle(to: firstConflictDiscordTitle)
        XCTAssertTrue(waitForSaveConflictAlert())

        let reloadButton = app.buttons["save-conflict.reload"].firstMatch
        let saveAsCopyButton = app.buttons["save-conflict.save-as-copy"].firstMatch
        let cancelButton = app.buttons["save-conflict.cancel"].firstMatch
        XCTAssertTrue(reloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(saveAsCopyButton.exists)
        XCTAssertTrue(cancelButton.exists)
        reloadButton.tap()

        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 10))
        XCTAssertFalse(waitForUnsavedIndicator(isPresent: true, timeout: 2))

        openEntry(named: discordEntryTitle, inGroup: socialGroupName)
        editCurrentEntryTitle(to: secondConflictDiscordTitle)
        XCTAssertTrue(waitForSaveConflictAlert())

        XCTAssertTrue(app.buttons["save-conflict.save-as-copy"].firstMatch.waitForExistence(timeout: 5))
        let saveAsCopyConfirmationButton = app.buttons["save-conflict.save-as-copy"].firstMatch
        saveAsCopyConfirmationButton.tap()
        XCTAssertTrue(waitForElementToDisappear(saveAsCopyConfirmationButton, timeout: 10))
        XCTAssertFalse(waitForUnsavedIndicator(isPresent: true, timeout: 10))
    }

    func testReadOnlyDatabaseHidesEditAffordancesShowsIndicator() {
        unlockSuccessfully()

        let indicator = readOnlyIndicator()
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "Read-only indicator did not appear")
        XCTAssertFalse(app.buttons["entry-list.add-entry"].exists)

        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        let entryLink = app.descendants(matching: .any).matching(identifier: "entry.navlink").firstMatch
        XCTAssertTrue(
            groupLink.waitForExistence(timeout: 10) || entryLink.waitForExistence(timeout: 10),
            "Read-only database never showed any group or entry navigation links"
        )

        openEntry(named: "GitHub", inGroup: workGroupName)
        XCTAssertFalse(app.buttons["entry-detail.edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(indicator.waitForExistence(timeout: 2), "Read-only indicator missing on entry detail")
    }

    func testReadOnlyDatabaseDisabledOnNextLaunchRestoresEditAffordances() {
        unlockSuccessfully()

        XCTAssertTrue(readOnlyIndicator().waitForExistence(timeout: 5), "Read-only indicator did not appear")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "UI_TEST_DATABASE_READ_ONLY")
        app.launch()
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 30)
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list did not appear after relaunching without read-only mode")
        unlockSuccessfully()

        XCTAssertTrue(
            waitForElementToDisappear(readOnlyIndicator(), timeout: 5),
            "Read-only indicator should disappear after turning editing back on"
        )
        XCTAssertTrue(
            app.buttons["entry-list.add-entry"].waitForExistence(timeout: 5),
            "Add entry button should return after turning read-only off"
        )
    }
}
