import XCTest

/// Opt-in layout-audit sweep for compact devices (iPhone SE, iPhone mini).
/// Walks the major screens and attaches a named screenshot of each so the
/// captures can be exported from the `.xcresult` and reviewed for layout
/// problems on small screens. Asserts only enough to keep the walk on rails.
///
/// Skipped unless the sweep is opted into, mirroring `AppStoreScreenshots`:
///
///     TEST_RUNNER_SMALL_SCREEN_SWEEP=1 xcodebuild test ... \
///         -only-testing:KeeForgeUITests/SmallScreenSweepCoreUITests
@MainActor
class SmallScreenSweepUITestCase: KeeForgeUITestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SMALL_SCREEN_SWEEP"] == "1" else {
            throw XCTSkip("Small-screen sweep runs only with SMALL_SCREEN_SWEEP=1")
        }
        try await super.setUp()
    }

    func snap(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapNavigationBack() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists && backButton.isHittable {
            backButton.tap()
            sleep(1)
        }
    }
}

@MainActor
final class SmallScreenSweepCoreUITests: SmallScreenSweepUITestCase {
    func test01_unlockVaultAndEntryFlow() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        snap("core-01-database-list")

        XCTAssertTrue(openDatabase(named: "test"))
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        replaceText(in: passwordField, with: "testpassword123")
        snap("core-02-unlock-keyboard-up")

        app.buttons["unlock.button"].tap()
        XCTAssertTrue(waitForVaultToUnlock())
        snap("core-03-group-list")

        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        let closeButton = app.buttons["database-details.close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        snap("core-04-database-details-top")
        app.swipeUp()
        snap("core-05-database-details-bottom")
        closeButton.tap()
        sleep(1)

        let socialGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Social") })
        XCTAssertNotNil(socialGroup)
        socialGroup?.tap()
        sleep(1)
        snap("core-06-entry-list")

        let twitterEntry = app.buttons.matching(identifier: "entry.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Twitter") })
        XCTAssertNotNil(twitterEntry)
        twitterEntry?.tap()
        sleep(1)

        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.waitForExistence(timeout: 3) && revealButton.isHittable {
            revealButton.tap()
        }
        snap("core-07-entry-detail-top")
        app.swipeUp()
        snap("core-08-entry-detail-bottom")

        let editButton = app.buttons["entry-detail.edit"]
        _ = revealElement(editButton, direction: .down)
        XCTAssertTrue(editButton.waitForExistence(timeout: Self.ciElementTimeout))
        editButton.tap()
        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("core-09-entry-edit-top")

        let generatorButton = app.buttons["entry-edit.password-generator-button"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 5))
        generatorButton.tap()
        let lengthSlider = app.sliders["password-generator.length-slider"]
        XCTAssertTrue(lengthSlider.waitForExistence(timeout: Self.ciElementTimeout))
        snap("core-11-password-generator")
        let useButton = app.buttons["password-generator.use"]
        XCTAssertTrue(revealElement(useButton), "Use Password button was not reachable")
        snap("core-12-password-generator-bottom")
        let generatorClose = app.buttons.matching(
            NSPredicate(format: "label == 'Close' OR label == 'Cancel'")
        ).firstMatch
        XCTAssertTrue(revealElement(generatorClose, direction: .down))
        generatorClose.tap()

        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: 5))
        app.swipeUp()
        snap("core-10-entry-edit-bottom")

        let editCancel = app.buttons["entry-edit.cancel"]
        _ = revealElement(editCancel, direction: .down)
        if editCancel.waitForExistence(timeout: 5) {
            editCancel.tap()
        }
    }

    func test02_searchAndSort() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "test"))
        unlockSuccessfully()

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("e")
            snap("core-13-search-results")
            let cancelButton = app.buttons["Cancel"]
            if cancelButton.exists && cancelButton.isHittable {
                cancelButton.tap()
            }
        }

        let sortMenu = app.buttons["sort.menu"]
        if sortMenu.waitForExistence(timeout: 5) {
            sortMenu.tap()
            snap("core-14-sort-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }

        let tagsRow = app.buttons["group-list.tags-row"]
        if tagsRow.waitForExistence(timeout: 5) && tagsRow.isHittable {
            tagsRow.tap()
            sleep(1)
            snap("core-15-empty-tag-list")
        }
    }

    private func openAppSettings() {
        let settingsButton = app.buttons["database.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.buttons["settings.security.link"].waitForExistence(timeout: Self.ciElementTimeout))
    }

    private func closeAppSettings() {
        // Pushed sub-screens carry no Done button; pop back to the sheet root
        // first, then dismiss. Filter nav-bar buttons on hittability — plain
        // index-0 matches the database list's nav bar behind the sheet.
        for _ in 0..<4 {
            let done = app.buttons["Done"].firstMatch
            if done.exists && done.isHittable {
                done.tap()
                break
            }
            let back = app.navigationBars.buttons.allElementsBoundByIndex
                .first(where: { $0.isHittable })
            guard let back else { break }
            back.tap()
            sleep(1)
        }
        _ = waitForDatabaseList(timeout: 10)
    }

    private func captureSettingsSubScreen(link: String, prefix: String, includeBottom: Bool) {
        openAppSettings()
        let linkButton = app.buttons[link]
        guard revealElement(linkButton), linkButton.isHittable else {
            XCTFail("Settings link \(link) was not reachable")
            return
        }
        linkButton.tap()
        sleep(1)
        snap("\(prefix)-top")
        if includeBottom {
            app.swipeUp()
            snap("\(prefix)-bottom")
        }
        closeAppSettings()
    }

    func test03_appSettings() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        openAppSettings()
        snap("settings-01-root")
        closeAppSettings()

        captureSettingsSubScreen(link: "settings.security.link", prefix: "settings-02-security", includeBottom: false)
        captureSettingsSubScreen(link: "settings.autofill.link", prefix: "settings-03-autofill", includeBottom: true)
        captureSettingsSubScreen(link: "settings.display.link", prefix: "settings-05-display", includeBottom: false)
        captureSettingsSubScreen(link: "settings.about.link", prefix: "settings-06-about", includeBottom: true)

        openAppSettings()
        let feedbackButton = app.buttons["settings.send-feedback"]
        if revealElement(feedbackButton), feedbackButton.isHittable {
            feedbackButton.tap()
            sleep(1)
            snap("settings-07-feedback-composer")
        }
    }

    func test05_groupEditAndEntryIconPicker() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "test"))
        unlockSuccessfully()

        let editAction = app.buttons["group-row.edit-context"]
        for _ in 0..<4 where editAction.exists == false {
            let row = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
                .first(where: { $0.label.contains("Social") && $0.isHittable })
            row?.press(forDuration: 1.2)
            if editAction.waitForExistence(timeout: 2) {
                break
            }
        }
        XCTAssertTrue(editAction.exists, "Edit Group context action never appeared")
        editAction.tap()
        XCTAssertTrue(app.textFields["group-edit.name-field"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("group-edit-01-form")
        let cancel = app.buttons["group-edit.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        let groupLink = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Social") })
        XCTAssertNotNil(groupLink)
        groupLink?.tap()
        let twitterEntry = app.buttons.matching(identifier: "entry.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Twitter") })
        XCTAssertNotNil(twitterEntry)
        twitterEntry?.tap()

        let iconButton = app.buttons["entry-detail.icon-button"]
        XCTAssertTrue(iconButton.waitForExistence(timeout: Self.ciElementTimeout))
        iconButton.tap()
        let pickerCancel = app.buttons["entry-icon-picker.cancel"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: Self.ciElementTimeout))
        snap("icon-picker-01-entry")
        pickerCancel.tap()
    }

    func test04_databaseCreation() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        let addButton = app.buttons["database.add.button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        sleep(1)
        snap("create-01-add-menu")

        let newDatabase = menuButton(identifier: "database.add.new", label: "Create New Database")
        XCTAssertTrue(newDatabase.waitForExistence(timeout: 5))
        newDatabase.tap()

        let nameField = app.textFields["database-create.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        snap("create-02-form-top")

        replaceText(in: nameField, with: "Sweep Vault")
        snap("create-03-form-keyboard-up")
        app.swipeUp()
        snap("create-04-form-bottom")
    }
}

@MainActor
final class SmallScreenSweepBannersUITests: SmallScreenSweepUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_WHATS_NEW"] = "1"
        app.launchEnvironment["UI_TEST_SHOW_AUTOFILL_TIP"] = "1"
    }

    func test01_whatsNewAndAutoFillTip() throws {
        let whatsNewTitle = app.staticTexts["whats-new.title"]
        if whatsNewTitle.waitForExistence(timeout: 10) {
            snap("banners-01-whats-new-top")
            app.swipeUp()
            snap("banners-02-whats-new-bottom")
            let done = app.buttons["whats-new.done"]
            _ = revealElement(done)
            if done.exists && done.isHittable {
                done.tap()
            }
        }

        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        _ = app.buttons["autofill-tip.enable"].waitForExistence(timeout: 5)
        snap("banners-03-database-list-autofill-tip")
    }
}

@MainActor
final class SmallScreenSweepTagsUITests: SmallScreenSweepUITestCase {
    override var databaseFixtureName: String { "tag-browser" }

    func test01_tagBrowser() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "tag-browser"))
        unlockSuccessfully()

        let tagsRow = app.buttons["group-list.tags-row"]
        XCTAssertTrue(tagsRow.waitForExistence(timeout: 5))
        tagsRow.tap()
        sleep(1)
        snap("tags-01-tag-list")

        let sharedTag = app.buttons["tag-list.row.shared"]
        XCTAssertTrue(sharedTag.waitForExistence(timeout: 5))
        sharedTag.tap()
        sleep(1)
        snap("tags-02-tag-entries")

        let entry = app.buttons.matching(identifier: "search.entry.navlink").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        sleep(1)
        snap("tags-03-entry-detail-chips")
    }
}

@MainActor
final class SmallScreenSweepHistoryUITests: SmallScreenSweepUITestCase {
    override var databaseFixtureName: String { "protected-custom-field" }

    func test01_protectedFieldAndHistory() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "protected-custom-field"))
        unlockSuccessfully()

        let secretsGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Secrets") })
        XCTAssertNotNil(secretsGroup)
        secretsGroup?.tap()
        sleep(1)

        let entry = app.buttons.matching(identifier: "entry.navlink").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        sleep(1)
        snap("history-01-entry-detail-protected-field")

        let historyRow = app.buttons["entry-detail.history"]
        guard revealElement(historyRow), historyRow.isHittable else { return }
        historyRow.tap()
        sleep(1)
        snap("history-02-history-list")

        let version = app.buttons["entry-history.version.0"]
        if version.waitForExistence(timeout: 5) {
            version.tap()
            sleep(1)
            snap("history-03-version-top")
            app.swipeUp()
            snap("history-04-version-bottom")
        }
    }
}
