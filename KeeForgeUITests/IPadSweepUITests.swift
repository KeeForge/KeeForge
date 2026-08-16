import XCTest

/// Opt-in layout-audit sweep for regular-width iPad layouts. Walks the major
/// screens of the split-view shell and attaches a named screenshot of each in
/// both orientations, so the captures can be exported from the `.xcresult`
/// and reviewed for layout problems. Asserts only enough to stay on rails.
///
/// Skipped unless opted into, mirroring `AppStoreScreenshots`:
///
///     TEST_RUNNER_IPAD_SWEEP=1 xcodebuild test ... \
///         -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' \
///         -only-testing:KeeForgeUITests/IPadSweepCoreUITests
///
/// `TEST_RUNNER_IPAD_SWEEP_ORIENTATION=landscape` starts landscape instead of
/// portrait; every `snap` also captures the other orientation unless the
/// caller opts out (context menus and keyboards do not survive a rotation).
@MainActor
class IPadSweepUITestCase: UnlockedDatabaseUITestCase {
    private var baseOrientation: UIDeviceOrientation = .portrait

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["IPAD_SWEEP"] == "1" else {
            throw XCTSkip("iPad sweep runs only with IPAD_SWEEP=1")
        }
        if ProcessInfo.processInfo.environment["IPAD_SWEEP_ORIENTATION"] == "landscape" {
            baseOrientation = .landscapeLeft
        }
        XCUIDevice.shared.orientation = baseOrientation
        try await super.setUp()
        try requireRegularWidthLayout()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private var otherOrientation: UIDeviceOrientation {
        baseOrientation == .portrait ? .landscapeLeft : .portrait
    }

    private func orientationTag(_ orientation: UIDeviceOrientation) -> String {
        orientation == .portrait ? "portrait" : "landscape"
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func snap(_ name: String, bothOrientations: Bool = true) {
        sleep(1)
        attachScreenshot(named: "\(name)-\(orientationTag(baseOrientation))")
        guard bothOrientations else { return }
        XCUIDevice.shared.orientation = otherOrientation
        sleep(2)
        attachScreenshot(named: "\(name)-\(orientationTag(otherOrientation))")
        XCUIDevice.shared.orientation = baseOrientation
        sleep(2)
    }

    /// Narrow iPads in portrait collapse the split view's sidebar behind a
    /// "Show Sidebar" toolbar button; reveal it so list-driven steps can run.
    func showSidebarIfHidden() {
        let show = app.buttons["Show Sidebar"].firstMatch
        if show.waitForExistence(timeout: 2) && show.isHittable {
            show.tap()
            sleep(1)
        }
    }

    override func waitForDatabaseList(timeout: TimeInterval = 10) -> Bool {
        if super.waitForDatabaseList(timeout: min(timeout, 3)) {
            return true
        }
        showSidebarIfHidden()
        return super.waitForDatabaseList(timeout: timeout)
    }

    func tapNavigationBack() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists && backButton.isHittable {
            backButton.tap()
            sleep(1)
        }
    }

    func dismissContextMenu() {
        // Tap the sidebar's title area, which is never covered by a row menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        sleep(1)
    }

    /// Long-presses `row` until `action` appears, then returns whether it did.
    @discardableResult
    func openContextMenu(on row: XCUIElement, revealing action: XCUIElement) -> Bool {
        for _ in 0..<4 where action.exists == false {
            guard row.exists else { break }
            row.press(forDuration: 1.2)
            if action.waitForExistence(timeout: 2) {
                break
            }
        }
        return action.exists
    }

    func openAppSettings() {
        let settingsButton = app.buttons["database.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.buttons["settings.security.link"].waitForExistence(timeout: Self.ciElementTimeout))
    }

    func closeAppSettings() {
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
}

@MainActor
final class IPadSweepCoreUITests: IPadSweepUITestCase {
    func test01_launchUnlockAndWorkspace() throws {
        snap("core-00-launch")
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        snap("core-01-database-list-placeholder")

        XCTAssertTrue(openDatabase(named: "test"))
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        snap("core-02-unlock")

        replaceText(in: passwordField, with: "wrong-password")
        snap("core-03-unlock-keyboard-up", bothOrientations: false)
        app.buttons["unlock.button"].tap()
        _ = app.staticTexts["unlock.error.label"].waitForExistence(timeout: 10)
        snap("core-04-unlock-error")

        replaceText(in: passwordField, with: "testpassword123")
        app.buttons["unlock.button"].tap()
        XCTAssertTrue(waitForVaultToUnlock())
        snap("core-05-workspace-root")
        showSidebarIfHidden()

        let addMenu = app.buttons["entry-list.add-entry"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()
        snap("core-06-add-menu", bothOrientations: false)
        let newEntry = menuButton(identifier: "New Entry", label: "New Entry")
        if newEntry.waitForExistence(timeout: 3) {
            newEntry.tap()
            XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: Self.ciElementTimeout))
            snap("core-07-new-entry-from-sidebar")
            let cancel = app.buttons["entry-edit.cancel"]
            if cancel.waitForExistence(timeout: 5) {
                cancel.tap()
            }
        }

        openGroup(named: "Empty")
        sleep(1)
        snap("core-07b-empty-group")
        tapNavigationBack()

        openGroup(named: "Social")
        sleep(1)
        snap("core-08-entry-list")

        openEntry(named: "Twitter")
        sleep(1)
        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.waitForExistence(timeout: 3) && revealButton.isHittable {
            revealButton.tap()
        }
        snap("core-09-entry-detail-top")
        if let container = scrollableContainer() {
            container.swipeUp()
        }
        snap("core-10-entry-detail-bottom")

        let editButton = app.buttons["entry-detail.edit"]
        _ = revealElement(editButton, direction: .down)
        XCTAssertTrue(editButton.waitForExistence(timeout: Self.ciElementTimeout))
        editButton.tap()
        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("core-11-entry-edit-top")

        let generatorButton = app.buttons["entry-edit.password-generator-button"]
        XCTAssertTrue(revealElement(generatorButton))
        generatorButton.tap()
        XCTAssertTrue(app.sliders["password-generator.length-slider"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("core-12-password-generator")
        let generatorClose = app.buttons.matching(
            NSPredicate(format: "label == 'Close' OR label == 'Cancel'")
        ).firstMatch
        XCTAssertTrue(revealElement(generatorClose, direction: .down))
        generatorClose.tap()

        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: 5))
        if let container = scrollableContainer() {
            container.swipeUp()
        }
        snap("core-13-entry-edit-bottom")

        let notesField = app.textViews["entry-edit.notes-field"]
        if revealElement(notesField), notesField.isHittable {
            notesField.tap()
            snap("core-14-entry-edit-keyboard-up", bothOrientations: false)
        }

        let editCancel = app.buttons["entry-edit.cancel"]
        _ = revealElement(editCancel, direction: .down)
        if editCancel.waitForExistence(timeout: 5) {
            editCancel.tap()
        }
        sleep(1)

        let iconButton = app.buttons["entry-detail.icon-button"]
        if revealElement(iconButton), iconButton.isHittable {
            iconButton.tap()
            let pickerCancel = app.buttons["entry-icon-picker.cancel"]
            if pickerCancel.waitForExistence(timeout: Self.ciElementTimeout) {
                snap("core-15-entry-icon-picker")
                pickerCancel.tap()
            }
        }

        let sortMenu = app.buttons["sort.menu"]
        if sortMenu.waitForExistence(timeout: 5) {
            sortMenu.tap()
            snap("core-16-sort-menu", bothOrientations: false)
            dismissContextMenu()
        }

        let lockButton = currentLockButton()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5))
        lockButton.tap()
        XCTAssertTrue(waitForLockedState())
        snap("core-17-locked-after-manual-lock")
    }

    func test02_databaseDetailsAndMasterKey() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "test"))
        unlockSuccessfully()
        showSidebarIfHidden()

        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        let closeButton = app.buttons["database-details.close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: Self.ciElementTimeout))
        snap("details-01-top")
        if let container = scrollableContainer() {
            container.swipeUp()
        }
        snap("details-02-bottom")

        let changeKey = app.buttons["database-details.change-master-key"]
        if revealElement(changeKey), changeKey.isHittable {
            changeKey.tap()
            let cancel = app.buttons["master-key.cancel"]
            if cancel.waitForExistence(timeout: Self.ciElementTimeout) {
                snap("details-03-change-master-key")
                cancel.tap()
            }
        }
        let appSettings = app.buttons["App Settings"].firstMatch
        if revealElement(appSettings), appSettings.isHittable {
            appSettings.tap()
            if app.buttons["settings.security.link"].waitForExistence(timeout: Self.ciElementTimeout) {
                snap("details-03b-app-settings-over-details")
                let done = app.buttons["Done"].firstMatch
                if done.exists && done.isHittable {
                    done.tap()
                }
            }
        }
        _ = revealElement(closeButton, direction: .down)
        if closeButton.exists {
            closeButton.tap()
        }
        sleep(1)

        let lock = currentLockButton()
        lock.tap()
        XCTAssertTrue(waitForLockedState())
        let editButton = app.buttons["database.edit.button"]
        if editButton.waitForExistence(timeout: 3) {
            editButton.tap()
            snap("details-04-database-list-edit-mode")
            editButton.tap()
        }
    }

    func test04_searchAndTags() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "test"))
        unlockSuccessfully()
        showSidebarIfHidden()

        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("e")
            snap("search-01-results-keyboard", bothOrientations: false)
            let result = app.buttons.matching(identifier: "search.entry.navlink").firstMatch
            if result.waitForExistence(timeout: 5) {
                result.tap()
                sleep(1)
                snap("search-02-result-selected")
            }
            searchField.tap()
            searchField.typeText("zzzzqqq")
            snap("search-03-no-results", bothOrientations: false)
            let cancelButton = app.buttons["Cancel"]
            if cancelButton.exists && cancelButton.isHittable {
                cancelButton.tap()
            }
        }

        let tagsRow = app.buttons["group-list.tags-row"]
        if tagsRow.waitForExistence(timeout: 5) && tagsRow.isHittable {
            tagsRow.tap()
            sleep(1)
            snap("search-04-empty-tag-list")
        }
    }

    func test05_appSettings() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        openAppSettings()
        snap("settings-01-root")
        if let container = scrollableContainer() {
            container.swipeUp()
        }
        snap("settings-02-root-bottom")
        closeAppSettings()

        captureSettingsSubScreen(link: "settings.security.link", prefix: "settings-03-security", includeBottom: true)
        captureSettingsSubScreen(link: "settings.autofill.link", prefix: "settings-04-autofill", includeBottom: true)
        captureSettingsSubScreen(link: "settings.display.link", prefix: "settings-05-display", includeBottom: false)
        captureSettingsSubScreen(link: "settings.about.link", prefix: "settings-06-about", includeBottom: true)

        openAppSettings()
        let aboutLink = app.buttons["settings.about.link"]
        if revealElement(aboutLink), aboutLink.isHittable {
            aboutLink.tap()
            let acknowledgments = app.buttons["Acknowledgments"].firstMatch
            if revealElement(acknowledgments), acknowledgments.isHittable {
                acknowledgments.tap()
                sleep(1)
                snap("settings-07-acknowledgments")
            }
        }
        closeAppSettings()

        openAppSettings()
        let feedbackButton = app.buttons["settings.send-feedback"]
        if revealElement(feedbackButton), feedbackButton.isHittable {
            feedbackButton.tap()
            sleep(1)
            snap("settings-08-feedback-composer")
            let message = app.textViews["feedback.message"]
            if message.waitForExistence(timeout: 3) && message.isHittable {
                message.tap()
                snap("settings-09-feedback-keyboard-up", bothOrientations: false)
            }
        }
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
        if includeBottom, let container = scrollableContainer() {
            container.swipeUp()
            snap("\(prefix)-bottom")
        }
        closeAppSettings()
    }

    func test06_databaseCreationAndAddFlows() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        let addButton = app.buttons["database.add.button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        sleep(1)
        snap("create-01-add-menu", bothOrientations: false)

        let webdav = menuButton(identifier: "database.add.webdav", label: "WebDAV")
        if webdav.waitForExistence(timeout: 3) {
            webdav.tap()
            let browserCancel = app.buttons["cloud.browser.cancel.button"]
            if browserCancel.waitForExistence(timeout: Self.ciElementTimeout) {
                snap("create-02-cloud-browser-signed-out")
                let connect = app.buttons["cloud.browser.connect.button"]
                if connect.exists && connect.isHittable {
                    connect.tap()
                    let webdavCancel = app.buttons["webdav.connect.cancel"]
                    if webdavCancel.waitForExistence(timeout: Self.ciElementTimeout) {
                        snap("create-02b-webdav-connect-over-browser")
                        webdavCancel.tap()
                        sleep(1)
                    }
                }
                if browserCancel.exists {
                    browserCancel.tap()
                }
            }
            sleep(1)
            addButton.tap()
            sleep(1)
        }

        let newDatabase = menuButton(identifier: "database.add.new", label: "Create New Database")
        XCTAssertTrue(newDatabase.waitForExistence(timeout: 5))
        newDatabase.tap()

        let nameField = app.textFields["database-create.name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        snap("create-03-form-top")

        replaceText(in: nameField, with: "Sweep Vault")
        snap("create-04-form-keyboard-up", bothOrientations: false)
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
        }

        let advanced = app.buttons["database-create.advanced-disclosure"]
        if revealElement(advanced), advanced.isHittable {
            advanced.tap()
            sleep(1)
        }
        if let container = scrollableContainer() {
            container.swipeUp()
        }
        snap("create-05-form-bottom-advanced")
    }
}

@MainActor
final class IPadSweepBannersUITests: IPadSweepUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_SHOW_WHATS_NEW"] = "1"
        app.launchEnvironment["UI_TEST_SHOW_AUTOFILL_TIP"] = "1"
    }

    func test01_whatsNewAndAutoFillTip() throws {
        let whatsNewTitle = app.staticTexts["whats-new.title"]
        if whatsNewTitle.waitForExistence(timeout: 10) {
            snap("banners-01-whats-new-top")
            if let container = scrollableContainer() {
                container.swipeUp()
            }
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
final class IPadSweepTagsUITests: IPadSweepUITestCase {
    override var databaseFixtureName: String { "tag-browser" }

    func test01_tagBrowser() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "tag-browser"))
        unlockSuccessfully()
        showSidebarIfHidden()

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

        let editButton = app.buttons["entry-detail.edit"]
        if revealElement(editButton, direction: .down), editButton.isHittable {
            editButton.tap()
            let tagsField = app.textFields["entry-edit.tags-field"]
            if revealElement(tagsField) {
                snap("tags-04-entry-edit-tags")
            }
            let cancel = app.buttons["entry-edit.cancel"]
            _ = revealElement(cancel, direction: .down)
            if cancel.exists {
                cancel.tap()
            }
        }
    }
}

@MainActor
final class IPadSweepHistoryUITests: IPadSweepUITestCase {
    override var databaseFixtureName: String { "protected-custom-field" }

    func test01_protectedFieldAndHistory() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "protected-custom-field"))
        unlockSuccessfully()
        showSidebarIfHidden()

        openGroup(named: "Secrets")
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
            let restore = app.buttons["entry-history.restore"]
            if restore.waitForExistence(timeout: 3) && restore.isHittable {
                restore.tap()
                _ = app.buttons["entry-history.restore.confirm"].waitForExistence(timeout: 5)
                snap("history-04-restore-confirmation", bothOrientations: false)
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists && cancel.isHittable {
                    cancel.tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                }
            }
            if let container = scrollableContainer() {
                container.swipeUp()
            }
            snap("history-05-version-bottom")
        }
    }
}

@MainActor
final class IPadSweepAttachmentsUITests: IPadSweepUITestCase {
    override var databaseFixtureName: String { "attachments" }

    func test01_attachmentsAndPreview() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "attachments"))
        unlockSuccessfully()
        showSidebarIfHidden()

        openGroup(named: "Attachments")
        openEntry(named: "Multi Attachment Entry")
        sleep(1)
        let attachment = app.buttons["entry.attachment.0"]
        if revealElement(attachment) {
            snap("attachments-01-entry-detail")
            attachment.tap()
            sleep(2)
            snap("attachments-02-quicklook-preview")
        }
    }
}

@MainActor
final class IPadSweepKeyFileUITests: IPadSweepUITestCase {
    override var databaseFixtureName: String { "demo-keyfile" }
    override var keyFileFixtureName: String? { "demo-keyfile" }

    func test01_keyFileUnlock() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "demo-keyfile"))
        XCTAssertTrue(app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 10))
        _ = app.buttons["unlock.keyfile.row"].waitForExistence(timeout: 5)
        snap("keyfile-01-unlock-with-key-file")
    }
}

/// Context menus leave the app and SpringBoard reporting "never idle" for the
/// rest of the run (every later interaction then waits out a 60s timeout), so
/// the long-press flows live in the class that sorts last.
@MainActor
final class IPadSweepZzContextMenusUITests: IPadSweepUITestCase {
    func test01_databaseRowContextMenu() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        let row = databaseRow(containing: "test")
        let detailsAction = app.buttons["database-row.details"]
        XCTAssertTrue(openContextMenu(on: row, revealing: detailsAction))
        snap("context-00-database-row-menu", bothOrientations: false)
        // The screenshot's idle wait can outlive the menu; reopen if it went away.
        XCTAssertTrue(openContextMenu(on: databaseRow(containing: "test"), revealing: detailsAction))
        detailsAction.tap()
        XCTAssertTrue(app.buttons["database-details.close"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("context-00b-details-from-list")
        closeDatabaseDetails()
    }

    func test02_groupAndEntryContextFlows() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10))
        XCTAssertTrue(openDatabase(named: "test"))
        unlockSuccessfully()
        showSidebarIfHidden()

        let socialRow = groupRow(named: "Social")
        XCTAssertTrue(revealElement(socialRow))
        let editAction = app.buttons["group-row.edit-context"]
        XCTAssertTrue(openContextMenu(on: socialRow, revealing: editAction), "Group context menu never appeared")
        snap("context-01-group-menu", bothOrientations: false)
        editAction.tap()
        XCTAssertTrue(app.textFields["group-edit.name-field"].waitForExistence(timeout: Self.ciElementTimeout))
        snap("context-02-group-edit")
        let groupIcon = app.buttons["group-edit.icon-button"]
        if revealElement(groupIcon), groupIcon.isHittable {
            groupIcon.tap()
            sleep(1)
            snap("context-03-group-icon-picker")
            let pickerCancel = app.buttons.matching(
                NSPredicate(format: "label == 'Cancel' OR label == 'Close'")
            ).firstMatch
            if pickerCancel.waitForExistence(timeout: 3) && pickerCancel.isHittable {
                pickerCancel.tap()
            }
        }
        let groupCancel = app.buttons["group-edit.cancel"]
        _ = revealElement(groupCancel, direction: .down)
        XCTAssertTrue(groupCancel.waitForExistence(timeout: 5))
        groupCancel.tap()
        sleep(1)

        let moveAction = app.buttons["group-row.move-context"]
        if openContextMenu(on: groupRow(named: "Social"), revealing: moveAction) {
            moveAction.tap()
            let moveCancel = app.buttons["move-picker.cancel"]
            if moveCancel.waitForExistence(timeout: Self.ciElementTimeout) {
                snap("context-04-move-group-picker")
                moveCancel.tap()
            }
        }

        addMenuNewGroupSheet()

        openGroup(named: "Social")
        let twitter = entryRow(named: "Twitter")
        XCTAssertTrue(revealElement(twitter))
        let entryMove = app.buttons["entry-row.move-context"]
        if openContextMenu(on: twitter, revealing: entryMove) {
            snap("context-06-entry-menu", bothOrientations: false)
            entryMove.tap()
            let moveCancel = app.buttons["move-picker.cancel"]
            if moveCancel.waitForExistence(timeout: Self.ciElementTimeout) {
                snap("context-07-move-entry-picker")
                moveCancel.tap()
            }
        }

        // Swipe actions on an entry row.
        let twitterAgain = entryRow(named: "Twitter")
        if twitterAgain.exists {
            twitterAgain.swipeLeft()
            snap("context-08-entry-swipe-actions", bothOrientations: false)
            twitterAgain.swipeRight()
        }
    }

    private func addMenuNewGroupSheet() {
        let addMenu = app.buttons["entry-list.add-entry"]
        guard addMenu.waitForExistence(timeout: 5) else { return }
        addMenu.tap()
        let newGroup = menuButton(identifier: "New Group", label: "New Group")
        guard newGroup.waitForExistence(timeout: 3) else {
            dismissContextMenu()
            return
        }
        newGroup.tap()
        let cancel = app.buttons["group-create.cancel"]
        if cancel.waitForExistence(timeout: Self.ciElementTimeout) {
            snap("context-05-new-group-sheet", bothOrientations: false)
            cancel.tap()
        }
    }
}
