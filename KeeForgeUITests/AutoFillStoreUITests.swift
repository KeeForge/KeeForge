import XCTest

// Requires a disposable physical iPhone with KeeForge enabled as its AutoFill
// provider. Seed once per test; subsequent launches preserve database UUIDs.
// Each scenario clears the real store before publishing its dedicated fixtures.
@MainActor
final class AutoFillStoreUITests: AppSettingsUITestCase {

    // MARK: - Fixtures

    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        [
            .init(resourceName: "autofill-store-alpha", injectedFilename: "alpha.kdbx"),
            .init(resourceName: "autofill-store-bravo", injectedFilename: "bravo.kdbx"),
        ]
    }

    private static let alphaIdentityCount = 2
    private static let bravoIdentityCount = 3
    private static let fixturePassword = "testpassword123"

    private func alphaMetadata(databaseID: String) -> [String] {
        let record = "v2:\(databaseID):11111111-1111-4111-8111-111111111111"
        return [
            "password|https://alpha-store-fixture.net|alpha-user|\(record)",
            "oneTimeCode|alpha-store-fixture.net|Alpha Login (alpha-user)|\(record)",
        ]
    }

    private func bravoMetadata(databaseID: String) -> [String] {
        let login = "v2:\(databaseID):22222222-2222-4222-8222-222222222222"
        let password = "v2:\(databaseID):33333333-3333-4333-8333-333333333333"
        return [
            "password|https://bravo-store-fixture.org|bravo-user|\(login)",
            "oneTimeCode|bravo-store-fixture.org|Bravo Login (bravo-user)|\(login)",
            "password|https://bravo-password-fixture.com|bravo-password-user|\(password)",
        ]
    }

    // MARK: - Identifiers

    private static let inspectorArgument = "-autofill-store-inspector"
    private static let enabledStateID = "autofill-inspector.enabled-state"
    private static let totalCountID = "autofill-inspector.total-count"
    private static let refreshID = "autofill-inspector.refresh"
    private static let databaseTogglePrefix = "settings.autofill.database-toggle."

    /// UserDefaults argument-domain overrides applied to every launch so
    /// one-shot system/app overlays cannot land mid-flow on the long-lived
    /// test device: the StoreKit review prompt (`hasPrompted` counts
    /// unlocks in standard defaults, which persist across runs) and the
    /// AutoFill tip banner (irrelevant while the provider is enabled, but the
    /// dismissal flag keeps argument-free launches deterministic).
    private static let launchDefaultsOverrides = [
        "-KeeForge.reviewPrompt.hasPrompted", "YES",
        "-KeeForge.autoFillTip.dismissed", "YES",
    ]

    // MARK: - Skip guard

    private struct StoreProbe {
        let isEnabled: Bool
    }

    /// Cached once per test-runner process so only the first test performs the
    /// probe launch; the rest skip (or proceed) immediately.
    private static var cachedStoreProbe: StoreProbe?

    override func setUp() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        try skipUnlessProvisionedStoreIsAvailable()
        try await super.setUp()
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += Self.launchDefaultsOverrides
    }

    /// Launches the inspector (registry untouched — no `-ui-testing`), reads
    /// the store state, and skips the test unless the store is enabled.
    private func skipUnlessProvisionedStoreIsAvailable() throws {
        let probe: StoreProbe
        if let cachedProbe = Self.cachedStoreProbe {
            probe = cachedProbe
        } else {
            let inspector = XCUIApplication()
            inspector.launchArguments = [Self.inspectorArgument] + Self.launchDefaultsOverrides
            inspector.launch()
            _ = inspector.wait(for: .runningForeground, timeout: 30)

            let enabledState = inspector.staticTexts[Self.enabledStateID]
            guard enabledState.waitForExistence(timeout: 30),
                  let value = enabledState.value as? String,
                  ["enabled", "disabled"].contains(value) else {
                inspector.terminate()
                throw NSError(domain: "AutoFillStoreUITests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Store inspector did not report provider readiness"])
            }
            let result = StoreProbe(isEnabled: value == "enabled")
            inspector.terminate()
            Self.cachedStoreProbe = result
            probe = result
        }

        guard probe.isEnabled else {
            throw XCTSkip(
                "AutoFill store is disabled — KeeForge is not this device's enabled "
                    + "credential provider. Run against a physical iPhone with KeeForge "
                    + "turned on in Settings > General > AutoFill & Passwords."
            )
        }
    }

    // MARK: - Re-enable across relaunches

    func testReEnableStaysEmptyUntilNextUnlock() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))

        launchNormalRoot()
        openAutoFillSettings()
        let alphaToggle = app.switches[Self.databaseTogglePrefix + ids.alpha]
        XCTAssertTrue(
            alphaToggle.waitForExistence(timeout: Self.ciElementTimeout),
            "Per-database toggle for the seeded alpha UUID did not survive the relaunch"
        )
        setSwitch(alphaToggle, isOn: false)
        clearStoreFromAutoFillSettings()
        XCTAssertTrue(
            revealElement(alphaToggle, in: scrollableContainer(), direction: .down),
            "Alpha toggle was not visible after clearing the store"
        )
        setSwitch(alphaToggle, isOn: true)
        leaveAutoFillSettings()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        assertInspectorDatabaseSectionAbsent(ids.alpha)

        launchNormalRoot()
        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))
    }

    // MARK: - Confirmed clear

    func testClearAutoFillEntriesReachesZero() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))

        launchNormalRoot()
        openAutoFillSettings()
        clearStoreFromAutoFillSettings()
        leaveAutoFillSettings()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        assertInspectorDatabaseSectionAbsent(ids.alpha)
        assertInspectorValue(Self.enabledStateID, equals: "enabled")
    }

    func testPublicationUnionAndTargetedRemovalPreserveOtherDatabase() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()
        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))
        assertInspectorDatabaseSectionAbsent(ids.bravo)

        launchNormalRoot()
        unlockDatabase(named: "bravo")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount + Self.bravoIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))
        assertDatabaseMetadata(ids.bravo, equals: bravoMetadata(databaseID: ids.bravo))

        launchNormalRoot()
        openDatabaseDetails(rowContaining: "bravo")
        openDatabaseDetailsPage(.autoFill)
        let detailsToggle = app.switches["database-details.autofill-toggle"]
        XCTAssertTrue(revealElement(detailsToggle, in: scrollableContainer()))
        setSwitch(detailsToggle, isOn: false)
        closeDatabaseDetails()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        assertDatabaseMetadata(ids.alpha, equals: alphaMetadata(databaseID: ids.alpha))
        assertInspectorDatabaseSectionAbsent(ids.bravo)

        launchNormalRoot()
        openAutoFillSettings()
        let alphaToggle = app.switches[Self.databaseTogglePrefix + ids.alpha]
        XCTAssertTrue(revealElement(alphaToggle, in: scrollableContainer()))
        setSwitch(alphaToggle, isOn: false)
        leaveAutoFillSettings()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        assertInspectorDatabaseSectionAbsent(ids.alpha)
        assertInspectorDatabaseSectionAbsent(ids.bravo)
        assertInspectorValue(Self.enabledStateID, equals: "enabled")
    }

    // MARK: - Seeding, capture, and baseline

    private struct SeededDatabaseIDs {
        /// Uppercase `UUID.uuidString` values captured from the settings
        /// toggle identifiers — the same casing the inspector's
        /// `autofill-inspector.database.<uuid>.count` identifiers use.
        let alpha: String
        let bravo: String
    }

    /// Per-test preamble run in the seeded (`-ui-testing`) launch: captures
    /// this seed's database UUIDs from the Settings → AutoFill toggles,
    /// ensures Quick AutoFill is on (publication is gated on it; the flag
    /// lives in the App Group defaults, which persist on the harness device),
    /// and clears the store so the test starts from a known-empty baseline
    /// regardless of residue from earlier runs or manual use.
    private func seedStoreBaselineAndCaptureDatabaseIDs(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SeededDatabaseIDs {
        XCTAssertTrue(
            waitForDatabaseList(timeout: Self.ciElementTimeout),
            "Seeded database list did not appear",
            file: file,
            line: line
        )

        openAutoFillSettings(file: file, line: line)

        let toggles = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.databaseTogglePrefix)
        )
        let deadline = Date().addingTimeInterval(Self.ciElementTimeout)
        while toggles.count < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        var uuidsByLabel: [String: String] = [:]
        for toggle in toggles.allElementsBoundByIndex where toggle.exists {
            let uuid = String(toggle.identifier.dropFirst(Self.databaseTogglePrefix.count))
            uuidsByLabel[toggle.label] = uuid
        }

        guard
            let alphaID = uuidsByLabel.first(where: { $0.key.contains("alpha") })?.value,
            let bravoID = uuidsByLabel.first(where: { $0.key.contains("bravo") })?.value
        else {
            struct DatabaseIDCaptureError: Error {}
            XCTFail(
                "Could not capture seeded database UUIDs from the AutoFill settings toggles "
                    + "(found: \(uuidsByLabel))",
                file: file,
                line: line
            )
            throw DatabaseIDCaptureError()
        }

        ensureQuickAutoFillEnabled(file: file, line: line)
        clearStoreFromAutoFillSettings(file: file, line: line)
        leaveAutoFillSettings(file: file, line: line)

        allowStoreWritesToSettle()
        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        launchNormalRoot()
        return SeededDatabaseIDs(alpha: alphaID, bravo: bravoID)
    }

    // MARK: - Launch phases

    /// Relaunches the app without `-ui-testing` so the seeded registry (UUIDs
    /// and persisted `autoFillEnabled` flags) survives.
    private func relaunch(arguments: [String]) {
        app.launchArguments = arguments + Self.launchDefaultsOverrides
        app.launchEnvironment = [:]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
    }

    /// Relaunches into the store inspector root and waits for the first
    /// snapshot.
    private func launchInspector(file: StaticString = #filePath, line: UInt = #line) {
        relaunch(arguments: [Self.inspectorArgument])
        XCTAssertTrue(
            app.staticTexts[Self.enabledStateID].waitForExistence(timeout: 30),
            "Store inspector did not present",
            file: file,
            line: line
        )
    }

    /// Relaunches into the normal database-list root (argument-free, so no
    /// registry reseed) and settles it: outside `-ui-testing` the What's New
    /// sheet can present once per app container when the current version has
    /// release notes — dismiss it if it does.
    private func launchNormalRoot(file: StaticString = #filePath, line: UInt = #line) {
        relaunch(arguments: [])

        let whatsNewDone = app.buttons["whats-new.done"]
        if whatsNewDone.waitForExistence(timeout: 3) {
            tapElement(whatsNewDone)
            let deadline = Date().addingTimeInterval(10)
            while whatsNewDone.exists, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }

        XCTAssertTrue(
            waitForDatabaseList(timeout: Self.ciElementTimeout),
            "Database list did not appear after relaunch",
            file: file,
            line: line
        )
    }

    /// Bounded settle window run *before terminating the app* after a
    /// store-mutating action (publish, targeted removal, clear): the app
    /// performs store writes in fire-and-forget tasks, and a write that has
    /// not landed when the process dies is lost, which no amount of
    /// inspector-side polling could recover. This is deliberately not an
    /// assertion wait — every assertion still polls inspector values.
    private func allowStoreWritesToSettle(seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Inspector assertions

    private func databaseCountID(_ uuid: String) -> String {
        "autofill-inspector.database.\(uuid).count"
    }

    /// Polls an inspector value row until it reads `expected`, re-enumerating
    /// the store via the refresh control between reads and scrolling the row
    /// into the accessibility hierarchy when it sits below the fold.
    private func waitForInspectorValue(
        _ identifier: String,
        toEqual expected: String,
        timeout: TimeInterval = 45,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.staticTexts[identifier]
        let refresh = app.buttons[Self.refreshID]
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved: String?

        repeat {
            let enumerationError = app.staticTexts["autofill-inspector.enumeration-error"]
            if enumerationError.exists {
                XCTFail(enumerationError.value as? String ?? enumerationError.label, file: file, line: line)
                return
            }
            let row = scanInspectorRow(element)
            if let value = row.value {
                lastObserved = value
                if value == expected {
                    return
                }
            }
            if refresh.exists, refresh.isHittable {
                refresh.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        } while Date() < deadline

        XCTFail(
            "Inspector \(identifier) read \(lastObserved.map { "\"\($0)\"" } ?? "<missing>"); "
                + "expected \"\(expected)\"",
            file: file,
            line: line
        )
    }

    private func assertDatabaseMetadata(
        _ databaseID: String,
        equals expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForInspectorValue(databaseCountID(databaseID), toEqual: "\(expected.count)", file: file, line: line)
        waitForInspectorValue("autofill-inspector.database.\(databaseID).identities",
                              toEqual: expected.sorted().joined(separator: "\n"), file: file, line: line)
    }

    /// Non-polling equality check for a value that a preceding
    /// `waitForInspectorValue` call has already settled (e.g. store state rows
    /// after the total count converged).
    private func assertInspectorValue(
        _ identifier: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = scanInspectorRow(app.staticTexts[identifier])
        XCTAssertTrue(row.exists, "Inspector row \(identifier) was not found", file: file, line: line)
        XCTAssertEqual(row.value, expected, file: file, line: line)
    }

    /// Asserts a database section is absent. Sections render only when
    /// non-empty, and rows below the fold are virtualized out of the
    /// accessibility hierarchy, so this swipes through the whole (short) list;
    /// callers first settle the totals so every identity is already accounted
    /// for by the surviving sections.
    private func assertInspectorDatabaseSectionAbsent(
        _ uuid: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = scanInspectorRow(app.staticTexts[databaseCountID(uuid)])
        XCTAssertFalse(
            row.exists,
            "Database section \(uuid) should not be present in the inspector",
            file: file,
            line: line
        )
    }

    /// Locates an inspector row, swiping down through the list to materialize
    /// virtualized rows when needed, and captures its value *while it is on
    /// screen* (rows scrolled back out of view leave the accessibility
    /// hierarchy, so reading the value later would fail). Scrolls back so the
    /// list ends near the top either way.
    private func scanInspectorRow(_ element: XCUIElement) -> (exists: Bool, value: String?) {
        if element.exists {
            return (true, element.value as? String)
        }
        guard let container = scrollableContainer(), container.exists else {
            return (false, nil)
        }

        var result: (exists: Bool, value: String?) = (false, nil)
        var swipes = 0
        while swipes < 4, result.exists == false {
            container.swipeUp()
            swipes += 1
            if element.exists {
                result = (true, element.value as? String)
            }
        }
        for _ in 0..<swipes {
            container.swipeDown()
        }
        return result
    }

    // MARK: - Settings flows

    private func openAutoFillSettings(file: StaticString = #filePath, line: UInt = #line) {
        openAppSettings(file: file, line: line)
        let autoFillLink = app.descendants(matching: .any)
            .matching(identifier: "settings.autofill.link").firstMatch
        revealInSettings(autoFillLink, maxSwipes: 2, file: file, line: line)
        tapElement(autoFillLink)
        XCTAssertTrue(
            app.buttons["settings.autofill.clear-entries"]
                .waitForExistence(timeout: Self.ciElementTimeout),
            "AutoFill settings screen did not appear",
            file: file,
            line: line
        )
    }

    /// Publication is gated on the Quick AutoFill flag, which lives in the App
    /// Group defaults and therefore persists across runs on the long-lived
    /// test device — force it on rather than assuming the default.
    private func ensureQuickAutoFillEnabled(file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches["Quick AutoFill"].firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "Quick AutoFill toggle was not visible",
            file: file,
            line: line
        )
        if (toggle.value as? String) != "1" {
            setSwitch(toggle, isOn: true, file: file, line: line)
        }
    }

    /// Runs the confirmed Clear AutoFill Entries action from the AutoFill
    /// settings screen (the confirm identifier matches two nested buttons —
    /// use `.firstMatch`, per the suite README).
    private func clearStoreFromAutoFillSettings(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let clearButton = app.buttons["settings.autofill.clear-entries"]
        revealInSettings(clearButton, file: file, line: line)
        tapElement(clearButton)

        let confirmButton = app.buttons["settings.autofill.clear-entries.confirm"].firstMatch
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 5),
            "Clear AutoFill Entries confirmation did not appear",
            file: file,
            line: line
        )
        tapElement(confirmButton)

        let deadline = Date().addingTimeInterval(10)
        while confirmButton.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(
            confirmButton.exists,
            "Clear AutoFill Entries confirmation did not dismiss",
            file: file,
            line: line
        )
    }

    /// Pops back from the AutoFill screen (the Done toolbar item lives on the
    /// Settings root) and dismisses the sheet.
    private func leaveAutoFillSettings(file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.navigationBars["AutoFill"].buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 5) {
            tapElement(backButton)
        }
        closeSettings(file: file, line: line)
        XCTAssertTrue(
            waitForDatabaseList(timeout: Self.ciElementTimeout),
            "Database list did not reappear after closing Settings",
            file: file,
            line: line
        )
    }

    // MARK: - Unlock / lock flows

    /// Unlocks a specific seeded database by row name with the same
    /// wrong-password retry the base class's `unlockSuccessfully` uses (the
    /// password can be typed before the field is ready on slow simulators).
    private func unlockDatabase(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let passwordField = app.secureTextFields["unlock.password.field"]
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if passwordField.exists == false {
                openDatabase(named: name, timeout: Self.ciElementTimeout, file: file, line: line)
            }
            XCTAssertTrue(
                passwordField.waitForExistence(timeout: 10),
                "Password field did not appear for '\(name)'",
                file: file,
                line: line
            )
            replaceText(in: passwordField, with: Self.fixturePassword)
            app.buttons["unlock.button"].tap()

            if pollForUnlock(timeout: 30) {
                return
            }
            if attempt < maxAttempts {
                // Let the unlock screen settle (error shown, field re-enabled)
                // before retrying.
                _ = passwordField.waitForExistence(timeout: 5)
            }
        }

        XCTFail("Database '\(name)' did not unlock", file: file, line: line)
    }

    /// Non-asserting unlock poll: true once a lock button exists, false on a
    /// surfaced unlock error or timeout.
    private func pollForUnlock(timeout: TimeInterval) -> Bool {
        let lockButtonQuery = app.buttons.matching(identifier: "lock.button")
        let errorLabel = app.staticTexts["unlock.error.label"]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if lockButtonQuery.allElementsBoundByIndex.contains(where: \.exists) {
                return true
            }
            if errorLabel.exists,
               errorLabel.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return false
    }

    private func lockVault(file: StaticString = #filePath, line: UInt = #line) {
        let lockButton = currentLockButton()
        XCTAssertTrue(
            lockButton.waitForExistence(timeout: Self.ciElementTimeout),
            "Lock button was not visible",
            file: file,
            line: line
        )
        tapElement(lockButton)
        XCTAssertTrue(
            waitForDatabaseList(timeout: Self.ciElementTimeout),
            "Database list did not reappear after locking",
            file: file,
            line: line
        )
    }
}
