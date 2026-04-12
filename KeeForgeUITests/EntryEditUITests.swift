import XCTest

@MainActor
final class EntryEditUITests: KeeForgeUITestCase {
    private let createdEntryTitle = "AAA UI Created Entry"
    private let generatedPasswordEntryTitle = "AAB Generated Password Entry"
    private let dirtyLockEntryTitle = "AAC Dirty Lock Entry"
    private let editedDiscordTitle = "Discord UI Edited"
    private let firstConflictDiscordTitle = "Discord Conflict Pass 1"
    private let secondConflictDiscordTitle = "Discord Conflict Pass 2"

    override func configureLaunch(app: XCUIApplication) throws {
        if name.contains("testSaveConflictOffersReloadAndConflictCopy") {
            app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "2"
        }
        if name.contains("testLockWhileDirtyPromptsConfirmationThenLocks") {
            app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "1"
        }
    }

    func testCreateEntrySavesAndShowsInList() {
        unlockSuccessfully()

        createEntry(
            title: createdEntryTitle,
            username: "ui-created-user",
            password: "created-password-123"
        )
        lockAndReopenVault()

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

        app.buttons["entry-edit.save"].tap()
        XCTAssertTrue(waitForElementToDisappear(app.buttons["entry-edit.save"], timeout: 10))
        lockAndReopenVault()

        openEntry(named: generatedPasswordEntryTitle)
        XCTAssertTrue(app.buttons["entry.password.reveal"].waitForExistence(timeout: 5))
    }

    func testLockWhileDirtyPromptsConfirmationThenLocks() {
        unlockSuccessfully()

        createEntry(title: dirtyLockEntryTitle, username: nil, password: "dirty-lock-password")
        XCTAssertTrue(waitForUnsavedIndicator(isPresent: true))

        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5))
        lockButton.tap()

        let alert = app.alerts["Lock and discard unsaved changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Lock and Discard"].tap()

        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        unlockSuccessfully()
        XCTAssertFalse(revealElement(entry(named: dirtyLockEntryTitle)))
    }

    func testSaveConflictOffersReloadAndConflictCopy() {
        unlockSuccessfully()

        openGroup(named: "Social")
        openEntry(named: "Discord")
        editCurrentEntryTitle(to: firstConflictDiscordTitle)
        XCTAssertTrue(waitForSaveConflictAlert())

        let reloadButton = app.buttons["save-conflict.reload"]
        let saveAsCopyButton = app.buttons["save-conflict.save-as-copy"]
        let cancelButton = app.buttons["save-conflict.cancel"]
        XCTAssertTrue(reloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(saveAsCopyButton.exists)
        XCTAssertTrue(cancelButton.exists)
        reloadButton.tap()

        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 10))
        XCTAssertFalse(waitForUnsavedIndicator(isPresent: true, timeout: 2))

        openGroup(named: "Social")
        openEntry(named: "Discord")
        editCurrentEntryTitle(to: secondConflictDiscordTitle)
        XCTAssertTrue(waitForSaveConflictAlert())

        XCTAssertTrue(saveAsCopyButton.waitForExistence(timeout: 5))
        saveAsCopyButton.tap()
        XCTAssertFalse(waitForUnsavedIndicator(isPresent: true, timeout: 10))
        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 5))
    }

    func testReadOnlyDatabaseHidesEditAffordancesShowsRibbon() {
        setDatabaseReadOnly(true)
        unlockSuccessfully()

        XCTAssertTrue(app.otherElements["database.read-only-ribbon"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["entry-list.add-entry"].exists)

        openGroup(named: "Social")
        let discordEntry = entry(named: "Discord")
        XCTAssertTrue(revealElement(discordEntry), "Discord entry was not visible in Social")
        discordEntry.swipeLeft()
        XCTAssertFalse(app.buttons["entry-row.delete-swipe"].waitForExistence(timeout: 1))

        discordEntry.tap()
        XCTAssertFalse(app.buttons["entry-detail.edit"].exists)
        XCTAssertTrue(app.otherElements["database.read-only-ribbon"].exists)
    }

    func testReadOnlyDatabaseToggleOffRestoresEditAffordances() {
        setDatabaseReadOnly(true)
        setDatabaseReadOnly(false)
        unlockSuccessfully()

        XCTAssertFalse(app.otherElements["database.read-only-ribbon"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["entry-list.add-entry"].waitForExistence(timeout: 5))

        openGroup(named: "Social")
        let discordEntry = entry(named: "Discord")
        XCTAssertTrue(revealElement(discordEntry), "Discord entry was not visible in Social")
        discordEntry.swipeLeft()
        XCTAssertTrue(app.buttons["entry-row.delete-swipe"].waitForExistence(timeout: 2))
        discordEntry.tap()
        XCTAssertTrue(app.buttons["entry-detail.edit"].waitForExistence(timeout: 5))
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
            let passwordField = app.secureTextFields["entry-edit.password-field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field was not visible", file: file, line: line)
            replaceText(in: passwordField, with: password)
        }

        let saveButton = app.buttons["entry-edit.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Entry editor save button was not visible", file: file, line: line)
        saveButton.tap()
        XCTAssertTrue(waitForElementToDisappear(saveButton, timeout: 10), "Entry editor did not dismiss after autosave", file: file, line: line)
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
        XCTAssertTrue(waitForElementToDisappear(saveButton, timeout: 10), "Entry editor did not dismiss after autosave", file: file, line: line)
    }

    private func lockAndReopenVault(file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = app.buttons["lock.button"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible", file: file, line: line)
        lockButton.tap()
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list did not reappear after locking", file: file, line: line)
        unlockSuccessfully(file: file, line: line)
    }

    private func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let group = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'group.navlink' AND label CONTAINS[c] %@", name)
        ).firstMatch
        XCTAssertTrue(revealElement(group), "Group '\(name)' was not visible", file: file, line: line)
        group.tap()
    }

    private func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = self.entry(named: name)
        XCTAssertTrue(revealElement(entry), "Entry '\(name)' was not visible", file: file, line: line)
        entry.tap()
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
        let indicator = app.otherElements["database.unsaved-indicator"]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if indicator.exists == isPresent {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return indicator.exists == isPresent
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
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "Navigation bar was not visible", file: file, line: line)

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

        guard let backButton = navigationBar.buttons.allElementsBoundByIndex.first(where: {
            $0.exists
                && $0.isHittable
                && excludedIdentifiers.contains($0.identifier) == false
                && excludedLabels.contains($0.label) == false
        }) else {
            XCTFail("Back button was not found", file: file, line: line)
            return
        }

        backButton.tap()
    }

    private func setDatabaseReadOnly(
        _ isReadOnly: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons["database.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Database row was not visible", file: file, line: line)
        row.press(forDuration: 1.2)

        let detailsButton = app.buttons["Database Details"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5), "Database Details action was not visible", file: file, line: line)
        detailsButton.tap()

        let readOnlyToggle = app.switches["Read-only"].firstMatch
        XCTAssertTrue(readOnlyToggle.waitForExistence(timeout: 5), "Read-only toggle was not visible", file: file, line: line)
        if switchIsOn(readOnlyToggle) != isReadOnly {
            readOnlyToggle.tap()
        }

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button was not visible", file: file, line: line)
        closeButton.tap()
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database list did not return after closing details", file: file, line: line)
    }

    private func switchIsOn(_ toggle: XCUIElement) -> Bool {
        let rawValue = String(describing: toggle.value ?? "")
        return rawValue == "1" || rawValue.caseInsensitiveCompare("on") == .orderedSame
    }
}
