import XCTest

@MainActor
class DatabaseCreationUITestCase: EntryEditUITestCase {
    private let createdDatabasePassword = "correct horse ui staple"

    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        []
    }

    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        app.launchEnvironment["UI_TEST_DATABASE_CREATION_EXPORT_PATH"] = "\(name)-created.kdbx"
    }

    func requireCompactLayout(file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window did not appear", file: file, line: line)
        guard window.frame.width < 700 else {
            throw XCTSkip("Requires a compact-width simulator destination")
        }
    }

    /// Creates and opens a local database through the New Database form.
    func createLocalDatabase(
        named databaseName: String,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let createButton = app.buttons["database.empty.create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10), "Empty-state create button was not visible", file: file, line: line)
        tapElement(createButton)

        let nameField = app.textFields["database-create.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Database name field was not visible", file: file, line: line)

        let passwordField = app.secureTextFields["database-create.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Master password field was not visible", file: file, line: line)
        let revealedPasswordField = revealPasswordTextField(
            in: passwordField,
            revealingWith: app.buttons["database-create.password-visibility-button"]
        )

        let confirmPasswordField = app.secureTextFields["database-create.confirm-password-field"]
        XCTAssertTrue(confirmPasswordField.waitForExistence(timeout: 5), "Confirm password field was not visible", file: file, line: line)
        let revealedConfirmPasswordField = revealPasswordTextField(
            in: confirmPasswordField,
            revealingWith: app.buttons["database-create.confirm-password-visibility-button"]
        )

        replaceText(in: nameField, with: databaseName)
        dismissKeyboardAfterPasswordFixtureEntry()
        replaceVisiblePasswordFixtureText(in: revealedPasswordField, with: password)
        dismissKeyboardAfterPasswordFixtureEntry()
        replaceVisiblePasswordFixtureText(in: revealedConfirmPasswordField, with: password)

        let formCreateButton = app.buttons["database-create.create-button"]
        XCTAssertTrue(formCreateButton.waitForExistence(timeout: 5), "Create confirmation button was not visible", file: file, line: line)
        tapElement(formCreateButton)

        XCTAssertTrue(
            app.buttons["lock.button"].waitForExistence(timeout: 30),
            "Created database did not open into an unlocked vault",
            file: file,
            line: line
        )
    }

    func createLocalDatabaseAndVerifyHappyPath(
        named databaseName: String,
        entryTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let createButton = app.buttons["database.empty.create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10), "Empty-state create button was not visible", file: file, line: line)
        tapElement(createButton)

        let nameField = app.textFields["database-create.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Database name field was not visible", file: file, line: line)

        let passwordField = app.secureTextFields["database-create.password-field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Master password field was not visible", file: file, line: line)
        let revealedPasswordField = revealPasswordTextField(
            in: passwordField,
            revealingWith: app.buttons["database-create.password-visibility-button"]
        )

        let confirmPasswordField = app.secureTextFields["database-create.confirm-password-field"]
        XCTAssertTrue(confirmPasswordField.waitForExistence(timeout: 5), "Confirm password field was not visible", file: file, line: line)
        let revealedConfirmPasswordField = revealPasswordTextField(
            in: confirmPasswordField,
            revealingWith: app.buttons["database-create.confirm-password-visibility-button"]
        )

        replaceText(in: nameField, with: databaseName)
        dismissKeyboardAfterPasswordFixtureEntry()
        replaceVisiblePasswordFixtureText(in: revealedPasswordField, with: createdDatabasePassword)
        dismissKeyboardAfterPasswordFixtureEntry()
        replaceVisiblePasswordFixtureText(in: revealedConfirmPasswordField, with: createdDatabasePassword)

        let formCreateButton = app.buttons["database-create.create-button"]
        XCTAssertTrue(formCreateButton.waitForExistence(timeout: 5), "Create confirmation button was not visible", file: file, line: line)
        tapElement(formCreateButton)

        let formDismissed = formCreateButton.waitForNonExistence(timeout: 30)
        XCTAssertTrue(
            formDismissed,
            "Create form did not dismiss after submission",
            file: file,
            line: line
        )
        revealSidebarIfNeeded()

        XCTAssertTrue(
            app.buttons["lock.button"].waitForExistence(timeout: 30),
            "Created database did not open into an unlocked vault",
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.navigationBars[databaseName].waitForExistence(timeout: 5)
                || app.staticTexts[databaseName].waitForExistence(timeout: 5)
                || firstRowMatching(name: "Recycle Bin", preferredIdentifier: "group.navlink").waitForExistence(timeout: 5),
            "Created database vault screen was not visible",
            file: file,
            line: line
        )

        createEntry(
            title: entryTitle,
            username: "created-ui-user",
            password: "created-ui-secret",
            file: file,
            line: line
        )

        XCTAssertTrue(
            revealElement(entry(named: entryTitle)),
            "Created entry was not visible after saving",
            file: file,
            line: line
        )

        lockAndReopenCreatedDatabase(file: file, line: line)

        XCTAssertTrue(
            revealElement(entry(named: entryTitle)),
            "Created entry was not visible after locking and reopening the new database",
            file: file,
            line: line
        )
    }

    private func lockAndReopenCreatedDatabase(file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button was not visible", file: file, line: line)
        tapElement(lockButton)
        XCTAssertTrue(waitForLockedState(timeout: 10), "Locked state did not appear after locking", file: file, line: line)

        unlock(password: createdDatabasePassword)
        XCTAssertTrue(
            app.secureTextFields["unlock.password.field"].waitForNonExistence(timeout: 30),
            "Created database did not leave the unlock screen after re-entering its password",
            file: file,
            line: line
        )
        revealSidebarIfNeeded()
        waitForVaultToUnlock(file: file, line: line)
    }
}

@MainActor
final class DatabaseCreationCompactUITests: DatabaseCreationUITestCase {
    func testCreateLocalDatabaseHappyPathInCompactLayout() throws {
        try requireCompactLayout()
        createLocalDatabaseAndVerifyHappyPath(
            named: "Compact UI Created",
            entryTitle: "Compact Created Entry"
        )
    }
}

@MainActor
final class DatabaseCreationRegularWidthUITests: DatabaseCreationUITestCase {
    func testCreateLocalDatabaseHappyPathInRegularWidthLayout() throws {
        try requireRegularWidthLayout()
        revealSidebarIfNeeded()
        createLocalDatabaseAndVerifyHappyPath(
            named: "Regular UI Created",
            entryTitle: "Regular Created Entry"
        )
    }
}
