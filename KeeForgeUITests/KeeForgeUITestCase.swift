import XCTest

@MainActor
class KeeForgeUITestCase: XCTestCase {
    private static let uiTestDBBase64Env = "UI_TEST_DB_BASE64"
    private static let uiTestDBFilenameEnv = "UI_TEST_DB_FILENAME"
    private static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
    private static let uiTestKeyFileBase64Env = "UI_TEST_KEYFILE_BASE64"
    private static let uiTestKeyFileFilenameEnv = "UI_TEST_KEYFILE_FILENAME"
    private static let passwordDeleteCount = 128

    struct DatabaseFixture {
        let resourceName: String
        let resourceExtension: String
        let injectedFilename: String

        init(resourceName: String, resourceExtension: String = "kdbx", injectedFilename: String) {
            self.resourceName = resourceName
            self.resourceExtension = resourceExtension
            self.injectedFilename = injectedFilename
        }
    }

    enum SwipeDirection {
        case up
        case down
    }

    var app: XCUIApplication!

    /// Override in subclasses to use a different database fixture (e.g. "demo-keyfile").
    var databaseFixtureName: String { "test" }
    var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: databaseFixtureName, injectedFilename: "\(databaseFixtureName).kdbx")]
    }

    /// Override in subclasses to inject a key file fixture (e.g. "demo-keyfile", extension "key").
    var keyFileFixtureName: String? { nil }
    var keyFileFixtureExtension: String { "key" }

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()

        let payloads = try databaseFixtures.map { fixture -> [String: String] in
            guard let fixtureURL = Bundle(for: KeeForgeUITestCase.self).url(
                forResource: fixture.resourceName,
                withExtension: fixture.resourceExtension
            ) else {
                throw NSError(
                    domain: "KeeForgeUITests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing \(fixture.resourceName).\(fixture.resourceExtension) fixture in test bundle"]
                )
            }

            let fixtureData = try Data(contentsOf: fixtureURL)
            return [
                "filename": fixture.injectedFilename,
                "base64": fixtureData.base64EncodedString(),
            ]
        }

        app.launchArguments += ["-ui-testing"]
        let payloadData = try JSONSerialization.data(withJSONObject: payloads, options: [])
        app.launchEnvironment[Self.uiTestDatabasesJSONEnv] = String(decoding: payloadData, as: UTF8.self)

        if let firstFixture = databaseFixtures.first {
            app.launchEnvironment[Self.uiTestDBFilenameEnv] = firstFixture.injectedFilename
        }

        if let keyFileName = keyFileFixtureName {
            let ext = keyFileFixtureExtension
            guard let keyFileURL = Bundle(for: KeeForgeUITestCase.self).url(forResource: keyFileName, withExtension: ext) else {
                throw NSError(domain: "KeeForgeUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(keyFileName).\(ext) fixture in test bundle"])
            }
            let keyFileData = try Data(contentsOf: keyFileURL)
            app.launchEnvironment[Self.uiTestKeyFileBase64Env] = keyFileData.base64EncodedString()
            app.launchEnvironment[Self.uiTestKeyFileFilenameEnv] = "\(keyFileName).\(ext)"
        }

        try configureLaunch(app: app)
        app.launch()
    }

    func configureLaunch(app: XCUIApplication) throws {}

    func fixtureData(resourceName: String, resourceExtension: String) throws -> Data {
        guard let fixtureURL = Bundle(for: KeeForgeUITestCase.self).url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw NSError(
                domain: "KeeForgeUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(resourceName).\(resourceExtension) fixture in test bundle"]
            )
        }

        return try Data(contentsOf: fixtureURL)
    }

    func unlock(password: String) {
        openFirstDatabaseFromListIfNeeded()

        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field did not appear")

        replaceText(in: passwordField, with: password)
        app.buttons["unlock.button"].tap()
    }

    func unlockSuccessfully(file: StaticString = #filePath, line: UInt = #line) {
        unlock(password: "testpassword123")
        waitForVaultToUnlock(file: file, line: line)
    }

    func replaceText(in element: XCUIElement, with text: String) {
        element.tap()
        let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.passwordDeleteCount)
        element.typeText(deleteSequence)
        element.typeText(text)
    }

    @discardableResult
    func waitForVaultToUnlock(
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let lockButton = app.buttons["lock.button"]
        let errorLabel = app.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)
        var lastErrorMessage: String?

        repeat {
            if lockButton.exists {
                return true
            }

            if errorLabel.exists {
                let message = errorLabel.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    lastErrorMessage = message
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        if let lastErrorMessage {
            XCTFail("Vault did not unlock. Last error: \(lastErrorMessage)", file: file, line: line)
        } else {
            XCTFail("Vault did not unlock within \(timeout) seconds", file: file, line: line)
        }
        return false
    }

    @discardableResult
    func waitForDatabaseList(timeout: TimeInterval = 10) -> Bool {
        let databaseRow = app.buttons["database.row"].firstMatch
        return databaseRow.waitForExistence(timeout: timeout)
    }

    @discardableResult
    func openFirstDatabaseFromListIfNeeded(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let passwordField = app.secureTextFields["unlock.password.field"]
        if passwordField.waitForExistence(timeout: 1) {
            return true
        }

        let databaseRow = app.buttons["database.row"].firstMatch
        XCTAssertTrue(
            databaseRow.waitForExistence(timeout: timeout),
            "Database list did not appear",
            file: file,
            line: line
        )
        databaseRow.tap()

        XCTAssertTrue(
            passwordField.waitForExistence(timeout: timeout),
            "Password field did not appear after opening the database",
            file: file,
            line: line
        )
        return passwordField.exists
    }

    func scrollableContainer() -> XCUIElement? {
        frontmostContainer()
    }

    /// Returns the frontmost (hittable) list/scroll container, preferring
    /// the one in a presented sheet over background views.
    private func frontmostContainer() -> XCUIElement? {
        let types: [XCUIElement.ElementType] = [.collectionView, .table, .scrollView]

        // Prefer a hittable container (e.g. inside the presented sheet)
        for type in types {
            for element in app.descendants(matching: type).allElementsBoundByIndex
            where element.exists && element.isHittable {
                return element
            }
        }

        // Fall back to any existing container
        let fallbacks: [XCUIElement] = [
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
            app.scrollViews.firstMatch,
        ]
        for candidate in fallbacks where candidate.exists {
            return candidate
        }

        return nil
    }

    @discardableResult
    func revealElement(
        _ element: XCUIElement,
        in container: XCUIElement? = nil,
        direction: SwipeDirection = .up,
        maxSwipes: Int = 6
    ) -> Bool {
        if element.exists && element.isHittable {
            return true
        }

        let scrollContainer = container ?? scrollableContainer()

        guard let scrollContainer, scrollContainer.exists else {
            return element.waitForExistence(timeout: 1)
        }

        if element.waitForExistence(timeout: 1), element.isHittable {
            return true
        }

        for _ in 0..<maxSwipes {
            switch direction {
            case .up:
                scrollContainer.swipeUp()
            case .down:
                scrollContainer.swipeDown()
            }

            if element.waitForExistence(timeout: 1), element.isHittable {
                return true
            }
        }

        return element.exists
    }

    @discardableResult
    func waitForDocumentPicker(timeout: TimeInterval = 15) -> Bool {
        let browseNav = app.navigationBars.matching(
            NSPredicate(format: "label CONTAINS[c] 'Browse' OR label CONTAINS[c] 'Recents'")
        ).firstMatch
        let browseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Browse' OR label CONTAINS[c] 'Recents'")
        ).firstMatch
        let cancelButton = app.buttons["Cancel"]
        let doneButton = app.buttons["Done"]
        let documentManager = app.otherElements.matching(
            NSPredicate(format: "identifier CONTAINS[c] 'Document' OR label CONTAINS[c] 'Browse' OR label CONTAINS[c] 'Recents'")
        ).firstMatch

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if browseNav.exists || browseButton.exists || cancelButton.exists || doneButton.exists || documentManager.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return false
    }

    private func currentListContainer() -> XCUIElement? {
        frontmostContainer()
    }

    private func firstHittableNavigationLink(identifier: String) -> XCUIElement? {
        let query: XCUIElementQuery
        if let container = currentListContainer() {
            query = container.descendants(matching: .any).matching(identifier: identifier)
        } else {
            query = app.descendants(matching: .any).matching(identifier: identifier)
        }

        return query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    private func waitForHittableNavigationLink(identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = firstHittableNavigationLink(identifier: identifier) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
    }

    private func tryRevealEntryInCurrentList() -> XCUIElement? {
        guard let container = currentListContainer(), container.exists else {
            return nil
        }

        for _ in 0..<2 {
            container.swipeUp()
            if let entry = firstHittableNavigationLink(identifier: "entry.navlink") {
                return entry
            }
        }

        for _ in 0..<2 {
            container.swipeDown()
            if let entry = firstHittableNavigationLink(identifier: "entry.navlink") {
                return entry
            }
        }

        return nil
    }

    /// Find a non-empty group to tap. Prefers groups whose label contains a non-zero entry count.
    private func findNonEmptyGroup(timeout: TimeInterval = 3) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Search all element types — NavigationLink may render as button or cell
            let groups = app.descendants(matching: .any).matching(identifier: "group.navlink")
                .allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
            // Prefer groups that don't say "0 entries"
            if let nonEmpty = groups.first(where: { !$0.label.contains("0 entries") }) {
                return nonEmpty
            }
            // Fall back to any group
            if let any = groups.first {
                return any
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    @discardableResult
    func openAnyEntry(maxDepth: Int = 8) -> Bool {
        for _ in 0..<maxDepth {
            if let entry = waitForHittableNavigationLink(identifier: "entry.navlink", timeout: 3) {
                entry.tap()
                return true
            }

            if let entry = tryRevealEntryInCurrentList() {
                entry.tap()
                return true
            }

            if let group = findNonEmptyGroup() {
                group.tap()
                continue
            }

            return false
        }

        return false
    }

    func firstVisibleEntryLabel(navigatingGroups maxDepth: Int = 8) -> String? {
        for _ in 0..<maxDepth {
            if let entry = waitForHittableNavigationLink(identifier: "entry.navlink", timeout: 3) {
                return normalizedEntryTitle(from: entry.label)
            }

            if let entry = tryRevealEntryInCurrentList() {
                return normalizedEntryTitle(from: entry.label)
            }

            if let group = findNonEmptyGroup() {
                group.tap()
                continue
            }

            return nil
        }

        return nil
    }

    private func normalizedEntryTitle(from rawLabel: String) -> String {
        let title = rawLabel
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        return rawLabel
    }
}
