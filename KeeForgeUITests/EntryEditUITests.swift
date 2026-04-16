import XCTest

@MainActor
final class EntryEditUITests: KeeForgeUITestCase {
    private let createdEntryTitle = "AAA UI Created Entry"
    private let generatedPasswordEntryTitle = "AAB Generated Password Entry"
    private let editedDiscordTitle = "Discord UI Edited"
    private let firstConflictDiscordTitle = "Discord Conflict Pass 1"
    private let secondConflictDiscordTitle = "Discord Conflict Pass 2"

    override func configureLaunch(app: XCUIApplication) throws {
        if name.contains("testSaveConflictOffersReloadAndConflictCopy") {
            app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "2"
        }
        if name.contains("testReadOnlyDatabase") {
            app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = "1"
        }
    }

    func testCreateEntrySavesAndShowsInList() {
        unlockSuccessfully()

        createEntry(
            title: createdEntryTitle,
            username: "ui-created-user",
            password: "created-password-123"
        )

        openEntry(named: createdEntryTitle)
        XCTAssertTrue(app.staticTexts["ui-created-user"].waitForExistence(timeout: 5))
    }

    func testEditEntrySavesNewValue() {
        unlockSuccessfully()

        openGroup(named: "Social")
        openEntry(named: "Discord")

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: editedDiscordTitle)
        app.buttons["entry-edit.save"].tap()
        XCTAssertTrue(waitForElementToDisappear(app.buttons["entry-edit.save"], timeout: 10))
        tapBackButton()
        tapBackButton()
        lockAndReopenVault()

        openGroup(named: "Social")
        openEntry(named: editedDiscordTitle)
        XCTAssertTrue(app.navigationBars[editedDiscordTitle].waitForExistence(timeout: 5))
    }

    func testDeleteEntrySoftDeleteMovesToRecycleBin() {
        unlockSuccessfully()

        openGroup(named: "Social")
        let twitterEntry = entry(named: "Twitter")
        XCTAssertTrue(revealElement(twitterEntry), "Twitter entry was not visible in Social")
        twitterEntry.swipeLeft()

        let deleteButton = app.buttons["entry-row.delete-swipe"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()
        app.alerts.buttons["Delete"].tap()
        waitForAutosaveAttempt()

        XCTAssertFalse(entry(named: "Twitter").exists)
        lockAndReopenVault()

        openGroup(named: "Recycle Bin")
        XCTAssertTrue(revealElement(entry(named: "Twitter")), "Twitter entry was not moved into the recycle bin")
    }

    func testDiscardUnsavedEditPromptsConfirmation() {
        unlockSuccessfully()

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

        tapAddEntry()

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: generatedPasswordEntryTitle)

        let generatorButton = app.buttons["entry-edit.password-generator-button"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 5))
        generatorButton.tap()

        let regenerateButton = app.buttons["password-generator.regenerate"]
        XCTAssertTrue(regenerateButton.waitForExistence(timeout: 5))
        regenerateButton.tap()

        let useButton = app.buttons["password-generator.use"]
        XCTAssertTrue(useButton.waitForExistence(timeout: 5))
        useButton.tap()

        let passwordField = app.textFields["entry-edit.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        let passwordValue = passwordField.value as? String
        XCTAssertNotNil(passwordValue)
        XCTAssertFalse(passwordValue?.isEmpty ?? true)

        app.buttons["entry-edit.save"].tap()
        XCTAssertTrue(waitForElementToDisappear(app.buttons["entry-edit.save"], timeout: 10))
        lockAndReopenVault()

        openEntry(named: generatedPasswordEntryTitle)
        XCTAssertTrue(app.buttons["entry.password.reveal"].waitForExistence(timeout: 5))
    }

    func testSaveConflictOffersReloadAndConflictCopy() {
        unlockSuccessfully()

        XCTAssertTrue(openAnyEntry(), "Could not open an entry for save conflict testing")
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

        XCTAssertTrue(openAnyEntry(), "Could not reopen an entry after reloading the conflicted database")
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

        let indicator = app.descendants(matching: .any).matching(identifier: "database.read-only-indicator").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "Read-only indicator did not appear")
        XCTAssertFalse(app.buttons["entry-list.add-entry"].exists)

        let groupLink = app.descendants(matching: .any).matching(identifier: "group.navlink").firstMatch
        let entryLink = app.descendants(matching: .any).matching(identifier: "entry.navlink").firstMatch
        XCTAssertTrue(
            groupLink.waitForExistence(timeout: 10) || entryLink.waitForExistence(timeout: 10),
            "Read-only database never showed any group or entry navigation links"
        )
        XCTAssertTrue(openAnyEntry(), "Could not open an entry in the read-only database")
        XCTAssertFalse(app.buttons["entry-detail.edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(indicator.waitForExistence(timeout: 2), "Read-only indicator missing on entry detail")
    }

    func testReadOnlyDatabaseDisabledOnNextLaunchRestoresEditAffordances() {
        unlockSuccessfully()

        let indicator = app.descendants(matching: .any).matching(identifier: "database.read-only-indicator").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "Read-only indicator did not appear")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "UI_TEST_DATABASE_READ_ONLY")
        app.launch()
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 30)
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list did not appear after relaunching without read-only mode")
        unlockSuccessfully()

        XCTAssertTrue(waitForElementToDisappear(indicator, timeout: 5), "Read-only indicator should disappear after turning editing back on")
        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 5), "Add entry button should return after turning read-only off")
    }

    private func tapAddEntry(file: StaticString = #filePath, line: UInt = #line) {
        let addButton = app.buttons["entry-list.add-entry"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add entry button was not visible", file: file, line: line)
        addButton.tap()
    }

    private func createEntry(
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

    private func editCurrentEntryTitle(to title: String, file: StaticString = #filePath, line: UInt = #line) {
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

    private func lockAndReopenVault(file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible", file: file, line: line)
        lockButton.tap()
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list did not reappear after locking", file: file, line: line)
        unlockSuccessfully(file: file, line: line)
    }

    private func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let group = firstRowMatching(name: name, preferredIdentifier: "group.navlink")
        XCTAssertTrue(revealElement(group), "Group '\(name)' was not visible", file: file, line: line)
        tapElement(group)
    }

    private func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = firstRowMatching(name: name, preferredIdentifier: "entry.navlink")
        XCTAssertTrue(revealElement(entry), "Entry '\(name)' was not visible", file: file, line: line)
        tapElement(entry)
    }

    private func entry(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'entry.navlink' AND label CONTAINS[c] %@", name)
        ).firstMatch
    }

    private func waitForUnsavedIndicator(
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
    private func waitForSaveCompletion(
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

    private func waitForSaveConflictAlert(timeout: TimeInterval = 10) -> Bool {
        app.alerts["Save Conflict"].waitForExistence(timeout: timeout)
    }

    private func waitForElementToDisappear(
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

    private func waitForAutosaveAttempt(timeout: TimeInterval = 2) {
        RunLoop.current.run(until: Date().addingTimeInterval(timeout))
    }

    private func tapBackButton(file: StaticString = #filePath, line: UInt = #line) {
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

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func firstRowMatching(name: String, preferredIdentifier: String) -> XCUIElement {
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
