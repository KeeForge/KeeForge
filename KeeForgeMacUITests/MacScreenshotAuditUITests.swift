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
        return [
            DatabaseFixture(resourceName: "test", injectedFilename: "Personal.kdbx"),
            DatabaseFixture(resourceName: "test", injectedFilename: "Work.kdbx"),
        ]
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
        let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT_DARK"] == "1" ? "dark" : "light"
        insertLaunchArguments(["-KeeForge.appearanceMode", appearance], into: app)

        insertLaunchArguments([Self.windowSizeArgument, Self.sizeValue(Self.databaseWindowSize)], into: app)
        insertLaunchArguments(["-KeeForge.macMenuBarQuickAccess", "YES"], into: app)
        // Argument-domain only: SSH Agent's database picker shows only while the agent is on.
        insertLaunchArguments(["-KeeForge.macSSHAgentEnabled", "YES"], into: app)
        if name.contains("ServerDatabases") {
            app.launchEnvironment["UI_TEST_CLOUD_ACCOUNTS_JSON"] = Self.serverAccountsJSON
            app.launchEnvironment["UI_TEST_CLOUD_DATABASES_JSON"] = Self.serverDatabasesJSON
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
    private func snapWindow(_ window: @autoclosure () -> XCUIElement?, _ name: String) async {
        guard waitForStableForeground(), let element = window(), element.exists,
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
            "01b-databases-create-new"
        ) {
            self.app.buttons["database-create.cancel-button"].firstMatch.click()
        }

        // 1c. Connect to Server > WebDAV sheet on the Databases window.
        await captureLauncherSheet(
            opening: {
                self.databasesWindow.descendants(matching: .any)["databases.connect-server"].firstMatch.click()
                let webDAV = self.app.menuItems["database.add.webdav"].firstMatch
                if webDAV.waitForExistence(timeout: 3) { webDAV.click() }
            },
            hosting: nil,
            "01c-databases-connect-webdav"
        ) {
            self.app.typeKey(.escape, modifierFlags: [])
        }

        // 2. Unlock screen
        openDatabase(named: "Personal")
        settle()
        await snap("02-unlock")

        // 3. Unlocked vault root (three-column: groups / entries / detail)
        unlockSuccessfully(in: personalWindow)
        settle()
        await snap("03-vault-root")

        // 4. A group with an entry selected, so all three columns have content.
        openGroup(named: "Social")
        openEntry(named: "Discord")
        settle()
        await snap("04-group-selected")

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

        // 8. Entry edit sheet (⌘N) — last, because presenting/dismissing it can
        //    drop the app out of the foreground. Best effort: re-focus an entry,
        //    open the editor, snap the sheet, then cancel.
        waitForStableForeground()
        let editorEntry = rowQuery(identifier: "entry.navlink").firstMatch
        if editorEntry.waitForExistence(timeout: 5), editorEntry.isHittable {
            editorEntry.click()
        }
        if typeAppShortcut("n"), app.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) {
            settle(0.6)
            await snapSurface(hosting: "entry-edit.title-field", "08-entry-editor-sheet")
            _ = await captureTOTPSetupLink()
            let cancelButton = app.buttons["entry-edit.cancel"].firstMatch
            if cancelButton.waitForExistence(timeout: 3), cancelButton.isHittable {
                cancelButton.click()
            }
            settle()
        } else {
            noteSkip("08-entry-editor-sheet", reason: "the editor never opened")
        }

        // 8a. Database details sheet — the tallest form the app sheets, and the
        //     one where a sheet taller than the window shows first.
        let detailsButton = app.buttons["database-details.button"].firstMatch
        if detailsButton.waitForExistence(timeout: 5), detailsButton.isHittable {
            detailsButton.click()
            if app.buttons["database-details.close"].waitForExistence(timeout: 8) {
                settle(0.6)
                await snapSurface(hosting: "database-details.close", "08a-database-details")
                let backupsLink = app.descendants(matching: .any)["database-details.backups.link"].firstMatch
                if backupsLink.waitForExistence(timeout: 3), backupsLink.isHittable {
                    backupsLink.click()
                    if app.descendants(matching: .any)["database-details.export-copy"].waitForExistence(timeout: 5) {
                        settle(0.6)
                        await snapSurface(hosting: "database-details.export-copy", "08a-database-details-backups-export")
                    } else {
                        noteSkip("08a-database-details-backups-export", reason: "the Backups & Export page never opened")
                    }
                } else {
                    noteSkip("08a-database-details-backups-export", reason: "the Backups & Export row was not hittable")
                }
                // Only the hub has Close; Escape pops the pushed page first.
                let closeButton = app.buttons["database-details.close"].firstMatch
                if !closeButton.waitForExistence(timeout: 1) {
                    app.typeKey(.escape, modifierFlags: [])
                    settle(0.6)
                }
                if closeButton.waitForExistence(timeout: 3) {
                    closeButton.click()
                } else {
                    app.typeKey(.escape, modifierFlags: [])
                }
                settle()
            } else {
                noteSkip("08a-database-details", reason: "the details sheet never opened")
            }
        } else {
            noteSkip("08a-database-details", reason: "the details toolbar button was not hittable")
        }

        // 8b. Entry history browser — the Mac shell is a versions/detail split
        //     rather than the iOS push, so it is its own screen to eyeball.
        //     Needs a fixture entry that ships stored versions.
        openGroup(named: "Social")
        openEntry(named: "Twitter")
        let historyRow = app.buttons["entry-detail.history"].firstMatch
        if historyRow.waitForExistence(timeout: 5), historyRow.isHittable {
            historyRow.click()
            if app.buttons["entry-history.done"].waitForExistence(timeout: 8) {
                settle(0.6)
                await snapSurface(hosting: "entry-history.done", "08b-entry-history")
                app.buttons["entry-history.done"].firstMatch.click()
                settle()
            } else {
                noteSkip("08b-entry-history", reason: "the history sheet never opened")
            }
        } else {
            noteSkip("08b-entry-history", reason: "the history row was not hittable")
        }

        // 9. Back to the main window in a clean state.
        await snap("09-final-state")

        // 10. The three columns and native toolbar at the window's
        //     minimum size (900x620), where crowding and truncation show up.
        shrinkMainWindowToMinimum()
        settle()
        await snap("10-minimum-width")

        attachCaptureReport()
    }

    func testCaptureTOTPSetupLink() async {
        unlockSuccessfully(in: openDatabase(named: "Personal"))
        guard typeAppShortcut("n"),
              app.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) else {
            XCTFail("The entry editor did not open")
            return
        }
        settle(0.6)
        let captured = await captureTOTPSetupLink()
        attachCaptureReport()
        XCTAssertTrue(captured, "The TOTP setup-link form was not captured in both states")
        if let editor = surface(hosting: "entry-edit.title-field"),
           let cancel = visibleControl(editor.buttons.matching(identifier: "entry-edit.cancel"), in: editor) {
            cancel.click()
        }
    }

    private func visibleControl(_ query: XCUIElementQuery, in surface: XCUIElement) -> XCUIElement? {
        query.allElementsBoundByIndex.first { element in
            let frame = element.frame
            return frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width > 1 && frame.height > 1
                && surface.frame.contains(frame) && element.isHittable
        }
    }

    private func captureTOTPSetupLink() async -> Bool {
        let name = "08c-totp-setup-link"
        func fail(_ reason: String) -> Bool {
            noteSkip(name, reason: reason)
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "\(name)-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            return false
        }
        guard let editor = surface(hosting: "entry-edit.title-field") else {
            return fail("the editor surface was missing")
        }
        guard let scrollView = visibleControl(editor.scrollViews, in: editor) else {
            return fail("the editor scroll view was not visible")
        }
        var setupLink = visibleControl(editor.buttons.matching(identifier: "entry-edit.totp.enter-link"), in: scrollView)
        var scrollDelta: CGFloat = 300
        for _ in 0..<6 {
            if setupLink != nil { break }
            let previousY = editor.buttons["entry-edit.totp.enter-link"].frame.minY
            scrollView.scroll(byDeltaX: 0, deltaY: scrollDelta)
            settle(0.3)
            setupLink = visibleControl(editor.buttons.matching(identifier: "entry-edit.totp.enter-link"), in: scrollView)
            if setupLink == nil, editor.buttons["entry-edit.totp.enter-link"].frame.minY >= previousY {
                scrollDelta = -scrollDelta
            }
        }
        guard let setupLink else { return fail("the setup-link button was not visible after scrolling") }
        setupLink.click()
        guard app.textFields["entry-edit.totp.link-field"].waitForExistence(timeout: 5),
              surface(hosting: "entry-edit.totp.link-field") != nil else {
            return fail("the setup-link sheet never opened")
        }
        settle(0.3)
        await snapSurface(hosting: "entry-edit.totp.link-field", "\(name)-empty")
        guard let linkSheet = surface(hosting: "entry-edit.totp.link-field"),
              let linkField = visibleControl(linkSheet.textFields.matching(identifier: "entry-edit.totp.link-field"), in: linkSheet) else {
            return fail("the setup-link field was not visible")
        }
        linkField.click()
        // Long enough to outgrow the row, so the pair of captures shows whether
        // the field keeps its place once it has a pasted-length value.
        linkField.typeText("otpauth://totp/Example:alice@example.com?issuer=Example&algorithm=SHA1&digits=6&period=30")
        guard let apply = visibleControl(linkSheet.buttons.matching(identifier: "entry-edit.totp.link-apply"), in: linkSheet),
              apply.isEnabled else { return fail("the setup-link Apply button was unavailable") }
        apply.click()
        guard linkSheet.staticTexts["entry-edit.totp.link-error"].waitForExistence(timeout: 5) else {
            return fail("the setup-link validation error never appeared")
        }
        settle(0.3)
        await snapSurface(hosting: "entry-edit.totp.link-field", name)
        guard let cancel = visibleControl(linkSheet.buttons.matching(identifier: "entry-edit.totp.link-cancel"), in: linkSheet) else {
            return fail("the setup-link Cancel button was unavailable")
        }
        cancel.click()
        settle(0.3)
        return skippedCaptures.contains(where: { $0.hasPrefix(name) }) == false
    }

    private func shrinkMainWindowToMinimum() {
        // Corner drags do not resize windows on macOS 27.
        let content = NSSize(width: 900, height: 620)
        let size = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        ).size
        app.terminate()
        if let index = app.launchArguments.firstIndex(of: Self.windowSizeArgument) {
            app.launchArguments[index + 1] = Self.sizeValue(content)
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        unlockSuccessfully(in: openDatabase(named: "Personal"))
        openGroup(named: "Social")
        openEntry(named: "Twitter")
        XCTAssertEqual(personalWindow.frame.width, size.width, accuracy: 2)
        XCTAssertEqual(personalWindow.frame.height, size.height, accuracy: 2)
    }

    /// Opens a sheet on the Databases window, snaps it, and closes it.
    private func captureLauncherSheet(
        opening open: () -> Void,
        hosting identifier: String?,
        _ name: String,
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
            ("Security", "settings.tab.security", "07a-settings-security"),
            ("AutoFill", "settings.tab.autofill", "07b-settings-autofill"),
            ("Menu Bar", "settings.tab.menu-bar", "07f-settings-menu-bar"),
            ("SSH Agent", "settings.tab.ssh-agent", "07g-settings-ssh-agent"),
            ("Display", "settings.tab.display", "07c-settings-display"),
            ("Cloud", "settings.tab.cloud", "07d-settings-cloud"),
            ("About", "settings.tab.about", "07e-settings-about"),
        ]

        let settingsWindow = self.settingsWindow
        guard settingsWindow.waitForExistence(timeout: 5) else {
            for (title, _, name) in tabs {
                noteSkip(name, reason: "Settings window missing before selecting '\(title)'")
            }
            return
        }

        for (title, contentIdentifier, name) in tabs {
            guard selectSettingsTab(named: title) else { continue }
            settle(0.6)
            guard surface(hosting: contentIdentifier) != nil else {
                noteSkip(name, reason: "settings tab '\(title)' did not reveal its content")
                continue
            }
            await snapSurface(hosting: contentIdentifier, name)
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
