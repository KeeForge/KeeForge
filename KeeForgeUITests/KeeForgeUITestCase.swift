import XCTest

@MainActor
class KeeForgeUITestCase: XCTestCase {
    private static let uiTestDBBase64Env = "UI_TEST_DB_BASE64"
    private static let uiTestDBFilenameEnv = "UI_TEST_DB_FILENAME"
    private static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
    private static let uiTestKeyFileBase64Env = "UI_TEST_KEYFILE_BASE64"
    private static let uiTestKeyFileFilenameEnv = "UI_TEST_KEYFILE_FILENAME"
    private static let passwordDeleteCount = 128

    /// Generous element-appearance timeout tuned for Xcode Cloud's slower,
    /// 4-way-parallel simulators, where sheets and detail screens can take
    /// noticeably longer to settle than on a local machine. Local runs settle
    /// well under this, so raising it costs nothing on the happy path.
    static let ciElementTimeout: TimeInterval = 15

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

    override func setUp() async throws {
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
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 30)
        let databaseRow = app.buttons["database.row"].firstMatch
        let passwordField = app.secureTextFields["unlock.password.field"]
        let lockButton = app.buttons["lock.button"]
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            if databaseRow.exists || passwordField.exists || lockButton.exists {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
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
        // Unlocking is flaky under Cloud's 4-way-parallel simulators: the
        // password can be typed before the field/keyboard is fully ready, which
        // surfaces as a "wrong password" error even though the fixture password
        // is correct. Retry the whole unlock a couple of times when the vault
        // reports an unlock error, and only fall through to the asserting waiter
        // (which surfaces the real error message) on the final attempt.
        let maxAttempts = 3
        for _ in 1 ..< maxAttempts {
            unlock(password: "testpassword123")
            if pollUnlockOutcome(timeout: 30) == .unlocked {
                return
            }
            // Let the unlock screen settle (error shown, field re-enabled)
            // before re-entering the password.
            _ = app.secureTextFields["unlock.password.field"].waitForExistence(timeout: 5)
        }

        unlock(password: "testpassword123")
        waitForVaultToUnlock(file: file, line: line)
    }

    private enum UnlockOutcome {
        case unlocked
        case failed
    }

    /// Polls until the vault unlocks (a `lock.button` appears), a non-empty
    /// unlock error surfaces, or `timeout` elapses. Non-asserting so callers
    /// can retry; `waitForVaultToUnlock` remains the asserting variant.
    private func pollUnlockOutcome(timeout: TimeInterval) -> UnlockOutcome {
        let lockButtonQuery = app.buttons.matching(identifier: "lock.button")
        let errorLabel = app.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if lockButtonQuery.allElementsBoundByIndex.contains(where: \.exists) {
                return .unlocked
            }
            if errorLabel.exists,
               errorLabel.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return .failed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return .failed
    }

    func replaceText(in element: XCUIElement, with text: String) {
        // Make sure the field is actually present and focusable before typing;
        // tapping (or coordinate-tapping) a not-yet-ready field is a common
        // source of dropped keystrokes on slower CI simulators.
        _ = element.waitForExistence(timeout: 10)
        focusFieldForTyping(element)
        let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.passwordDeleteCount)
        element.typeText(deleteSequence)
        element.typeText(text)
    }

    /// Taps `element` to give it keyboard focus before typing. On compact
    /// devices (e.g. iPhone SE) a form field lower on screen can sit underneath
    /// the software keyboard raised by a previously-focused field; a plain
    /// center tap then lands on the keyboard, focus never moves, and the
    /// following `typeText` fails with "Neither element nor any descendant has
    /// keyboard focus". Scroll the field clear of the keyboard first. On tall
    /// devices nothing is occluded, so the scroll loop is a no-op.
    private func focusFieldForTyping(_ element: XCUIElement) {
        scrollFieldClearOfKeyboard(element)
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func scrollFieldClearOfKeyboard(_ element: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        // No keyboard up yet → the field can't be occluded by one.
        guard keyboard.exists, element.exists else { return }
        guard let container = scrollableContainer(), container.exists else { return }

        var attempts = 0
        while attempts < 6,
              keyboard.exists,
              element.exists,
              element.frame.maxY > keyboard.frame.minY - 12 {
            // Gentle upward drag (≈20% of the container) so the field rises
            // above the keyboard without overshooting past the top edge.
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
        }
    }

    func databaseRow(containing text: String) -> XCUIElement {
        let cell = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        if cell.exists {
            return cell
        }

        return app.buttons.matching(
            NSPredicate(format: "identifier == 'database.row' AND label CONTAINS[c] %@", text)
        ).firstMatch
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func firstExistingElement(in query: XCUIElementQuery) -> XCUIElement {
        let candidates = query.allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
            ?? candidates.first(where: { $0.exists })
            ?? query.firstMatch
    }

    func currentLockButton() -> XCUIElement {
        firstExistingElement(in: app.buttons.matching(identifier: "lock.button"))
    }

    @discardableResult
    func openDatabase(
        named name: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let row = databaseRow(containing: name)
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "Database '\(name)' was not visible", file: file, line: line)
        tapElement(row)

        let passwordField = app.secureTextFields["unlock.password.field"]
        let chooseDifferentButton = app.buttons["unlock.choose-different"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if passwordField.exists || chooseDifferentButton.exists || currentLockButton().exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail(
            "Database '\(name)' did not open into an unlock or vault screen within \(timeout) seconds",
            file: file,
            line: line
        )
        return false
    }

    @discardableResult
    func waitForVaultToUnlock(
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let lockButtonQuery = app.buttons.matching(identifier: "lock.button")
        let errorLabel = app.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)
        var lastErrorMessage: String?

        repeat {
            if lockButtonQuery.allElementsBoundByIndex.contains(where: \.exists) {
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
    func waitForLockedState(timeout: TimeInterval = 10) -> Bool {
        let databaseRow = app.buttons["database.row"].firstMatch
        let passwordField = app.secureTextFields["unlock.password.field"]
        let chooseDifferentButton = app.buttons["unlock.choose-different"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if databaseRow.exists || passwordField.exists || chooseDifferentButton.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return databaseRow.exists || passwordField.exists || chooseDifferentButton.exists
    }

    func requireRegularWidthLayout(file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window did not appear", file: file, line: line)
        guard window.frame.width >= 700 else {
            throw XCTSkip("Requires a regular-width simulator destination")
        }
    }

    @discardableResult
    func openFirstDatabaseFromListIfNeeded(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: timeout)

        let passwordField = app.secureTextFields["unlock.password.field"]
        if passwordField.waitForExistence(timeout: 1) {
            return true
        }

        let databaseRowQuery = app.buttons.matching(identifier: "database.row")
        let databaseRow = databaseRowQuery.firstMatch
        let databaseCell = app.cells.firstMatch
        let listDeadline = Date().addingTimeInterval(timeout)
        while !databaseRow.exists && !databaseCell.exists && Date() < listDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        XCTAssertTrue(
            databaseRow.exists || databaseCell.exists,
            "Database list did not appear",
            file: file,
            line: line
        )

        let rowCandidates: [XCUIElement] = [databaseRow, databaseCell]

        // Prefer a normally hittable row, but fall back to a coordinate tap when
        // XCTest exposes the row before it reports as hittable.
        let hittableDeadline = Date().addingTimeInterval(timeout)
        var hittableRow: XCUIElement?
        while hittableRow == nil, Date() < hittableDeadline {
            hittableRow = databaseRowQuery.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
                ?? rowCandidates.first(where: { $0.exists && $0.isHittable })
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        let tapTarget: XCUIElement
        if let hittableRow {
            tapTarget = hittableRow
        } else {
            guard let fallbackRow = rowCandidates.first(where: { $0.exists }) else {
                XCTFail("Database row was not visible", file: file, line: line)
                return false
            }
            tapTarget = fallbackRow
        }

        let tapSequence = [tapTarget, databaseRow, databaseCell]
        for _ in 0..<3 {
            app.activate()
            for candidate in tapSequence where candidate.exists {
                if candidate.isHittable {
                    candidate.tap()
                } else {
                    XCTAssertGreaterThan(candidate.frame.width, 0, "Database row frame was empty", file: file, line: line)
                    XCTAssertGreaterThan(candidate.frame.height, 0, "Database row frame was empty", file: file, line: line)
                    let isDatabaseRow = candidate.identifier == "database.row"
                    let offset = isDatabaseRow
                        ? CGVector(dx: 0.2, dy: 0.5)
                        : CGVector(dx: 0.5, dy: 0.5)
                    candidate.coordinate(withNormalizedOffset: offset).tap()
                }

                if passwordField.waitForExistence(timeout: 3) {
                    return true
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 1),
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
        candidateScrollableContainers().first
    }

    private func candidateScrollableContainers() -> [XCUIElement] {
        let types: [XCUIElement.ElementType] = [.collectionView, .table, .scrollView]
        var candidates: [XCUIElement] = []

        for type in types {
            for element in app.descendants(matching: type).allElementsBoundByIndex
            where isSafeToHitTest(element) {
                candidates.append(element)
            }
        }

        if candidates.isEmpty == false {
            return candidates.sorted(by: preferredContainerOrder)
        }

        // Fall back to any existing container
        for type in types {
            let existing = app.descendants(matching: type).allElementsBoundByIndex.filter {
                $0.exists && hasUsableFrame($0)
            }
            if existing.isEmpty == false {
                return existing.sorted(by: preferredContainerOrder)
            }
        }

        return []
    }

    private func preferredContainerOrder(_ lhs: XCUIElement, _ rhs: XCUIElement) -> Bool {
        let leftArea = lhs.frame.width * lhs.frame.height
        let rightArea = rhs.frame.width * rhs.frame.height

        if leftArea != rightArea {
            return leftArea > rightArea
        }

        if lhs.frame.minX != rhs.frame.minX {
            return lhs.frame.minX > rhs.frame.minX
        }

        return lhs.frame.minY < rhs.frame.minY
    }

    @discardableResult
    func revealElement(
        _ element: XCUIElement,
        in container: XCUIElement? = nil,
        direction: SwipeDirection = .up,
        maxSwipes: Int = 6
    ) -> Bool {
        if isSafeToHitTest(element) {
            return true
        }

        if let container, container.exists {
            if element.waitForExistence(timeout: 1), isSafeToHitTest(element) {
                return true
            }

            for _ in 0..<maxSwipes {
                switch direction {
                case .up:
                    container.swipeUp()
                case .down:
                    container.swipeDown()
                }

                if element.waitForExistence(timeout: 1), isSafeToHitTest(element) {
                    return true
                }
            }
        } else {
            for _ in 0..<maxSwipes {
                switch direction {
                case .up:
                    app.swipeUp()
                case .down:
                    app.swipeDown()
                }

                if element.waitForExistence(timeout: 1), isSafeToHitTest(element) {
                    return true
                }
            }
        }

        return element.exists
    }

    private func hasUsableFrame(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private func isSafeToHitTest(_ element: XCUIElement) -> Bool {
        guard element.exists, hasUsableFrame(element) else { return false }
        return element.isHittable
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
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX {
                    return lhs.frame.minX > rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }
            .first
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
            let groups = app.descendants(matching: .any).matching(identifier: "group.navlink")
                .allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
                .sorted { lhs, rhs in
                    if lhs.frame.minX != rhs.frame.minX {
                        return lhs.frame.minX > rhs.frame.minX
                    }
                    return lhs.frame.minY < rhs.frame.minY
                }
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
