import XCTest

/// Captures the full App Store screenshot walkthrough against the `demo`
/// fixture. Runs only opt-in — skipped by default so it does not add its
/// ~15+ s of hard `sleep()`-driven walkthrough (largely duplicating existing
/// smoke assertions) to every full `KeeForgeUITests` invocation, including
/// both RC release gates. Mirrors the `SCREENSHOT_AUDIT=1` gate
/// `KeeForgeMacUITests/MacScreenshotAuditUITests` already uses.
///
///     TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test ... \
///         -only-testing:KeeForgeUITests/AppStoreScreenshots
///
/// `TEST_RUNNER_APPSTORE_SCREENSHOTS` must be a real environment variable set
/// on the `xcodebuild` process itself (Xcode strips the `TEST_RUNNER_` prefix
/// and forwards it into the test runner's environment) — passing it as a
/// trailing bare `KEY=value` argument does not work; verified empirically,
/// that form is silently ignored and the test skips as if unset.
///
/// `ci_scripts/make_appstore_screenshots.py --capture` runs this once per
/// shipped locale (`-testLanguage`/`-testRegion`), exports each run into
/// `build/screenshots/<locale>/`, and composites the captioned listings.
@MainActor
final class AppStoreScreenshots: KeeForgeUITestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["APPSTORE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("App Store screenshot capture runs only with APPSTORE_SCREENSHOTS=1")
        }
        try await super.setUp()
        executionTimeAllowance = 600
    }

    private enum ScreenshotName: String {
        case databaseList = "01-database-list"
        case unlockScreen = "02-unlock-screen"
        case vaultGroups = "03-vault-groups"
        case databaseSettings = "04-database-settings"
        case entryList = "05-entry-list"
        case entryDetail = "06-entry-detail"
        case entryPasskey = "06b-entry-passkey"
        case entryEdit = "07-entry-edit"
        case search = "08-search"
    }

    private struct CloudAccountPayload: Encodable {
        let id: String
        let displayName: String
        let provider: String
    }

    private struct CloudFilePayload: Encodable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let modifiedDate: Date?
        let size: Int64?
    }

    private struct CloudDatabasePayload: Encodable {
        let provider: String
        let accountId: String
        let file: CloudFilePayload
    }

    private struct DropboxDirectoryPayload: Encodable {
        let path: String?
        let files: [CloudFilePayload]
    }

    private struct DropboxProviderPayload: Encodable {
        let accounts: [CloudAccountPayload]
        let directories: [DropboxDirectoryPayload]
        let fileContentsByID: [String: String]
        let contentHashByFileID: [String: String]
        let revByFileID: [String: String]
        let authenticateError: String?
        let listError: String?
        let metadataError: String?
        let downloadError: String?
        let uploadError: String?
    }

    private struct WebDAVDirectoryPayload: Encodable {
        let path: String?
        let files: [CloudFilePayload]
    }

    private struct WebDAVProviderPayload: Encodable {
        let accounts: [CloudAccountPayload]
        let directories: [WebDAVDirectoryPayload]
        let fileContentsByID: [String: String]
        let contentHashByFileID: [String: String]
        let revByFileID: [String: String]?
        let connectError: String?
        let authenticateError: String?
        let listError: String?
        let metadataError: String?
        let downloadError: String?
        let uploadError: String?
    }

    private static let uiTestCloudDatabasesEnv = "UI_TEST_CLOUD_DATABASES_JSON"
    private static let uiTestCloudAccountsEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let uiTestDropboxPayloadEnv = "UI_TEST_DROPBOX_PAYLOAD_JSON"
    private static let uiTestWebDAVPayloadEnv = "UI_TEST_WEBDAV_PAYLOAD_JSON"

    private let demoPassword = "demo"

    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "demo", injectedFilename: "Personal.kdbx"),
            DatabaseFixture(resourceName: "demo", injectedFilename: "Work.kdbx"),
        ]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchEnvironment["UI_TEST_HIDE_SEARCH_RESULTS_COUNT"] = "1"
        let fixtureData = try fixtureData(resourceName: "demo", resourceExtension: "kdbx")
        let fixtureBase64 = fixtureData.base64EncodedString()

        let account = CloudAccountPayload(
            id: "acct-1",
            displayName: "alex@example.com",
            provider: "dropbox"
        )
        let webDAVAccount = CloudAccountPayload(
            id: "webdav-family",
            displayName: "family@webdav.example.com",
            provider: "webdav"
        )
        let oneDriveAccount = CloudAccountPayload(
            id: "onedrive-backup",
            displayName: "taylor@outlook.com",
            provider: "onedrive"
        )
        let cloudFile = CloudFilePayload(
            id: "/Vaults/shared-vault.kdbx",
            name: "Shared Vault.kdbx",
            path: "/Vaults/shared-vault.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 1_712_345_678),
            size: Int64(fixtureData.count)
        )
        let webDAVFile = CloudFilePayload(
            id: "/Family/Family WebDAV.kdbx",
            name: "Family WebDAV.kdbx",
            path: "/Family/Family WebDAV.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 1_712_432_100),
            size: Int64(fixtureData.count)
        )
        let oneDriveFile = CloudFilePayload(
            id: "/drive/root:/KeeForge/OneDrive Backup.kdbx",
            name: "OneDrive Backup.kdbx",
            path: "/KeeForge/OneDrive Backup.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 1_712_500_400),
            size: Int64(fixtureData.count)
        )

        app.launchEnvironment[Self.uiTestCloudAccountsEnv] = try encode([account, webDAVAccount, oneDriveAccount])
        app.launchEnvironment[Self.uiTestCloudDatabasesEnv] = try encode([
            CloudDatabasePayload(
                provider: "dropbox",
                accountId: account.id,
                file: cloudFile
            ),
            CloudDatabasePayload(
                provider: "webdav",
                accountId: webDAVAccount.id,
                file: webDAVFile
            ),
            CloudDatabasePayload(
                provider: "onedrive",
                accountId: oneDriveAccount.id,
                file: oneDriveFile
            ),
        ])
        app.launchEnvironment[Self.uiTestDropboxPayloadEnv] = try encode(
            DropboxProviderPayload(
                accounts: [account],
                directories: [DropboxDirectoryPayload(path: nil, files: [cloudFile])],
                fileContentsByID: [cloudFile.id: fixtureBase64],
                contentHashByFileID: [cloudFile.id: "demo-content-hash"],
                revByFileID: [cloudFile.id: "demo-rev-1"],
                authenticateError: nil,
                listError: nil,
                metadataError: nil,
                downloadError: nil,
                uploadError: nil
            )
        )
        app.launchEnvironment[Self.uiTestWebDAVPayloadEnv] = try encode(
            WebDAVProviderPayload(
                accounts: [webDAVAccount],
                directories: [WebDAVDirectoryPayload(path: nil, files: [webDAVFile])],
                fileContentsByID: [webDAVFile.id: fixtureBase64],
                contentHashByFileID: [webDAVFile.id: "demo-webdav-content-hash"],
                revByFileID: [webDAVFile.id: "\"demo-webdav-rev-1\""],
                connectError: nil,
                authenticateError: nil,
                listError: nil,
                metadataError: nil,
                downloadError: nil,
                uploadError: nil
            )
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func saveScreenshot(_ name: ScreenshotName) {
        sleep(1)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Types Latin `text` (the demo password, the search term), switching keyboards only
    /// if it did not arrive: typeText types nothing on a Cyrillic keyboard, while kana,
    /// Zhuyin and Latin keyboards take it as is, and every globe tap risks an English
    /// "Quickly Change Keyboards" tip in the capture.
    private func typeLatin(_ text: String, into field: XCUIElement) {
        field.typeText(text)
        if !fieldShows(text, field) {
            switchToLatinKeyboard()
            replaceText(in: field, with: text)
        }
    }

    private func fieldShows(_ text: String, _ field: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let value = field.value as? String,
               value == text || (field.elementType == .secureTextField && value.count == text.count && value.allSatisfy { $0 == "•" }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    /// Cycles the globe key until a Latin letter keyboard shows. The globe is the lowest
    /// unidentified button on the keyboard's left half (Shift and Go carry identifiers),
    /// since its label is localized.
    private func switchToLatinKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 3) else { return }
        let latinLetter = keyboard.keys.matching(NSPredicate(format: "label ==[c] 'd'")).firstMatch
        for _ in 0..<3 where !latinLetter.waitForExistence(timeout: 1) {
            guard let globe = nextKeyboardKey(in: keyboard) else { break }
            globe.tap()
        }
        if !latinLetter.exists {
            let attachment = XCTAttachment(string: keyboard.debugDescription)
            attachment.name = "keyboard-without-latin-letters"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// iPhone lists the globe among the app's buttons below the keys. iPad's Russian layout has
    /// no globe but a Cyrillic/Latin toggle key at the left of the home row. Letters, the
    /// number-mode key, padding and the wide space bar are never it.
    private func nextKeyboardKey(in keyboard: XCUIElement) -> XCUIElement? {
        let keyboardFrame = keyboard.frame
        let candidates = (app.buttons.allElementsBoundByIndex + keyboard.keys.allElementsBoundByIndex)
            .filter { element in
                let frame = element.frame
                return element.identifier.isEmpty && element.label.count > 1
                    && element.label.rangeOfCharacter(from: .decimalDigits) == nil
                    && frame.width > 0 && frame.width < frame.height * 3
                    && frame.midY > keyboardFrame.minY && frame.midX < keyboardFrame.midX
            }
        guard let lowest = candidates.map(\.frame.midY).max() else { return nil }
        return candidates
            .filter { $0.frame.midY > lowest - 10 }
            .min { $0.frame.midX < $1.frame.midX }
    }

    private func tapBackButton() {
        let toolbarIdentifiers = Set(["lock.button", "settings.button", "vault.more", "sort.menu", "Done"])

        let backButton = app.navigationBars.buttons.allElementsBoundByIndex.first { button in
            guard button.exists && button.isHittable else { return false }
            let identifier = button.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = button.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if toolbarIdentifiers.contains(identifier) || toolbarIdentifiers.contains(label) {
                return false
            }
            return true
        }

        if let backButton {
            backButton.tap()
            sleep(1)
        }
    }

    private func cloudDatabaseRow(containing name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == 'database.row' AND label CONTAINS[c] %@", name)
        ).firstMatch
    }

    func testCaptureAllScreenshots() throws {
        XCTAssertTrue(waitForDatabaseList(timeout: 10), "Database rows should appear on the home screen")
        XCTAssertTrue(cloudDatabaseRow(containing: "Shared Vault").waitForExistence(timeout: 5), "Dropbox-backed database row should appear on the home screen")
        XCTAssertTrue(cloudDatabaseRow(containing: "Family WebDAV").waitForExistence(timeout: 5), "WebDAV-backed database row should appear on the home screen")
        XCTAssertTrue(cloudDatabaseRow(containing: "OneDrive Backup").waitForExistence(timeout: 5), "OneDrive-backed database row should appear on the home screen")
        saveScreenshot(.databaseList)

        XCTAssertTrue(openFirstDatabaseFromListIfNeeded(), "Unlock sheet should appear after opening the first database")
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field should appear in unlock sheet")
        passwordField.tap()
        typeLatin(demoPassword, into: passwordField)
        saveScreenshot(.unlockScreen)

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
        unlockButton.tap()
        XCTAssertTrue(waitForVaultToUnlock(), "Vault should unlock with the demo fixture password")
        sleep(2)

        saveScreenshot(.vaultGroups)

        openDatabaseDetailsFromVault()
        let closeButton = app.buttons["database-details.close"]
        sleep(1)
        saveScreenshot(.databaseSettings)

        closeButton.tap()
        sleep(1)

        let primaryGroup = app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
            .first(where: { $0.label.contains("Social") })
            ?? app.buttons.matching(identifier: "group.navlink").allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(primaryGroup, "A top-level group should exist after unlock")
        primaryGroup?.tap()
        sleep(2)
        saveScreenshot(.entryList)

        let entries = app.buttons.matching(identifier: "entry.navlink").allElementsBoundByIndex
        let totpEntry = entries.first(where: { $0.label.contains("Discord") })
            ?? entries.first(where: { $0.label.contains("Twitter") })
            ?? entries.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(totpEntry, "Should find an entry in the selected group")
        totpEntry?.tap()
        sleep(1)

        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.waitForExistence(timeout: 3) && revealButton.isHittable {
            revealButton.tap()
            sleep(1)
        }

        let totpCopy = app.buttons["entry.copy.totp"]
        if totpCopy.exists && !totpCopy.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }
        saveScreenshot(.entryDetail)

        // The demo Discord entry also holds a passkey; its section sits below the one-time code.
        // Found by its relying party, which reads the same in every locale; card rows hide the copy button's ID.
        let passkeySection = app.staticTexts.matching(NSPredicate(format: "label == 'discord.com'")).firstMatch
        // The section's username row sits below the relying party, so keep the relying party in the top 70%.
        func passkeyFits() -> Bool {
            passkeySection.exists && passkeySection.frame.maxY < app.frame.height * 0.7
                && passkeySection.frame.minY > app.frame.height * 0.12
        }
        var drags = 0
        while drags < 6 && !passkeyFits() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            drags += 1
            sleep(1)
        }
        XCTAssertTrue(passkeyFits(), "The demo Discord entry should show its whole passkey section")
        saveScreenshot(.entryPasskey)
        // iPad shows the passkey without scrolling, and a stray swipe there breaks the way back.
        for _ in 0..<drags {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            sleep(1)
        }

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: Self.ciElementTimeout), "Edit button should be visible from entry detail")
        editButton.tap()
        XCTAssertTrue(app.textFields["entry-edit.title-field"].waitForExistence(timeout: Self.ciElementTimeout), "Entry editor should appear")
        saveScreenshot(.entryEdit)

        let cancelButton = app.buttons["entry-edit.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        sleep(1)

        let searchField = app.searchFields.firstMatch
        tapBackButton()
        // iPad's split view shows the group list after one step back; a second tap would hide the sidebar.
        if app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 2) {
            tapBackButton()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should be visible on GroupListView")
        searchField.tap()
        sleep(1)
        let activeSearchField = app.searchFields.firstMatch
        if activeSearchField.waitForExistence(timeout: 3) {
            activeSearchField.tap()
            sleep(1)
        }
        typeLatin("git", into: activeSearchField)
        sleep(2)
        saveScreenshot(.search)
    }
}
