import XCTest

/// Store-lifecycle assertions against the **real** `ASCredentialIdentityStore`
/// (epic: 2026-07-20-autofill-store-validation-harness, slice 03). Each test
/// drives real app flows (unlock, per-database AutoFill toggles, Clear AutoFill
/// Entries) and then reads the resulting store state through the slice 01
/// DEBUG inspector (`-autofill-store-inspector`).
///
/// ## Precondition
///
/// The system store only accepts writes once KeeForge is enabled as the
/// simulator's credential provider. Provision the dedicated harness simulator
/// once with the slice 02 recipe:
///
///     scripts/provision-autofill-harness-sim.sh
///
/// Device: **`KeeForge-AutoFill-Harness`** (iPhone-class, newest installed iOS
/// runtime; provider enablement persists until the device is erased). Run the
/// class against that device — never the default `iPhone 17 Pro`:
///
///     xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
///       -destination 'platform=iOS Simulator,name=KeeForge-AutoFill-Harness' \
///       -only-testing:KeeForgeUITests/AutoFillStoreUITests
///
/// ## Skip guard
///
/// Every test begins with a store-state probe through the inspector and calls
/// `XCTSkip` when the store is disabled or enumeration is unavailable, so a run
/// in the default suites or on an unprovisioned simulator all-skips quickly
/// instead of failing or hanging. The probe result is cached per test-runner
/// process: only the first test pays the probe launch.
///
/// ## `-ui-testing` reseed vs. store persistence (the interplay this class is
/// built around)
///
/// `DatabaseListStore.bootstrapForUITestingIfNeeded()` rebuilds
/// `database-list.json` on **every** launch that passes `-ui-testing`: the
/// fixture databases get fresh random `DatabaseReference` UUIDs, persisted
/// `autoFillEnabled` flags reset to their default (`true`), the active AutoFill
/// pointer is cleared, and the shared cache directories are wiped. The system
/// credential identity store, by contrast, is OS-owned: identities persist
/// across app launches, reinstalls, and registry reseeds, tagged with whatever
/// database UUID published them — a reseed therefore orphans everything the
/// previous seed published. This class resolves that as follows:
///
/// 1. **Seed exactly once per test.** Only the `setUp` launch passes
///    `-ui-testing`. The test then captures the seeded database UUIDs from the
///    `settings.autofill.database-toggle.<uuid>` accessibility identifiers.
///    Every later launch inside the same test omits `-ui-testing`
///    (`-autofill-store-inspector` only, or no arguments), so
///    `database-list.json` — UUIDs *and* persisted `autoFillEnabled` flips —
///    survives unchanged and inspector sections can be correlated with the
///    captured UUIDs. (`testReEnableStaysEmptyUntilNextUnlock` relies on this
///    directly: the same reference must be re-unlockable after a relaunch.)
/// 2. **Every test establishes its own store baseline.** The store may hold
///    residue from earlier runs, earlier tests in this class (tagged with
///    now-orphaned UUIDs), or manual use of the harness device. Each test
///    therefore runs the confirmed Clear AutoFill Entries action right after
///    capturing UUIDs and never assumes the store starts empty. Combined with
///    per-test seeding this makes every test independent of run order.
/// 3. **Store writes are fire-and-forget.** The app performs store mutations
///    in detached tasks; terminating the process too early can drop a write.
///    Tests interleave real UI steps after each mutating action and run a
///    short settle window (`allowStoreWritesToSettle`) before relaunching.
///    That settle is *not* an assertion wait — all assertions are
///    inspector-value polls (`waitForExistence` + value polling with refresh
///    taps), never fixed sleeps.
///
/// Absence assertions ("this database's section vanished") are anchored on
/// totals first: the inspector renders a database section only when it has
/// identities, and each fixture database publishes a known identity count, so
/// asserting `total-count` plus the surviving sections' counts accounts for
/// every identity before the swipe-through absence check runs.
///
/// ## Simulator store quirks this class is built around
///
/// 1. **The enumeration API reads empty.** On simulator runtimes (verified
///    on iOS 26.5 and 18.5) the system store accepts and persists writes,
///    but `credentialIdentities(forService:)` always returns an empty array.
///    The DEBUG + simulator seam in `SystemCredentialIdentityStore`
///    substitutes identities reconstructed from the store's backing
///    `Identities.db` when the API reads empty, so both the inspector
///    (`autofill-inspector.source` reads "fallback-db") and the app's
///    enumeration-dependent flows — targeted removal on per-database
///    disable, `populate`'s additive multi-database refresh — behave
///    device-equivalently on the harness.
/// 2. **Write-side cross-database dedup.** The simulator store collapses
///    identities sharing the same (service, user) pair across databases,
///    ignoring their record identifiers (measured: two databases publishing
///    the same 5 service/user pairs survive as 5 rows; distinct pairs
///    survive as 10). The multi-database union scenario therefore seeds
///    "bravo" from `autofill-union.kdbx`, whose domains and usernames are
///    fully disjoint from the default fixture's, so the union's counts are
///    deterministic.
@MainActor
final class AutoFillStoreUITests: AppSettingsUITestCase {

    // MARK: - Fixtures

    /// Two databases with fully disjoint service domains: the simulator's
    /// store dedups identities sharing (service, user) across databases (see
    /// the class doc), so the union scenario needs fixtures whose identities
    /// cannot collapse into each other. "alpha" is the default `test.kdbx`;
    /// "bravo" is `autofill-union.kdbx`, purpose-built with union-only
    /// domains (see `TestFixtures/README.md`). Both use the same password.
    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        [
            .init(resourceName: "test", injectedFilename: "alpha.kdbx"),
            .init(resourceName: "autofill-union", injectedFilename: "bravo.kdbx"),
        ]
    }

    /// Identities `test.kdbx` ("alpha") publishes on the iOS 18+ harness
    /// runtime: 5 password identities — Twitter → twitter.com, Discord →
    /// discord.com, Email → example.com (mail. subdomain collapses), GitHub →
    /// github.com (URL + two KP2A_URL_* fields all collapse to one registered
    /// domain), and 日本語テスト 🔑 → example.jp; "Offline Key" has no URL and
    /// "Public Profile" has no password, so neither is eligible — plus
    /// 2 one-time-code identities (Discord and GitHub carry TOTP configs).
    /// Derived from `CredentialIdentityStoreManager`'s eligibility rules;
    /// recompute if the fixture or those rules change.
    private static let alphaIdentityCount = 7

    /// Identities `autofill-union.kdbx` ("bravo") publishes: 3 password
    /// identities (unionbank-fixture.net, union-news-fixture.org,
    /// union-shop-fixture.io) plus 1 one-time-code identity (Union News
    /// carries a TOTP config). All domains and usernames are disjoint from
    /// alpha's, so no cross-database (service, user) dedup can occur.
    private static let bravoIdentityCount = 4

    private static let fixturePassword = "testpassword123"

    // MARK: - Identifiers

    private static let inspectorArgument = "-autofill-store-inspector"
    private static let enabledStateID = "autofill-inspector.enabled-state"
    private static let enumerationStateID = "autofill-inspector.enumeration-state"
    private static let totalCountID = "autofill-inspector.total-count"
    private static let refreshID = "autofill-inspector.refresh"
    private static let databaseTogglePrefix = "settings.autofill.database-toggle."

    /// UserDefaults argument-domain overrides applied to every launch so
    /// one-shot system/app overlays cannot land mid-flow on the long-lived
    /// harness device: the StoreKit review prompt (`hasPrompted` counts
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
        let enumerationAvailable: Bool
    }

    /// Cached once per test-runner process so only the first test performs the
    /// probe launch; the rest skip (or proceed) immediately.
    private static var cachedStoreProbe: StoreProbe?

    override func setUp() async throws {
        try skipUnlessProvisionedStoreIsAvailable()
        try await super.setUp()
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += Self.launchDefaultsOverrides
    }

    /// Launches the inspector (registry untouched — no `-ui-testing`), reads
    /// the store state, and skips the test unless the store is enabled with
    /// enumeration available. Conservative on indeterminate state: an
    /// unreadable inspector skips rather than fails, so this class can never
    /// break a run on an unprovisioned simulator.
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
            var result = StoreProbe(isEnabled: false, enumerationAvailable: false)
            if enabledState.waitForExistence(timeout: 30) {
                result = StoreProbe(
                    isEnabled: (enabledState.value as? String) == "enabled",
                    enumerationAvailable:
                        (inspector.staticTexts[Self.enumerationStateID].value as? String) == "available"
                )
            }
            inspector.terminate()
            Self.cachedStoreProbe = result
            probe = result
        }

        guard probe.isEnabled else {
            throw XCTSkip(
                "AutoFill store is disabled — KeeForge is not this simulator's enabled "
                    + "credential provider. Run scripts/provision-autofill-harness-sim.sh and "
                    + "target the KeeForge-AutoFill-Harness device."
            )
        }
        guard probe.enumerationAvailable else {
            throw XCTSkip("AutoFill store enumeration is unavailable on this runtime.")
        }
    }

    // MARK: - Scenario 1: publication on unlock

    func testUnlockPublishesIdentitiesForUnlockedDatabaseOnly() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        waitForInspectorValue(
            databaseCountID(ids.alpha),
            toEqual: "\(Self.alphaIdentityCount)"
        )
        // bravo was never unlocked: with all identities accounted to alpha's
        // section, bravo must have no section at all.
        assertInspectorDatabaseSectionAbsent(ids.bravo)
        assertInspectorValue(Self.enabledStateID, equals: "enabled")
    }

    // MARK: - Scenario 2: targeted removal on per-database disable

    func testDisableViaDetailsSheetEmptiesOnlyThatDatabase() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        // "With A published": verified through the inspector, not assumed.
        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        waitForInspectorValue(
            databaseCountID(ids.alpha),
            toEqual: "\(Self.alphaIdentityCount)"
        )

        // Disable while the database is locked (registry-only flip) via the
        // database-details sheet toggle.
        launchNormalRoot()
        openDatabaseDetails(rowContaining: "alpha")
        let detailsToggle = app.switches["database-details.autofill-toggle"]
        XCTAssertTrue(
            revealElement(detailsToggle, in: scrollableContainer()),
            "AutoFill toggle was not visible in the database details sheet"
        )
        setSwitch(detailsToggle, isOn: false)
        closeDatabaseDetails()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        assertInspectorDatabaseSectionAbsent(ids.alpha)
        // "Nothing else changes": the provider stays enabled and enumerable —
        // targeted removal must not degrade store availability.
        assertInspectorValue(Self.enabledStateID, equals: "enabled")
        assertInspectorValue(Self.enumerationStateID, equals: "available")
    }

    // MARK: - Scenario 3: lazy republish on re-enable

    func testReEnableStaysEmptyUntilNextUnlock() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")

        // Disable alpha, empty the store, then re-enable — all while alpha is
        // locked (no unlocked session means the enable side has nothing to
        // republish immediately). The zero state is established with the
        // confirmed Clear AutoFill Entries action rather than the disable's
        // own store-side targeted removal, keeping this test independent of
        // scenario 2's removal mechanics (which
        // testDisableViaDetailsSheetEmptiesOnlyThatDatabase pins): whatever
        // removal does, the contract under test here — re-enable publishes
        // nothing until the database's next unlock — is asserted against
        // real toggle state end to end.
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

        // Re-enable is lazy: still zero until the next unlock.
        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "0")
        assertInspectorDatabaseSectionAbsent(ids.alpha)

        // Next unlock of the same reference (same UUID — the relaunches above
        // never reseeded) republishes.
        launchNormalRoot()
        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")
        waitForInspectorValue(
            databaseCountID(ids.alpha),
            toEqual: "\(Self.alphaIdentityCount)"
        )
    }

    // MARK: - Scenario 4: Clear AutoFill Entries reaches zero

    func testClearAutoFillEntriesReachesZero() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()

        unlockDatabase(named: "alpha")
        lockVault()
        allowStoreWritesToSettle()

        // "With identities present": verified before clearing.
        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(Self.alphaIdentityCount)")

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

    // MARK: - Scenario 5: multi-database union and single-section removal

    func testMultiDatabaseUnionAndSingleSectionRemoval() throws {
        let ids = try seedStoreBaselineAndCaptureDatabaseIDs()
        let alphaCount = Self.alphaIdentityCount
        let bravoCount = Self.bravoIdentityCount

        unlockDatabase(named: "alpha")
        lockVault()
        unlockDatabase(named: "bravo")
        lockVault()
        allowStoreWritesToSettle()

        // Union: both sections present simultaneously, each with its own full
        // identity set (the second unlock must aggregate, not replace). The
        // asymmetric counts (7 vs 4) also pin that neither refresh disturbed
        // the other database's set.
        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(alphaCount + bravoCount)")
        waitForInspectorValue(databaseCountID(ids.alpha), toEqual: "\(alphaCount)")
        waitForInspectorValue(databaseCountID(ids.bravo), toEqual: "\(bravoCount)")

        // Disable bravo (locked) via the Settings per-database toggle: only
        // its section may vanish.
        launchNormalRoot()
        openAutoFillSettings()
        let bravoToggle = app.switches[Self.databaseTogglePrefix + ids.bravo]
        XCTAssertTrue(
            bravoToggle.waitForExistence(timeout: Self.ciElementTimeout),
            "Per-database toggle for the seeded bravo UUID did not survive the relaunch"
        )
        setSwitch(bravoToggle, isOn: false)
        leaveAutoFillSettings()
        allowStoreWritesToSettle()

        launchInspector()
        waitForInspectorValue(Self.totalCountID, toEqual: "\(alphaCount)")
        waitForInspectorValue(databaseCountID(ids.alpha), toEqual: "\(alphaCount)")
        assertInspectorDatabaseSectionAbsent(ids.bravo)
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

        return SeededDatabaseIDs(alpha: alphaID, bravo: bravoID)
    }

    // MARK: - Launch phases

    /// Relaunches the app without `-ui-testing` so the seeded registry (UUIDs
    /// and persisted `autoFillEnabled` flags) survives. See the class doc.
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
    /// harness device — force it on rather than assuming the default.
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
