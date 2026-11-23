import AppKit
import CoreGraphics
import ScreenCaptureKit
import XCTest

private extension CGRect {
    var area: CGFloat { width * height }
}

/// Walks the app's primary screens and attaches per-window screenshots with
/// `.keepAlways` lifetime, for visual UX auditing (screenshots from passing
/// tests are otherwise discarded). Skipped unless launched with
/// `SCREENSHOT_AUDIT=1` in the test runner environment:
///
///     TEST_RUNNER_SCREENSHOT_AUDIT=1 xcodebuild test ... \
///         -only-testing:KeeForgeMacUITests/MacScreenshotAuditUITests
///
/// Captures are light unless `TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` asks for a
/// dark-appearance pass; the host's own appearance never decides. Both
/// must be real environment variables on the `xcodebuild` process itself
/// (Xcode strips the `TEST_RUNNER_` prefix and forwards them into the test
/// runner's environment) — verified empirically, a trailing bare `KEY=value`
/// argument is a build-setting override that never reaches the runner, and
/// the class silently skips as if unset.
///
/// Then export: `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`.
///
/// The harness only ever screenshots the app's own windows. Captures come from
/// each window's own content via ScreenCaptureKit — never `XCUIElement.screenshot()`
/// or `XCUIApplication.screenshot()`, both of which capture the *screen* and hand
/// back whatever the user has in front. On macOS 26 the element variant returns
/// the windows behind the app as soon as a second app window exists, verified with
/// the app confirmed frontmost and unoccluded.
///
/// Two preconditions, both of which the harness reports rather than works around:
/// the runner needs Screen Recording permission, and the app must launch with
/// `blockScreenCapture` off (see `configureLaunch`). Without either, every capture
/// is recorded in the `00-skipped-captures` attachment instead of attaching
/// whatever happened to be underneath.
@MainActor
final class MacScreenshotAuditUITests: MacUITestCase {

    // The bundled test database under presentable names, since the database
    // list and window titles show the injected filename in listing captures.
    override var databaseFixtures: [DatabaseFixture] {
        if name.contains("EmptyDatabasesWindow") { return [] }
        // Attachments, custom fields, tags and a version that differs live only in kitchen-sink.
        if name.contains("EntryVariants") {
            return [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "Personal.kdbx")]
        }
        let local = [
            DatabaseFixture(resourceName: "test", injectedFilename: "Personal.kdbx"),
            DatabaseFixture(resourceName: "test", injectedFilename: "Work.kdbx"),
        ]
        // A registered database whose file is gone, for the recovery page.
        guard name.contains("ServerDatabases") else { return local }
        return local + [DatabaseFixture(resourceName: "test", injectedFilename: "Archive.kdbx",
                                        disposition: "documents-missing")]
    }

    private static let databaseWindowSize = NSSize(width: 1080, height: 700)

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT"] == "1" else {
            throw XCTSkip("Screenshot audit runs only with SCREENSHOT_AUDIT=1")
        }
        try await super.setUp()
    }

    override func configureLaunch(app: XCUIApplication) throws {
        // The app blocks screen capture by default (`sharingType = .none` on
        // every window), so its windows are excluded from the capture
        // composite: ScreenCaptureKit returns a blank image and a screen-region
        // capture returns whatever sits BEHIND the app. A screenshot harness has
        // to opt out of the protection it is trying to photograph.
        insertLaunchArguments(["-KeeForge.blockScreenCapture", "NO"], into: app)

        // Seed the app's own appearance preference (`@AppStorage`) so the host's
        // system appearance cannot change the captures. The app renders with
        // `preferredColorScheme`, so an OS-level `-AppleInterfaceStyle` override
        // would not reach it.
        // The phase-nine pass sets the theme in Settings instead, so the app-wide seam applies it live.
        if name.contains("PhaseNine") == false {
            insertLaunchArguments(["-KeeForge.appearanceMode", Self.auditAppearance], into: app)
        }

        insertLaunchArguments([Self.windowSizeArgument, Self.sizeValue(Self.databaseWindowSize)], into: app)
        insertLaunchArguments(["-KeeForge.macMenuBarQuickAccess", "YES"], into: app)
        // Argument-domain only: SSH Agent's database picker shows only while the agent is on.
        insertLaunchArguments(["-KeeForge.macSSHAgentEnabled", "YES"], into: app)
        if name.contains("ServerDatabases") || name.contains("PhaseNine") {
            app.launchEnvironment["UI_TEST_CLOUD_ACCOUNTS_JSON"] = Self.serverAccountsJSON
            app.launchEnvironment["UI_TEST_CLOUD_DATABASES_JSON"] = Self.serverDatabasesJSON
            app.launchEnvironment["UI_TEST_WEBDAV_PAYLOAD_JSON"] = try webDAVPayloadJSON()
        }
        if name.contains("AutoFillPicker") {
            app.launchArguments += ["-autofill-picker-harness"]
        }

        // The `results:N` overlay is a UI-test hook, not app UI.
        app.launchEnvironment["UI_TEST_HIDE_SEARCH_RESULTS_COUNT"] = "1"
    }

    private func insertLaunchArguments(_ arguments: [String], into app: XCUIApplication) {
        if let index = app.launchArguments.firstIndex(of: "-ui-testing") {
            app.launchArguments.insert(contentsOf: arguments, at: index)
        } else {
            app.launchArguments += arguments
        }
    }

    private static var auditAppearance: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT_DARK"] == "1" ? "dark" : "light"
    }

    private static let appBundleIdentifier = "com.keevault.app"
    private static let windowSizeArgument = "-ui-testing-database-window-size"

    private static func sizeValue(_ size: NSSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    // A WebDAV and an FTP row next to the local ones; nothing connects unless a row is opened.
    private static let serverAccountsJSON = """
    [{"id":"webdav-acct-1","displayName":"alex@cloud.example.com","provider":"webdav"},
     {"id":"ftp-acct-1","displayName":"ftp.example.com","provider":"ftp"}]
    """
    private static let serverDatabasesJSON = """
    [{"provider":"webdav","accountId":"webdav-acct-1","file":{"id":"/Vaults/Family.kdbx","name":"Family.kdbx",
      "path":"/Vaults/Family.kdbx","isFolder":false,"modifiedDate":"2023-11-14T22:13:20Z","size":4096}},
     {"provider":"ftp","accountId":"ftp-acct-1","file":{"id":"/backup/Archive.kdbx","name":"Archive.kdbx",
      "path":"/backup/Archive.kdbx","isFolder":false,"modifiedDate":"2023-11-14T22:13:20Z","size":4096}}]
    """

    /// Family.kdbx is the test fixture behind a mock WebDAV server whose uploads
    /// need write access, so the first save asks to reconnect.
    private func webDAVPayloadJSON(uploadError: String = "writeScopeRequired") throws -> String {
        let data = try fixtureData(resourceName: "test", resourceExtension: "kdbx")
        let payload: [String: Any] = [
            "accounts": [["id": "webdav-acct-1", "displayName": "alex@cloud.example.com", "provider": "webdav"]],
            "directories": [["path": "/", "files": [
                ["id": "/Vaults", "name": "Vaults", "path": "/Vaults", "isFolder": true],
                ["id": "/notes.txt", "name": "notes.txt", "path": "/notes.txt", "isFolder": false,
                 "modifiedDate": "2023-11-14T22:13:20Z", "size": 512],
            ]], ["path": "/Vaults", "files": [[
                "id": "/Vaults/Family.kdbx", "name": "Family.kdbx", "path": "/Vaults/Family.kdbx",
                "isFolder": false, "modifiedDate": "2023-11-14T22:13:20Z", "size": data.count,
            ]]]],
            "fileContentsByID": ["/Vaults/Family.kdbx": data.base64EncodedString()],
            "contentHashByFileID": [String: String](),
            "revByFileID": ["/Vaults/Family.kdbx": "\"etag-family\""],
            "uploadError": uploadError,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    /// PID of the running app-under-test.
    private var appProcessID: pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
            .processIdentifier
    }

    /// True when the app-under-test owns the active (menu-bar-owning)
    /// application slot. Needs no Screen Recording permission, unlike the
    /// window-list check below.
    private var isAppActiveApplication: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.appBundleIdentifier
    }

    private struct ScreenWindow {
        let pid: pid_t
        let id: CGWindowID
        let rect: CGRect
    }

    /// The on-screen, normal-layer windows the window server reports, ordered
    /// front to back.
    ///
    /// Without Screen Recording permission this list is trimmed to the caller's
    /// own windows, so the harness cannot assume it sees the whole screen.
    private func orderedScreenWindows(anyLayer: Bool = false) -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  anyLayer || (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 1, rect.height > 1 else {
                return nil
            }
            return ScreenWindow(pid: pid, id: id, rect: rect)
        }
    }

    /// The window-server record for the app window at `rect`, at any level:
    /// the quick-search panel and context menus float above normal windows.
    private func appScreenWindow(matching rect: CGRect) -> ScreenWindow? {
        guard let pid = appProcessID else { return nil }
        return orderedScreenWindows(anyLayer: true).first {
            $0.pid == pid && abs($0.rect.origin.x - rect.origin.x) < 3
                && abs($0.rect.origin.y - rect.origin.y) < 3
                && abs($0.rect.width - rect.width) < 3
                && abs($0.rect.height - rect.height) < 3
        }
    }

    /// True when the frontmost real on-screen window belongs to the app.
    private func isAppWindowFrontmost() -> Bool {
        guard let pid = appProcessID else { return false }
        guard let front = orderedScreenWindows().first(where: {
            $0.rect.width > 200 && $0.rect.height > 200
        }) else {
            return false
        }
        return front.pid == pid
    }

    /// The gate the keyboard steps go through: the app must own the active
    /// application slot *and* the frontmost real window. Captures no longer
    /// depend on it — `windowImage(id:)` does not care what is on top — but a
    /// ⌘-shortcut still has to be delivered to the right app.
    private var isAppForeground: Bool {
        isAppActiveApplication && isAppWindowFrontmost()
    }

    /// The database window the captures follow.
    private var personalWindow: XCUIElement { databaseWindow(named: "Personal") }

    /// Raises the app over other apps as forcefully as the test process can:
    /// `XCUIApplication.activate()` plus `NSRunningApplication.activate()`.
    private func forceActivateApp() {
        guard let app,
              app.state == .runningForeground || app.state == .runningBackground else {
            return
        }
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
            .activate()
        app.activate()
    }

    /// Waits until the app owns the foreground for two consecutive checks
    /// (a stable foreground, not a momentary flicker), re-activating as needed.
    ///
    /// This only raises the app so keyboard shortcuts land; captures are
    /// occlusion-independent and do not rely on it.
    @discardableResult
    private func waitForStableForeground(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            forceActivateApp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if isAppForeground {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if isAppForeground {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    return true
                }
            }
        }
        return false
    }

    /// Captures one window's own content.
    ///
    /// This is what makes the harness leak-proof by construction: the image is
    /// composited from that window alone, so no other app's pixels can enter it
    /// no matter what is on screen. `XCUIElement.screenshot()` cannot promise
    /// that — it region-captures the screen, and on macOS 26 it returns the
    /// windows *behind* the app once a second app window exists, which is how a
    /// "window" capture ends up holding the user's desktop.
    ///
    /// `nonisolated` and self-contained so no ScreenCaptureKit object crosses an
    /// actor boundary; only the `CGImage` comes back.
    private nonisolated static func windowImage(id: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                return nil
            }
            let configuration = SCStreamConfiguration()
            // `SCWindow.frame` is in points and the runner reports a
            // backingScaleFactor of 1, so ask for Retina pixels explicitly —
            // reading the screen's scale here yields half-resolution captures.
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            // Without this SCK can render the window 1:1 into the Retina-sized
            // buffer, leaving half-scale content in the corner of the image.
            configuration.scalesToFit = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch {
            return nil
        }
    }

    /// Attaches a capture of one app window, or records why it was skipped.
    /// `waitsForForeground: false` skips the foreground wait (about a second) for a state that
    /// lasts only briefly, such as the copy tick; the caller has just raised the app.
    private func snapWindow(_ window: @autoclosure () -> XCUIElement?, _ name: String, waitsForForeground: Bool = true) async {
        guard !waitsForForeground || waitForStableForeground(), let element = window(), element.exists,
              element.frame.width > 1, element.frame.height > 1 else {
            noteSkip(name, reason: "app never held the foreground")
            return
        }

        // An attached sheet has its own accessibility frame and window-server
        // record, but ScreenCaptureKit composites its pixels into the parent
        // window. Capturing the sheet record therefore renders the parent at
        // 1x into a Retina buffer sized for the sheet, leaving black padding.
        // Capture the parent window instead; the sheet remains visible in the
        // resulting image with its surrounding context.
        let captureElement: XCUIElement
        if element.elementType == .sheet, let parent = parentWindow(ofSheet: element) {
            captureElement = parent
        } else {
            captureElement = element
        }

        guard let record = appScreenWindow(matching: captureElement.frame) else {
            noteSkip(name, reason: "no window-server record for \(captureElement.frame)")
            return
        }
        guard let image = await Self.windowImage(id: record.id) else {
            noteSkip(
                name,
                reason: "window capture failed — grant Screen Recording to KeeForgeMacUITests-Runner"
            )
            return
        }

        let attachment = XCTAttachment(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func parentWindow(ofSheet sheet: XCUIElement) -> XCUIElement? {
        let frame = sheet.frame
        return app.windows.allElementsBoundByIndex.first {
            $0.sheets.count > 0 && $0.frame.intersects(frame)
        }
    }

    /// Snaps the Personal database window.
    private func snap(_ name: String) async {
        await snapWindow(personalWindow, name)
    }

    /// The app window (or attached sheet) that hosts `identifier`.
    ///
    /// Secondary surfaces are addressed by content, never by `windows.firstMatch`:
    /// that returns the main window when the surface failed to open, so the
    /// capture silently mislabels the main window as "settings" or "editor".
    private func surface(hosting identifier: String) -> XCUIElement? {
        if let sheet = app.sheets.allElementsBoundByIndex.first(where: {
            $0.exists && $0.descendants(matching: .any)[identifier].exists
        }) {
            return sheet
        }
        return (app.windows.allElementsBoundByIndex + app.dialogs.allElementsBoundByIndex).first {
            $0.descendants(matching: .any)[identifier].exists
        }
    }

    /// Snaps the app window or sheet hosting `identifier`, recording a skip when
    /// that surface never opened.
    private func snapSurface(hosting identifier: String, _ name: String) async {
        guard surface(hosting: identifier) != nil else {
            noteSkip(name, reason: "no surface hosting '\(identifier)'")
            return
        }
        await snapWindow(self.surface(hosting: identifier), name)
    }

    private var skippedCaptures: [String] = []

    private func noteSkip(_ name: String, reason: String) {
        skippedCaptures.append("\(name): \(reason)")
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Sends a ⌘-shortcut only while the app owns the foreground. Typing one
    /// blind delivers it to whatever app is actually in front — on a developer
    /// Mac that means ⌘W and ⌘, land in the user's own windows.
    @discardableResult
    private func typeAppShortcut(_ key: String) -> Bool {
        guard waitForStableForeground() else { return false }
        typeCommandShortcut(key)
        return true
    }

    func testCaptureEmptyDatabasesWindow() async {
        settle(2)
        await snapWindow(databasesWindow, "00a-databases-first-run")
        attachCaptureReport()
    }

    func testCaptureServerDatabasesInTheDatabasesWindow() async {
        settle(2)
        await snapWindow(databasesWindow, "00b-databases-with-servers")

        // 13. A WebDAV database whose save needs write access: the reconnect
        //     notice above the list and the status card's problem line.
        let name = "13-notice-reconnect"
        let window = openDatabase(named: "Family")
        unlockSuccessfully(in: window)
        // 8a2. Database Settings ▸ Sync for the WebDAV database.
        let syncName = "08a2-database-settings-sync"
        if let sheet = openDatabaseSettings(in: window, skipping: syncName) {
            if selectDatabaseSettingsTab("Sync", in: sheet) { await snapWindow(sheet, syncName) }
            else { noteSkip(syncName, reason: "a WebDAV database showed no Sync tab") }
            sheet.buttons["database-settings.done"].firstMatch.click()
            _ = sheet.waitForNonExistence(timeout: 5)
        }
        openGroup(named: "Social")
        if deleteGroup(named: "Empty", skipping: name) {
            if window.buttons["cloud-reauth-banner.reconnect"].firstMatch.waitForExistence(timeout: 15) {
                settle(0.6)
                await snapWindow(window, name)
                // 8a2b. The Sync tab while the server needs reconnecting, with the card's Reconnect.
                let reconnectName = "08a2b-database-settings-sync-reconnect"
                let saveAlertOK = window.sheets.buttons["OK"].firstMatch
                if saveAlertOK.waitForExistence(timeout: 3) { saveAlertOK.click(); settle(0.6) }
                if let sheet = openDatabaseSettings(in: window, skipping: reconnectName) {
                    if selectDatabaseSettingsTab("Sync", in: sheet) { await snapWindow(sheet, reconnectName) }
                    else { noteSkip(reconnectName, reason: "a WebDAV database showed no Sync tab") }
                    sheet.buttons["database-settings.done"].firstMatch.click()
                    _ = sheet.waitForNonExistence(timeout: 5)
                }
            } else {
                noteSkip(name, reason: "the reconnect notice never appeared")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "\(name)-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            // Quitting with the unsaved draft would ask first and stall the teardown.
            if typeAppShortcut("w") {
                let dontSave = window.sheets.buttons["Don’t Save"].firstMatch
                if dontSave.waitForExistence(timeout: 5) { dontSave.click() }
                _ = window.waitForNonExistence(timeout: 10)
            }
        }

        // 2d. A database whose file is gone: the recovery page after the password.
        let archive = openDatabase(named: "Archive")
        unlock(password: Self.fixturePassword, in: archive)
        if archive.buttons["unlock.remove-missing"].waitForExistence(timeout: 30) {
            settle()
            await snapWindow(archive, "02d-file-unavailable")
        } else {
            noteSkip("02d-file-unavailable", reason: "the missing file never reached the recovery page")
            attachHierarchy(named: "02d-file-unavailable-hierarchy")
        }
        await captureRemoteBrowser()
        noteSkip("01e-ftp-connect", reason: "the FTP form is not captured against a server")
        attachCaptureReport()
    }

    func testCaptureScreens() async {
        // 1. The Databases window
        settle(2)
        await snapWindow(databasesWindow, "01-databases")

        // 1a. Database row context menu.
        if let databaseRow = selectDatabaseRow(containing: "Personal") {
            databaseRow.rightClick()
            let rowMenu = app.menus.firstMatch
            if rowMenu.waitForExistence(timeout: 3) {
                settle(0.4)
                await snapWindow(rowMenu, "01a-database-row-menu")
            } else {
                noteSkip("01a-database-row-menu", reason: "the context menu never opened")
            }
            app.typeKey(.escape, modifierFlags: [])
            settle(0.4)
        } else {
            noteSkip("01a-database-row-menu", reason: "the database row was not hittable")
        }

        // 1b. Create New sheet on the Databases window.
        await captureLauncherSheet(
            opening: { self.databasesWindow.buttons["databases.create-new"].firstMatch.click() },
            hosting: "database-create.cancel-button",
            "01b-databases-create-new",
            then: [
                ("01b1-databases-create-advanced", { $0.buttons["database-create.advanced-options"].firstMatch.click() }),
                ("01b2-databases-create-webdav", { sheet in
                    sheet.popUpButtons["database-create.destination-picker"].firstMatch.click()
                    self.app.menuItems["WebDAV"].firstMatch.click()
                }),
                ("01b3-databases-create-advanced-closed", { $0.buttons["database-create.advanced-options"].firstMatch.click() }),
            ]
        ) {
            self.app.buttons["database-create.cancel-button"].firstMatch.click()
        }

        // 1c. The Connect to Server sheet on the Databases window, WebDAV selected.
        await captureLauncherSheet(
            opening: { self.databasesWindow.buttons["databases.connect-server"].firstMatch.click() },
            hosting: "connect-server.type",
            "01c-databases-connect-webdav"
        ) {
            self.app.buttons["webdav.connect.cancel"].firstMatch.click()
        }

        // 2. Unlock screen
        openDatabase(named: "Personal")
        settle()
        await snap("02-unlock")

        // 2a. After a wrong password: the emptied, ringed field and the failure card.
        await captureWrongPassword(in: personalWindow, "02a-unlock-wrong-password")

        // 3. Unlocked vault root (sidebar / entry table / detail)
        unlockSuccessfully(in: personalWindow)
        settle()
        await snap("03-vault-root")

        // 3b. A Library row selected in the sidebar's sections.
        clickFirstRow(identifier: "sidebar.collection.allEntries")
        settle()
        await snap("03b-sidebar-all-entries")

        // 3c. Library > Verification Codes: live code rows with their countdown rings.
        clickFirstRow(identifier: "sidebar.collection.verificationCodes")
        if app.buttons["verification-code-row.copy"].firstMatch.waitForExistence(timeout: 8) {
            settle()
            await snap("03c-verification-codes")
        } else {
            noteSkip("03c-verification-codes", reason: "no verification-code row appeared")
        }

        // 3e. Library > Passkeys: the fixture has none, so its empty state.
        clickFirstRow(identifier: "sidebar.collection.passkeys")
        if waitForDisplayText("Passkeys", identifier: "entry-list.header.title", timeout: 8) {
            settle()
            await snap("03e-passkeys")
        } else {
            noteSkip("03e-passkeys", reason: "the Passkeys list never showed")
        }

        // 4. A group with an entry selected, so all three columns have content.
        openGroup(named: "Social")
        openEntry(named: "Discord")
        settle()
        await snap("04-group-selected")

        // 4b. A native multiple selection (⌘-click) with the detail summary; Escape ends it.
        let twitter = rowQuery(identifier: "entry.navlink").matching(NSPredicate(format: "value == 'Twitter'"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 1 }
        if waitForStableForeground(), let twitter {
            XCUIElement.perform(withKeyModifiers: .command) { twitter.click() }
            if app.buttons["entry-selection.move"].firstMatch.waitForExistence(timeout: 5) {
                settle()
                await snap("04b-multi-select")
            } else {
                noteSkip("04b-multi-select", reason: "the selection summary never appeared")
            }
            app.typeKey(.escape, modifierFlags: [])
            settle(0.4)
        } else {
            noteSkip("04b-multi-select", reason: "the 'Twitter' row was not hittable")
        }

        // 5. Entry detail — entry rows live in the content column only after a
        //    group is selected.
        openGroup(named: "Work")
        let entry = rowQuery(identifier: "entry.navlink").firstMatch
        if entry.waitForExistence(timeout: 10) {
            entry.click()
            settle()
            await snap("05-entry-detail")
        }

        // NOTE ON ORDERING: the keyboard-driven captures (⌘F search, ⌘, settings)
        // come BEFORE the entry editor. A modal sheet hands the foreground back
        // to whatever app was active before the test on a shared machine, after
        // which ⌘-shortcuts no longer reach the app. Keeping the sheet last means
        // the search/settings captures run while the app still holds focus from
        // the entry clicks above.

        // 6. Search focused with results for a real fixture entry.
        if typeAppShortcut("f") {
            app.typeText("Email")
            if rowQuery(identifier: "search.entry.navlink").firstMatch.waitForExistence(timeout: 8) == false {
                noteSkip("06-search", reason: "no results appeared for \"Email\"")
            }
            settle()
            await snap("06-search")
            // Clear the search so later steps see the normal browse UI.
            clearSearchField()
            settle()
        } else {
            noteSkip("06-search", reason: "⌘F could not be delivered")
        }

        // 11. A second database window beside the first: one locked, one unlocked.
        let workWindow = openDatabase(named: "Work")
        settle()
        await snapWindow(workWindow, "11a-second-window-locked")
        await snap("11b-first-window-unlocked")
        unlockSuccessfully(in: workWindow)
        settle()

        // 7. Settings window + each tab; SSH Agent shows its database picker
        //    with both databases unlocked.
        if typeAppShortcut(",") {
            settle(1.5)
            await captureSettingsTabs()
            guard closeSettingsWindow() else {
                noteSkip("07-settings-close", reason: "the Settings window did not close")
                attachCaptureReport()
                return
            }
        } else {
            noteSkip("07-settings", reason: "⌘, could not be delivered")
        }

        // 12. The menu bar quick-search panel names the database it searches.
        await captureQuickSearchPanel()

        // Back to one database window, so the vault queries below are unambiguous.
        // The close button needs neither the menu bar nor key focus.
        waitForStableForeground()
        let closeWork = workWindow.buttons[XCUIIdentifierCloseWindow].firstMatch
        if closeWork.exists { closeWork.click() }
        if workWindow.waitForNonExistence(timeout: 10) == false {
            noteSkip("12-close-second-window", reason: "the Work window did not close")
        }
        // The Databases window, ordered above Personal when Work opened, is now in front.
        let windowMenu = app.menuBars.menuBarItems["Window"].firstMatch
        windowMenu.click()
        let personalItem = windowMenu.menuItems.matching(
            NSPredicate(format: "title == 'Personal' OR title BEGINSWITH 'Personal ('")
        ).firstMatch
        if personalItem.waitForExistence(timeout: 5) {
            personalItem.click()
        } else {
            // An open menu would stall every later step and the teardown.
            app.typeKey(.escape, modifierFlags: [])
            noteSkip("12-front-personal", reason: "the Window menu did not list Personal")
        }

        // 8. The inline editor, its generator popover, a new entry with the Set Up sheet,
        //    the discard prompt, and the Password Generator panel.
        await captureEditor()

        // 8a, 8m, 8n. Database Settings and its tabs, Change Master Key with its
        //     confirmation, and Encryption Settings.
        await captureDatabaseSettings()

        // 8o-8s. Import Passwords before a file is chosen, the group editor, New Group,
        //     Move to Group and the entry icon picker.
        await captureWorkspaceSheets()

        // 8d-8f. A group's context menu, the Recycle Bin its delete creates,
        //        and the window with the sidebar hidden.
        await captureSidebarStates()

        // 9. Back to the main window in a clean state.
        openGroup(named: "Social")
        openEntry(named: "Twitter")
        settle()
        await snap("09-final-state")

        // 10b. A read-only database's detail: no Edit, no icon picker.
        relaunch(readOnly: true, contentSize: Self.databaseWindowSize)
        settle()
        await snap("10b-read-only-detail")

        // 10e. The title's Read-Only badge explains itself in a sheet.
        let badge = personalWindow.buttons["toolbar.title.read-only"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "A read-only database's title shows no Read-Only badge")
        if badge.exists, badge.isHittable {
            badge.click()
            let ok = personalWindow.sheets.buttons["OK"].firstMatch
            if ok.waitForExistence(timeout: 5) {
                settle(0.6)
                await snap("10e-read-only-explained")
                ok.click()
                _ = ok.waitForNonExistence(timeout: 5)
            } else {
                noteSkip("10e-read-only-explained", reason: "the badge opened no explanation")
            }
        } else {
            noteSkip("10e-read-only-explained", reason: "the Read-Only badge was not hittable")
        }

        // 10. The three columns and native toolbar at the window's
        //     minimum size (900x620), where crowding and truncation show up,
        //     with the sidebar's status card showing for a read-only database.
        relaunch(readOnly: true, contentSize: Self.minimumContentSize)
        settle()
        await snap("10-minimum-width")

        // 10a. Code rows at the minimum width.
        clickFirstRow(identifier: "sidebar.collection.verificationCodes")
        if app.buttons["verification-code-row.copy"].firstMatch.waitForExistence(timeout: 8) {
            clickFirstRow(identifier: "entry.navlink")
            settle()
            await snap("10a-minimum-width-codes")
        } else {
            noteSkip("10a-minimum-width-codes", reason: "no verification-code row appeared")
        }

        // 2b, 2e. A picked key file on the form, and the failure card at the minimum size.
        relaunchLocked(contentSize: Self.databaseWindowSize, keyFile: true)
        await snap("02b-unlock-key-file")
        relaunchLocked(contentSize: Self.minimumContentSize, keyFile: false)
        await captureWrongPassword(in: personalWindow, "02e-unlock-minimum-size")
        app.launchEnvironment["UI_TEST_KEYFILE_BASE64"] = nil

        // 4a, 4c. The Save Conflict alert and the status card's problem states.
        //     Last, because it relaunches writable with a save conflict injected.
        await captureSaveConflict()

        attachCaptureReport()
    }

    /// Relaunches writable at the default size with one injected save conflict
    /// and deletes a group with an entry open. The native alert shows over the
    /// window with the status card behind it; Cancel leaves the draft unsaved,
    /// and the card's action saves it again (the conflict was injected once).
    private func captureSaveConflict() async {
        let name = "04a-save-conflict-alert"
        app.terminate()
        app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = nil
        app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "1"
        if let index = app.launchArguments.firstIndex(of: Self.windowSizeArgument) {
            app.launchArguments[index + 1] = Self.sizeValue(Self.databaseWindowSize)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        unlockSuccessfully(in: openDatabase(named: "Personal"))
        openGroup(named: "Social")
        openEntry(named: "Twitter")
        guard deleteGroup(named: "Empty", skipping: name) else { return }
        let cancel = personalWindow.buttons["save-conflict.cancel"].firstMatch
        guard cancel.waitForExistence(timeout: 10) else {
            noteSkip(name, reason: "the injected save conflict never appeared")
            return
        }
        settle(0.6)
        await snap(name)
        cancel.click()
        let problem = "04c-status-card-unsaved"
        if cancel.waitForNonExistence(timeout: 5) {
            settle(0.6)
            await snap(problem)
        } else {
            noteSkip(problem, reason: "Cancel did not dismiss the Save Conflict alert")
            app.typeKey(.escape, modifierFlags: [])
        }
        // Quitting with an unsaved draft asks first, which would stall the teardown.
        for identifier in ["database.unsaved-indicator", "save-conflict.resolve"] {
            let action = personalWindow.buttons[identifier].firstMatch
            guard action.exists, action.isHittable else { continue }
            action.click()
            let reload = personalWindow.buttons["save-conflict.reload"].firstMatch
            if reload.waitForExistence(timeout: 3) { reload.click() }
            break
        }
        let line = personalWindow.staticTexts["sidebar.status-card.line"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while displayText(of: line).hasSuffix("On This Mac") == false, Date() < deadline { settle(0.25) }
        if displayText(of: line).hasSuffix("On This Mac") == false {
            noteSkip("\(name)-cleanup", reason: "the draft stayed unsaved: \(displayText(of: line))")
        }
    }

    /// Work/Email in the inline editor (header Edit) and its generator popover, then a new entry
    /// with the Set Up sheet and the discard prompt, then Database > Password Generator.
    /// Quick Look is a system panel and is checked by the smoke suite, not captured.
    private func captureEditor() async {
        waitForStableForeground()
        openGroup(named: "Work")
        openEntry(named: "Email")
        let titleField = personalWindow.textFields["entry-edit.title-field"].firstMatch
        let cancel = personalWindow.buttons["entry-edit.cancel"].firstMatch
        let edit = personalWindow.buttons["entry-detail.edit"].firstMatch
        if edit.waitForExistence(timeout: 5), edit.isHittable {
            edit.click()
        }
        if titleField.waitForExistence(timeout: 8) {
            settle(0.6)
            await snap("08-entry-editor-inline")
            let generator = personalWindow.buttons["entry-edit.password-generator-button"].firstMatch
            let popover = app.popovers.containing(.button, identifier: "password-generator.use").firstMatch
            if generator.exists, generator.isHittable {
                generator.click()
                if popover.waitForExistence(timeout: 5) {
                    settle(0.6)
                    await snapWindow(popover, "08k-generator-popover")
                    app.typeKey(.escape, modifierFlags: [])
                    _ = popover.waitForNonExistence(timeout: 5)
                } else {
                    noteSkip("08k-generator-popover", reason: "Generate opened no popover")
                }
            } else {
                noteSkip("08k-generator-popover", reason: "the Generate button was not hittable")
            }
            if cancel.exists { cancel.click() }
            _ = titleField.waitForNonExistence(timeout: 5)
        } else {
            noteSkip("08-entry-editor-inline", reason: "the header's Edit opened no editor")
            noteSkip("08k-generator-popover", reason: "the editor never opened")
        }

        if typeAppShortcut("n"), titleField.waitForExistence(timeout: 8) {
            settle(0.6)
            await snap("08i-new-entry")
            _ = await captureTOTPSetupLink()
            titleField.click()
            app.typeText("Draft Entry")
            cancel.click()
            let discard = personalWindow.sheets.buttons["Discard Changes"].firstMatch
            if discard.waitForExistence(timeout: 5) {
                settle(0.6)
                await snap("08j-discard-changes")
                discard.click()
            } else {
                noteSkip("08j-discard-changes", reason: "Cancel on a changed entry did not ask")
                if cancel.exists { cancel.click() }
            }
            _ = titleField.waitForNonExistence(timeout: 5)
            settle()
        } else {
            noteSkip("08i-new-entry", reason: "⌘N opened no editor")
        }

        let panelName = "08l-generator-panel"
        guard waitForStableForeground() else {
            noteSkip(panelName, reason: "app never held the foreground")
            return
        }
        chooseMenuItem("Password Generator", inMenu: "Database")
        let panel = app.descendants(matching: .any).matching(identifier: "password-generator.panel").firstMatch
        if panel.waitForExistence(timeout: 5) {
            settle(0.6)
            await snapWindow(panel, panelName)
            app.typeKey(.escape, modifierFlags: [])
            _ = panel.waitForNonExistence(timeout: 5)
        } else {
            noteSkip(panelName, reason: "Database > Password Generator opened no panel")
        }
    }

    /// Detail variants from kitchen-sink: attachments, a protected custom field, tags, Large Type,
    /// the copy tick and History with differences; then the detail and the editor at the minimum width.
    func testCaptureEntryVariants() async {
        unlockSuccessfully(in: openDatabase(named: "Personal"))

        openGroup(named: "Attachments")
        openEntry(named: "Multi Attachment Entry")
        settle()
        await snap("05a-entry-detail-attachments")

        openGroup(named: "Secrets")
        openEntry(named: "Protected Custom")
        settle()
        await snap("05a2-entry-detail-custom-field")

        let largeType = personalWindow.buttons["entry.password.large-type"].firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "large-type.panel").firstMatch
        if largeType.exists, largeType.isHittable {
            largeType.click()
            if panel.waitForExistence(timeout: 5) {
                settle(0.6)
                // The panel closes when the app resigns active, so no foreground dance.
                await snapWindow(panel, "05b-large-type", waitsForForeground: false)
                app.typeKey(.escape, modifierFlags: [])
                _ = panel.waitForNonExistence(timeout: 5)
            } else {
                noteSkip("05b-large-type", reason: "Show in Large Type opened no panel")
            }
        } else {
            noteSkip("05b-large-type", reason: "the Large Type button was not hittable")
        }

        let copyName = "05c-copy-feedback"
        let copyUsername = personalWindow.buttons["entry.copy.username"].firstMatch
        if waitForStableForeground(), copyUsername.exists, copyUsername.isHittable {
            copyUsername.click()
            settle(0.2)
            await snapWindow(personalWindow, copyName, waitsForForeground: false)
        } else {
            noteSkip(copyName, reason: "the username's copy button was not hittable")
        }

        openGroup(named: "Tagged")
        openEntry(named: "Router Admin")
        settle()
        await snap("05d-entry-detail-tags")

        // Its one earlier version has another password and other notes.
        let historyName = "08b-entry-history"
        openGroup(named: "Round Trip")
        openEntry(named: "Controlled Unknowns")
        let historyLink = personalWindow.links["entry-detail.history"].firstMatch
        if historyLink.waitForExistence(timeout: 5) {
            scrollIntoView(historyLink, in: personalWindow, failing: false)
            historyLink.click()
            let done = app.buttons["entry-history.done"].firstMatch
            if done.waitForExistence(timeout: 8) {
                settle(0.6)
                await snapSurface(hosting: "entry-history.done", historyName)
                done.click()
                settle()
            } else {
                noteSkip(historyName, reason: "the History sheet never opened")
                attachHierarchy(named: "\(historyName)-hierarchy")
            }
        } else {
            noteSkip(historyName, reason: "the entry has no Earlier Versions link")
            attachHierarchy(named: "\(historyName)-hierarchy")
        }

        relaunch(readOnly: false, contentSize: Self.minimumContentSize,
                 group: "Attachments", entry: "Multi Attachment Entry")
        settle()
        await snap("10c-minimum-width-detail")
        let edit = personalWindow.buttons["entry-detail.edit"].firstMatch
        if edit.waitForExistence(timeout: 5), edit.isHittable {
            edit.click()
            if personalWindow.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) {
                settle(0.6)
                await snap("10d-minimum-width-editor")
                personalWindow.buttons["entry-edit.cancel"].firstMatch.click()
            } else {
                noteSkip("10d-minimum-width-editor", reason: "Edit opened no editor")
            }
        } else {
            noteSkip("10d-minimum-width-editor", reason: "the header's Edit was not hittable")
        }
        attachCaptureReport()
    }

    /// The Database Settings sheet (⌘I) on `window`, or nil after noting `name` skipped.
    private func openDatabaseSettings(in window: XCUIElement, skipping name: String) -> XCUIElement? {
        let sheet = window.sheets.matching(identifier: "database-settings.sheet").firstMatch
        guard typeAppShortcut("i"), sheet.waitForExistence(timeout: 8) else {
            noteSkip(name, reason: "⌘I opened no Database Settings sheet")
            return nil
        }
        return sheet
    }

    /// Clicks the Database Settings segment titled `title`.
    private func selectDatabaseSettingsTab(_ title: String, in sheet: XCUIElement) -> Bool {
        let segment = sheet.descendants(matching: .any)["database-settings.tabs"].firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch
        guard segment.waitForExistence(timeout: 3), segment.isHittable else { return false }
        segment.click()
        settle(0.6)
        return true
    }

    private func captureDatabaseSettings() async {
        let general = "08a-database-settings-general"
        let security = "08a1-database-settings-security"
        let autoFill = "08a3-database-settings-autofill"
        let backups = "08a-database-settings-backups"
        let masterKey = "08m-master-key"
        let confirm = "08m1-master-key-confirm"
        let encryption = "08n-encryption-settings"
        guard let sheet = openDatabaseSettings(in: personalWindow, skipping: general) else {
            for name in [security, autoFill, backups, masterKey, confirm, encryption] {
                noteSkip(name, reason: "Database Settings never opened")
            }
            return
        }
        // The file facts load asynchronously; the Security tab's buttons wait for them.
        _ = sheet.descendants(matching: .any)["database-details.file-format"].waitForExistence(timeout: 8)
        settle(0.6)
        await snapWindow(sheet, general)

        if selectDatabaseSettingsTab("Security", in: sheet) {
            await snapWindow(sheet, security)
            let change = sheet.buttons["database-details.change-master-key"].firstMatch
            waitUntilEnabled(change, timeout: 8)
            if change.isEnabled {
                change.click()
                let child = app.sheets.matching(identifier: "master-key.sheet").firstMatch
                if child.waitForExistence(timeout: 8) {
                    settle(0.6)
                    await snapWindow(child, masterKey)
                    await captureMasterKeyConfirmation(in: child, confirm)
                    child.buttons["master-key.cancel"].firstMatch.click()
                    _ = child.waitForNonExistence(timeout: 5)
                } else {
                    noteSkip(masterKey, reason: "Change Master Key… opened no sheet")
                    noteSkip(confirm, reason: "the master-key sheet never opened")
                }
            } else {
                noteSkip(masterKey, reason: "Change Master Key… stayed dimmed")
                noteSkip(confirm, reason: "the master-key sheet never opened")
            }
            let reencrypt = sheet.buttons["database-details.change-encryption-settings"].firstMatch
            waitUntilEnabled(reencrypt, timeout: 8)
            if reencrypt.isEnabled {
                reencrypt.click()
                let child = app.sheets.matching(identifier: "encryption-settings.sheet").firstMatch
                if child.waitForExistence(timeout: 8) {
                    settle(0.6)
                    await snapWindow(child, encryption)
                    child.buttons["encryption-settings.cancel"].firstMatch.click()
                    _ = child.waitForNonExistence(timeout: 5)
                } else {
                    noteSkip(encryption, reason: "Change Encryption Settings… opened no sheet")
                }
            } else {
                noteSkip(encryption, reason: "Change Encryption Settings… stayed dimmed")
            }
        } else {
            for name in [security, masterKey, confirm, encryption] { noteSkip(name, reason: "no Security tab") }
        }
        if selectDatabaseSettingsTab("AutoFill", in: sheet) { await snapWindow(sheet, autoFill) }
        else { noteSkip(autoFill, reason: "no AutoFill tab") }
        if selectDatabaseSettingsTab("Backups", in: sheet) { await snapWindow(sheet, backups) }
        else { noteSkip(backups, reason: "no Backups tab") }
        noteSkip("08a-export-save-panel", reason: "the system Save panel for Export Copy… is not captured")
        sheet.buttons["database-settings.done"].firstMatch.click()
        _ = sheet.waitForNonExistence(timeout: 5)
        settle(0.4)
    }

    /// Fills a valid new password, Saves, snaps the native confirmation and declines it.
    private func captureMasterKeyConfirmation(in sheet: XCUIElement, _ name: String) async {
        let fields = ["master-key.new-password-field", "master-key.confirm-password-field"].map {
            sheet.descendants(matching: .any).matching(identifier: $0).firstMatch
        }
        guard fields.allSatisfy({ $0.waitForExistence(timeout: 3) && $0.isHittable }) else {
            noteSkip(name, reason: "the new-password fields were not available")
            return
        }
        for field in fields {
            field.click()
            field.typeText("correct horse battery staple")
        }
        sheet.buttons["master-key.save"].firstMatch.click()
        let decline = app.buttons["master-key.cancel-change"].firstMatch
        guard decline.waitForExistence(timeout: 5) else {
            noteSkip(name, reason: "Save asked no confirmation")
            return
        }
        settle(0.6)
        await snapWindow(sheet, name)
        decline.click()
        _ = decline.waitForNonExistence(timeout: 5)
        noteSkip("08m-key-file-save-panel", reason: "the system Save panel for Create Key File… is not captured")
    }

    private func captureWorkspaceSheets() async {
        // 8o. File ▸ Import Passwords… before a file is chosen.
        let importName = "08o-import-no-file"
        if waitForStableForeground() {
            chooseMenuItem("Import Passwords…", inMenu: "File")
            let sheet = app.sheets.matching(identifier: "password-import.sheet").firstMatch
            if sheet.waitForExistence(timeout: 8) {
                settle(0.6)
                await snapWindow(sheet, importName)
                sheet.buttons["password-import.cancel"].firstMatch.click()
                _ = sheet.waitForNonExistence(timeout: 5)
            } else {
                noteSkip(importName, reason: "Import Passwords… opened no sheet")
            }
        } else {
            noteSkip(importName, reason: "app never held the foreground")
        }
        noteSkip("08o1-import-preview", reason: "the preview needs a CSV chosen in the system Open panel")

        // 8p. Edit Group… from Social's row menu.
        let editName = "08p-edit-group"
        if let social = rowQuery(identifier: "group.navlink").matching(NSPredicate(format: "value == 'Social'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.height > 1 }), waitForStableForeground() {
            social.rightClick()
            let edit = app.menuItems.matching(identifier: "group-row.edit-context").allElementsBoundByIndex
                .first { $0.isEnabled && $0.isHittable }
            if let edit {
                edit.click()
                await snapSheet(hosting: "group-edit.cancel", editName)
                app.buttons["group-edit.cancel"].firstMatch.click()
                settle(0.6)
            } else {
                app.typeKey(.escape, modifierFlags: [])
                noteSkip(editName, reason: "the group row menu had no Edit Group…")
            }
        } else {
            noteSkip(editName, reason: "the 'Social' group row was not available")
        }

        // 8q. File ▸ New Group.
        let newName = "08q-new-group"
        if waitForStableForeground() {
            chooseMenuItem("New Group", inMenu: "File")
            await snapSheet(hosting: "group-create.cancel", newName)
            app.buttons["group-create.cancel"].firstMatch.click()
            settle(0.6)
        } else {
            noteSkip(newName, reason: "app never held the foreground")
        }

        // 8r, 8s. Edit ▸ Move to Group… and the icon picker for Social/Twitter.
        openGroup(named: "Social")
        openEntry(named: "Twitter")
        let moveName = "08r-move-to-group"
        if waitForStableForeground() {
            chooseMenuItem("Move to Group…", inMenu: "Edit")
            await snapSheet(hosting: "move-picker.cancel", moveName)
            app.buttons["move-picker.cancel"].firstMatch.click()
            settle(0.6)
        } else {
            noteSkip(moveName, reason: "app never held the foreground")
        }
        let iconName = "08s-entry-icon-picker"
        let iconButton = personalWindow.buttons["entry-detail.icon-button"].firstMatch
        if iconButton.waitForExistence(timeout: 5), iconButton.isHittable {
            iconButton.click()
            await snapSheet(hosting: "icon-picker.use", iconName)
            app.buttons["entry-icon-picker.cancel"].firstMatch.click()
            settle(0.6)
        } else {
            noteSkip(iconName, reason: "the entry's icon button was not hittable")
        }
    }

    /// Waits for the sheet holding `identifier` and snaps it.
    private func snapSheet(hosting identifier: String, _ name: String) async {
        guard app.sheets.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 8) else {
            noteSkip(name, reason: "no sheet hosting '\(identifier)'")
            attachHierarchy(named: "\(name)-hierarchy")
            return
        }
        settle(0.6)
        await snapSurface(hosting: identifier, name)
    }

    /// 1d. Connect to Server against the mock WebDAV server, then its file browser.
    private func captureRemoteBrowser() async {
        let name = "01d-remote-browser"
        showDatabasesWindow()
        guard waitForStableForeground() else { return noteSkip(name, reason: "app never held the foreground") }
        databasesWindow.buttons["databases.connect-server"].firstMatch.click()
        let sheet = databasesWindow.sheets.firstMatch
        let fields = [("webdav.connect.server-field", "https://cloud.example.com/dav"),
                      ("webdav.connect.username-field", "alex"), ("webdav.connect.password-field", "password")]
        for (identifier, text) in fields {
            let field = sheet.descendants(matching: .any).matching(identifier: identifier).firstMatch
            guard field.waitForExistence(timeout: 8) else {
                app.typeKey(.escape, modifierFlags: [])
                return noteSkip(name, reason: "the Connect sheet has no '\(identifier)'")
            }
            field.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText(text)
        }
        sheet.buttons["webdav.connect.submit"].firstMatch.click()
        let table = databasesWindow.descendants(matching: .any)["remote-browser.table"].firstMatch
        guard table.waitForExistence(timeout: 10),
              databasesWindow.descendants(matching: .any)["cloud.browser.file.row"].firstMatch.waitForExistence(timeout: 10) else {
            noteSkip(name, reason: "the mock server's files never listed")
            attachHierarchy(named: "\(name)-hierarchy")
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        settle(0.6)
        await snapWindow(databasesWindow.sheets.firstMatch, name)
        app.typeKey(.escape, modifierFlags: [])
        settle(0.6)
    }

    /// Deletes a sidebar group through its row menu and the confirmation.
    private func deleteGroup(named group: String, skipping name: String) -> Bool {
        guard waitForStableForeground(),
              let row = rowQuery(identifier: "group.navlink").matching(NSPredicate(format: "value == %@", group))
                .allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.height > 1 }) else {
            noteSkip(name, reason: "the '\(group)' group row was not available")
            return false
        }
        row.rightClick()
        let delete = app.menuItems.matching(identifier: "group-row.delete-context").firstMatch
        guard delete.waitForExistence(timeout: 3) else {
            app.typeKey(.escape, modifierFlags: [])
            noteSkip(name, reason: "the group context menu never opened")
            return false
        }
        delete.click()
        let confirm = app.windows.sheets.buttons["workspace.delete.confirm"].firstMatch
        guard confirm.waitForExistence(timeout: 5) else {
            noteSkip(name, reason: "the delete confirmation never appeared")
            return false
        }
        confirm.click()
        return true
    }

    /// Phase 9 states: the theme set live through Settings (the app-wide seam) reaching the
    /// window, an alert, a sheet and Settings; the quick-search panel with results and locked;
    /// the minimum width with the sidebar hidden; the WebDAV upload problem states and the
    /// Discard Pending Upload alert.
    func testCapturePhaseNineStates() async {
        settle(2)
        let window = openDatabase(named: "Personal")
        unlockSuccessfully(in: window)
        openGroup(named: "Social")
        openEntry(named: "Twitter")

        let theme = Self.auditAppearance == "dark" ? "Dark" : "Light"
        if setTheme(theme) {
            await snapWindow(settingsWindow, "07i-settings-theme-set-live")
            _ = closeSettingsWindow()
            settle()
            await snap("07j-window-theme-set-live")
            await captureDeleteAlertAndSheetInTheme()
        } else {
            noteSkip("07i-settings-theme-set-live", reason: "the Theme picker did not take '\(theme)'")
        }

        await captureQuickSearchStates(in: window)

        // 10f. The minimum size with the sidebar hidden: search must stay a field.
        relaunch(readOnly: false, contentSize: Self.minimumContentSize)
        settle()
        clickToolbarButton(identifier: "sidebar.left", overflowLabel: "Hide Sidebar")
        settle()
        await snap("10f-minimum-width-sidebar-hidden")
        attachHierarchy(named: "10f-minimum-width-sidebar-hidden-hierarchy")
        clickToolbarButton(identifier: "sidebar.left", overflowLabel: "Show Sidebar")
        settle()

        // 13a-13c. WebDAV uploads that fail after the local save.
        await captureUploadProblem(uploadError: "conflict", name: "13a-upload-conflict", discardAlert: "13b-discard-pending-upload-alert")
        await captureUploadProblem(uploadError: "networkUnavailable", name: "13c-upload-offline", discardAlert: nil)

        // Leave the stored theme as a fresh install has it, for the suites that follow.
        relaunch(readOnly: false, contentSize: Self.databaseWindowSize)
        _ = setTheme("System Default")
        _ = closeSettingsWindow()
        noteSkip("13d-reconnect-cached", reason: "the mock provider cannot turn a downloaded copy disconnected within one launch")
        noteSkip("10g-read-only-pill-240", reason: "XCUITest drags do not move split dividers on macOS 27")
        noteSkip("03f-empty-tag-bin-new-database", reason: "no fixture has an empty tag or an empty bin section; a new database needs a save panel")
        attachCaptureReport()
    }

    /// Picks a Theme in Settings ▸ Appearance; the seam applies it to every window at once.
    private func setTheme(_ title: String) -> Bool {
        guard typeAppShortcut(",") else { return false }
        settle(1.5)
        guard selectSettingsTab(named: "Appearance") else { return false }
        // The picker's radio group is only its accessibility representation; a click on it reaches
        // no button, so click the thumbnail itself (84 pt wide, 12 pt apart, 54 pt tall).
        let picker = settingsWindow.descendants(matching: .any)["settings.display.theme-picker"].firstMatch
        guard let index = ["System Default", "Light", "Dark"].firstIndex(of: title),
              picker.waitForExistence(timeout: 5) else {
            attachHierarchy(named: "07i-theme-picker-hierarchy")
            return false
        }
        picker.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 42 + 96 * index, dy: 27)).click()
        settle()
        return true
    }

    private func captureDeleteAlertAndSheetInTheme() async {
        let alertName = "07k-alert-theme-set-live"
        if let row = rowQuery(identifier: "group.navlink").matching(NSPredicate(format: "value == 'Empty'"))
            .allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.height > 1 }) {
            row.rightClick()
            let delete = app.menuItems.matching(identifier: "group-row.delete-context").firstMatch
            if delete.waitForExistence(timeout: 3) {
                delete.click()
                let cancel = personalWindow.sheets.buttons["workspace.delete.cancel"].firstMatch
                if cancel.waitForExistence(timeout: 5) {
                    settle(0.6)
                    await snap(alertName)
                    cancel.click()
                    _ = cancel.waitForNonExistence(timeout: 5)
                } else {
                    noteSkip(alertName, reason: "the delete confirmation never appeared")
                }
            } else {
                app.typeKey(.escape, modifierFlags: [])
                noteSkip(alertName, reason: "the group context menu never opened")
            }
        } else {
            noteSkip(alertName, reason: "the 'Empty' group row was not available")
        }
        let sheetName = "07l-sheet-theme-set-live"
        if let sheet = openDatabaseSettings(in: personalWindow, skipping: sheetName) {
            settle(0.6)
            await snapWindow(sheet, sheetName)
            sheet.buttons["database-settings.done"].firstMatch.click()
            _ = sheet.waitForNonExistence(timeout: 5)
        }
    }

    private func captureQuickSearchStates(in window: XCUIElement) async {
        let statusItem = app.statusItems["menu-bar.quick-search.status-item"].firstMatch
        let panel = app.dialogs["quick-search.panel"].firstMatch
        func open(_ name: String) -> Bool {
            guard statusItem.waitForExistence(timeout: 5) else {
                noteSkip(name, reason: "the menu bar item did not appear")
                return false
            }
            statusItem.click()
            guard panel.waitForExistence(timeout: 5) else {
                noteSkip(name, reason: "the panel did not open")
                return false
            }
            return true
        }
        let results = "12a-quick-search-results"
        if open(results) {
            let field = panel.textFields["quick-search.field"].firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText("o")
                _ = panel.staticTexts["quick-search.result-count"].waitForExistence(timeout: 5)
                // The selected row shows its copy pills.
                app.typeKey(.downArrow, modifierFlags: [])
                settle(0.6)
                await snapWindow(panel, results)
            } else {
                noteSkip(results, reason: "the unlocked panel offered no search field")
            }
            app.typeKey(.escape, modifierFlags: [])
            _ = panel.waitForNonExistence(timeout: 5)
        }
        let locked = "12b-quick-search-locked"
        guard typeAppShortcut("l"), waitForLockedState(in: window) else {
            noteSkip(locked, reason: "⌘L did not lock Personal")
            return
        }
        if open(locked) {
            settle(0.6)
            await snapWindow(panel, locked)
            app.typeKey(.escape, modifierFlags: [])
            _ = panel.waitForNonExistence(timeout: 5)
        }
        unlockSuccessfully(in: window)
    }

    /// Relaunches with the mock WebDAV server failing uploads with `uploadError`, deletes a
    /// group in Family so the local save succeeds and the upload does not, and snaps the
    /// status card and notice; optionally the window's Discard Pending Upload alert.
    private func captureUploadProblem(uploadError: String, name: String, discardAlert: String?) async {
        app.terminate()
        app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = nil
        app.launchEnvironment["UI_TEST_WEBDAV_PAYLOAD_JSON"] = try? webDAVPayloadJSON(uploadError: uploadError)
        if let index = app.launchArguments.firstIndex(of: Self.windowSizeArgument) {
            app.launchArguments[index + 1] = Self.sizeValue(Self.databaseWindowSize)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let window = openDatabase(named: "Family")
        unlockSuccessfully(in: window)
        openGroup(named: "Social")
        guard deleteGroup(named: "Empty", skipping: name) else { return }
        // The failed save first raises its alert (Save Conflict or Couldn't Save Database).
        let alertButton = window.sheets.buttons.matching(
            NSPredicate(format: "identifier == 'save-conflict.cancel' OR title == 'OK'")
        ).firstMatch
        if alertButton.waitForExistence(timeout: 15) {
            settle(0.6)
            await snapWindow(window, "\(name)-alert")
            alertButton.click()
            _ = alertButton.waitForNonExistence(timeout: 5)
        } else {
            noteSkip("\(name)-alert", reason: "the failed upload raised no alert")
        }
        settle(1.5)
        await snapWindow(window, name)
        if let discardAlert {
            let databaseMenu = app.menuBars.menuBarItems["Database"].firstMatch
            databaseMenu.click()
            let discard = databaseMenu.menuItems["Discard Pending Upload…"].firstMatch
            if discard.waitForExistence(timeout: 5), discard.isEnabled {
                discard.click()
                let cancel = window.sheets.buttons["Cancel"].firstMatch
                if cancel.waitForExistence(timeout: 5) {
                    settle(0.6)
                    await snapWindow(window, discardAlert)
                    cancel.click()
                    _ = cancel.waitForNonExistence(timeout: 5)
                } else {
                    noteSkip(discardAlert, reason: "Discard Pending Upload… showed no alert")
                }
            } else {
                app.typeKey(.escape, modifierFlags: [])
                noteSkip(discardAlert, reason: "Discard Pending Upload… was dimmed after a failed upload")
            }
        }
        // Closing with unsaved work asks first, which would stall the next relaunch.
        if typeAppShortcut("w") {
            let dontSave = window.sheets.buttons["Don’t Save"].firstMatch
            if dontSave.waitForExistence(timeout: 5) { dontSave.click() }
            _ = window.waitForNonExistence(timeout: 10)
        }
    }

    /// The Mac AutoFill picker in its DEBUG harness: possible matches for the request,
    /// search results with the field focused, an empty search, then exact matches.
    func testCaptureAutoFillPicker() async {
        let field = app.textFields["autofill.search-field"].firstMatch
        guard field.waitForExistence(timeout: 15) else {
            noteSkip("14-autofill-picker", reason: "the harness showed no picker")
            attachCaptureReport()
            return
        }
        settle()
        await snapSurface(hosting: "autofill.search-field", "14b-autofill-possible-matches")
        field.click()
        field.typeText("Ba")
        settle(0.6)
        await snapSurface(hosting: "autofill.search-field", "14d-autofill-search-focused")
        field.typeText("zzz")
        settle(0.6)
        await snapSurface(hosting: "autofill.search-field", "14c-autofill-empty")

        app.terminate()
        app.launchArguments += ["-autofill-picker-store"]
        app.launchEnvironment["UI_TEST_AUTOFILL_HARNESS_SEARCH"] = nil
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        if field.waitForExistence(timeout: 15) {
            settle()
            await snapSurface(hosting: "autofill.search-field", "14a-autofill-matches")
        } else {
            noteSkip("14a-autofill-matches", reason: "the store harness showed no picker")
        }
        attachCaptureReport()
    }

    func testCaptureTOTPSetupLink() async {
        unlockSuccessfully(in: openDatabase(named: "Personal"))
        guard typeAppShortcut("n"),
              personalWindow.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) else {
            XCTFail("The entry editor did not open")
            return
        }
        settle(0.6)
        let captured = await captureTOTPSetupLink()
        attachCaptureReport()
        XCTAssertTrue(captured, "The Set Up sheet was not captured in both states")
        let cancel = personalWindow.buttons["entry-edit.cancel"].firstMatch
        if cancel.exists, cancel.isHittable { cancel.click() }
    }

    /// The Set Up sheet over the inline editor, empty and then with a link it refuses.
    private func captureTOTPSetupLink() async -> Bool {
        let name = "08c-totp-setup-link"
        func fail(_ reason: String) -> Bool {
            noteSkip(name, reason: reason)
            attachHierarchy(named: "\(name)-hierarchy")
            return false
        }
        let setUp = personalWindow.buttons["entry-edit.totp.enter-link"].firstMatch
        guard setUp.waitForExistence(timeout: 5), scrollIntoView(setUp, in: personalWindow, failing: false) else {
            return fail("the Set Up… button was not visible")
        }
        setUp.click()
        let sheet = personalWindow.sheets.firstMatch
        let linkField = sheet.textViews["entry-edit.totp.link-field"].firstMatch
        guard linkField.waitForExistence(timeout: 5) else { return fail("the Set Up sheet never opened") }
        settle(0.3)
        await snapWindow(sheet, "\(name)-empty")
        linkField.click()
        // Long enough to wrap in the field, so the capture shows how a pasted link sits.
        linkField.typeText("otpauth://totp/Example:alice@example.com?issuer=Example&algorithm=SHA1&digits=6&period=30")
        let apply = sheet.buttons["entry-edit.totp.link-apply"].firstMatch
        guard apply.exists, apply.isEnabled else { return fail("the Set Up sheet's Apply button was unavailable") }
        apply.click()
        guard sheet.descendants(matching: .any)["entry-edit.totp.link-error"].waitForExistence(timeout: 5) else {
            return fail("the setup-link validation error never appeared")
        }
        settle(0.3)
        await snapWindow(sheet, name)
        let cancel = sheet.buttons["entry-edit.totp.link-cancel"].firstMatch
        guard cancel.exists else { return fail("the Set Up sheet's Cancel button was unavailable") }
        cancel.click()
        _ = sheet.waitForNonExistence(timeout: 5)
        settle(0.3)
        return skippedCaptures.contains(where: { $0.hasPrefix(name) }) == false
    }

    private func attachHierarchy(named name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let minimumContentSize = NSSize(width: 900, height: 620)

    /// Relaunches with Personal's window at `contentSize` (corner drags do not resize windows on
    /// macOS 27), unlocks it and opens `entry` in `group`.
    private func relaunch(readOnly: Bool, contentSize: NSSize, group: String = "Social", entry: String = "Twitter") {
        let size = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        ).size
        app.terminate()
        app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = readOnly ? "1" : nil
        if let index = app.launchArguments.firstIndex(of: Self.windowSizeArgument) {
            app.launchArguments[index + 1] = Self.sizeValue(contentSize)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        unlockSuccessfully(in: openDatabase(named: "Personal"))
        openGroup(named: group)
        openEntry(named: entry)
        XCTAssertEqual(personalWindow.frame.width, size.width, accuracy: 2)
        XCTAssertEqual(personalWindow.frame.height, size.height, accuracy: 2)
    }

    /// Relaunches writable with Personal's window at `contentSize`, left on its unlock page;
    /// `keyFile` seeds the form with `demo-keyfile.key` as if picked.
    private func relaunchLocked(contentSize: NSSize, keyFile: Bool) {
        app.terminate()
        app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = nil
        app.launchEnvironment["UI_TEST_KEYFILE_BASE64"] = keyFile
            ? (try? fixtureData(resourceName: "demo-keyfile", resourceExtension: "key"))?.base64EncodedString()
            : nil
        app.launchEnvironment["UI_TEST_KEYFILE_FILENAME"] = keyFile ? "personal.keyx" : nil
        if let index = app.launchArguments.firstIndex(of: Self.windowSizeArgument) {
            app.launchArguments[index + 1] = Self.sizeValue(contentSize)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        openDatabase(named: "Personal")
        settle()
    }

    /// Submits a wrong password from the focused field and snaps the failure card.
    private func captureWrongPassword(in window: XCUIElement, _ name: String) async {
        let field = window.secureTextFields["unlock.password.field"]
        guard waitForKeyboardFocus(field, timeout: 5) else {
            noteSkip(name, reason: "the password field never had focus")
            return
        }
        app.typeText("not-the-password")
        app.typeKey(.return, modifierFlags: [])
        guard window.descendants(matching: .any)["unlock.error.card"].waitForExistence(timeout: 30) else {
            noteSkip(name, reason: "the wrong password showed no failure card")
            return
        }
        settle()
        await snapWindow(window, name)
    }

    private func captureSidebarStates() async {
        let menuName = "08d-group-context-menu"
        let binName = "08e-recycle-bin-selected"

        // 8h. An entry's row menu; its Delete fills the bin's Deleted Entries.
        let rowMenuName = "08h-entry-row-menu"
        openGroup(named: "Social")
        let profile = rowQuery(identifier: "entry.navlink").matching(NSPredicate(format: "value == 'Public Profile'"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 1 }
        if waitForStableForeground(), let profile {
            profile.rightClick()
            let delete = app.menuItems.matching(identifier: "entry-row.delete-context").firstMatch
            if delete.waitForExistence(timeout: 3) {
                settle(0.4)
                await snapWindow(app.menus.containing(.menuItem, identifier: "entry-row.delete-context").firstMatch, rowMenuName)
                delete.click()
                let confirm = personalWindow.sheets.buttons["workspace.delete.confirm"].firstMatch
                if confirm.waitForExistence(timeout: 5) { confirm.click() }
                waitUntilEnabled(personalWindow.searchFields.firstMatch, timeout: 15)
            } else {
                noteSkip(rowMenuName, reason: "the entry row menu never opened")
                app.typeKey(.escape, modifierFlags: [])
            }
        } else {
            noteSkip(rowMenuName, reason: "the 'Public Profile' row was not available")
        }

        let emptyGroup = rowQuery(identifier: "group.navlink").matching(NSPredicate(format: "value == 'Empty'"))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 1 }
        if waitForStableForeground(), let emptyGroup {
            // The entry column's empty state, before the group is deleted.
            emptyGroup.click()
            settle()
            await snap("03d-empty-group")
            emptyGroup.rightClick()
            let delete = app.menuItems.matching(identifier: "group-row.delete-context").firstMatch
            if delete.waitForExistence(timeout: 3) {
                settle(0.4)
                await snapWindow(app.menus.containing(.menuItem, identifier: "group-row.delete-context").firstMatch, menuName)
                delete.click()
                let confirm = personalWindow.sheets.buttons["workspace.delete.confirm"].firstMatch
                if confirm.waitForExistence(timeout: 5) {
                    settle(0.6)
                    await snap("08t-delete-group-alert")
                    confirm.click()
                    // The bin's own row is Deleted Entries, under the Recycle Bin header.
                    openGroup(named: "Deleted Entries")
                    settle()
                    await snap(binName)
                } else {
                    noteSkip(binName, reason: "the delete confirmation never appeared")
                }
            } else {
                noteSkip(menuName, reason: "the group context menu never opened")
                noteSkip(binName, reason: "no group was deleted")
                app.typeKey(.escape, modifierFlags: [])
            }
        } else {
            noteSkip("03d-empty-group", reason: "the app or the 'Empty' group row was not available")
            noteSkip(menuName, reason: "the app or the 'Empty' group row was not available")
            noteSkip(binName, reason: "no group was deleted")
        }

        // 8g. A folded sidebar section.
        let foldName = "08g-sidebar-section-folded"
        // The chevron reads Hide or Show; Library's is in the outline's first row.
        let outline = personalWindow.outlines[Self.sidebarOutlineIdentifier]
        let libraryChevron = outline.outlineRows.element(boundBy: 0).buttons.firstMatch
        if libraryChevron.waitForExistence(timeout: 3), libraryChevron.isHittable {
            libraryChevron.click()
            settle()
            await snap(foldName)
            libraryChevron.click()
            settle(0.4)
        } else {
            noteSkip(foldName, reason: "the Library header has no chevron")
            let hierarchy = XCTAttachment(string: personalWindow.debugDescription)
            hierarchy.name = "\(foldName)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }

        clickToolbarButton(identifier: "sidebar.left", overflowLabel: "Hide Sidebar")
        settle()
        await snap("08f-sidebar-hidden")
        clickToolbarButton(identifier: "sidebar.left", overflowLabel: "Show Sidebar")
        settle()
    }

    /// Opens a sheet on the Databases window, snaps it, and closes it.
    private func captureLauncherSheet(
        opening open: () -> Void,
        hosting identifier: String?,
        _ name: String,
        then steps: [(name: String, step: (XCUIElement) -> Void)] = [],
        closing close: () -> Void
    ) async {
        guard waitForStableForeground() else {
            noteSkip(name, reason: "app never held the foreground")
            return
        }
        open()
        let sheet = databasesWindow.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 8),
              identifier.map({ sheet.descendants(matching: .any)[$0].waitForExistence(timeout: 5) }) ?? true else {
            noteSkip(name, reason: "the sheet never opened on the Databases window")
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        settle(0.6)
        await snapWindow(sheet, name)
        for (stepName, step) in steps {
            step(sheet)
            settle(0.6)
            await snapWindow(sheet, stepName)
        }
        close()
        if sheet.waitForNonExistence(timeout: 5) == false {
            app.typeKey(.escape, modifierFlags: [])
        }
        settle(0.4)
    }

    private func captureQuickSearchPanel() async {
        let name = "12-quick-search-panel"
        let statusItem = app.statusItems["menu-bar.quick-search.status-item"].firstMatch
        guard statusItem.waitForExistence(timeout: 5) else {
            noteSkip(name, reason: "the menu bar item did not appear")
            return
        }
        statusItem.click()
        let panel = app.dialogs["quick-search.panel"].firstMatch
        guard panel.waitForExistence(timeout: 5),
              panel.descendants(matching: .any)["quick-search.database-name"].waitForExistence(timeout: 5) else {
            noteSkip(name, reason: "the panel did not show its database caption")
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        settle(0.6)
        await snapWindow(panel, name)
        app.typeKey(.escape, modifierFlags: [])
        _ = panel.waitForNonExistence(timeout: 5)
        settle(0.4)
        if isAppActiveApplication == false {
            noteSkip("12-focus-after-quick-search", reason: "KeeForge was not the active app after Escape closed the panel")
        }
    }

    /// Records which captures were skipped, so a short export is obviously a
    /// harness/foreground problem rather than a screen that does not exist.
    private func attachCaptureReport() {
        guard skippedCaptures.isEmpty == false else { return }
        let report = skippedCaptures.joined(separator: "\n")
        print("SCREENSHOT AUDIT — skipped captures:\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "00-skipped-captures"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clearSearchField() {
        let searchField = app.searchFields.firstMatch
        if searchField.exists, searchField.isHittable {
            searchField.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
        }
    }

    private func captureSettingsTabs() async {
        let tabs = [
            ("General", "settings.tab.general", "07c-settings-general"),
            ("Security", "settings.tab.security", "07a-settings-security"),
            ("AutoFill", "settings.tab.autofill", "07b-settings-autofill"),
            ("Quick Search", "settings.tab.quick-search", "07f-settings-quick-search"),
            ("SSH Agent", "settings.tab.ssh-agent", "07g-settings-ssh-agent"),
            ("Browsers", "settings.tab.browsers", "07m-settings-browsers"),
            ("Appearance", "settings.tab.appearance", "07h-settings-appearance"),
            ("Servers", "settings.tab.servers", "07d-settings-servers"),
            ("About", "settings.tab.about", "07e-settings-about"),
        ]

        let settingsWindow = self.settingsWindow
        guard settingsWindow.waitForExistence(timeout: 5) else {
            for (title, _, name) in tabs {
                noteSkip(name, reason: "Settings window missing before selecting '\(title)'")
            }
            return
        }
        // A fresh Settings window, as it first opens.
        await snapWindow(settingsWindow, "07-settings")

        for (title, contentIdentifier, name) in tabs {
            guard selectSettingsTab(named: title) else { continue }
            settle(0.6)
            guard surface(hosting: contentIdentifier) != nil else {
                noteSkip(name, reason: "settings tab '\(title)' did not reveal its content")
                continue
            }
            await snapSurface(hosting: contentIdentifier, name)
            if contentIdentifier == "settings.tab.security" {
                // 7a1. A caption's caveat behind its help button.
                let helpName = "07a1-settings-security-clipboard-help"
                let help = settingsWindow.descendants(matching: .any)["settings.security.clipboard.help"].firstMatch
                let popover = app.popovers.firstMatch
                if help.waitForExistence(timeout: 3) {
                    help.click()
                    if popover.waitForExistence(timeout: 3) {
                        settle(0.4)
                        await snapWindow(popover, helpName)
                    } else {
                        noteSkip(helpName, reason: "the help popover never opened")
                    }
                    app.typeKey(.escape, modifierFlags: [])
                    _ = popover.waitForNonExistence(timeout: 3)
                } else {
                    noteSkip(helpName, reason: "the clipboard row has no help button")
                }
            }
        }
    }

    /// Closes the Settings window through its standard traffic-light control.
    /// Activating the app before sending ⌘W can raise the main window instead,
    /// leaving Settings open to interrupt the later sheet interactions.
    private func closeSettingsWindow() -> Bool {
        let settingsWindow = self.settingsWindow
        guard settingsWindow.exists else { return true }

        settingsWindow.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 16, dy: 16))
            .click()
        return settingsWindow.waitForNonExistence(timeout: 5)
    }
}
