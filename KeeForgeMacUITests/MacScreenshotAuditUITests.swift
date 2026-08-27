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
/// Add `TEST_RUNNER_SCREENSHOT_AUDIT_DARK=1` for a dark-appearance pass. Both
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
        //
        // `-key value` pairs go BEFORE the bare `-ui-testing` flag, which the
        // base class keeps last so it is not swallowed as another key's value.
        insertLaunchArguments(["-KeeForge.blockScreenCapture", "NO"], into: app)

        if ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT_DARK"] == "1" {
            // Force the process into dark appearance regardless of the host's
            // system setting (the app follows the system when its appearance
            // preference is "System", which is the default in tests).
            //
            // Seed the app's own appearance preference (`@AppStorage`) to dark;
            // the app renders with `preferredColorScheme`, so an OS-level
            // `-AppleInterfaceStyle` override does not reach it when the
            // preference is "System".
            insertLaunchArguments(["-KeeForge.appearanceMode", "dark"], into: app)
        }
    }

    private func insertLaunchArguments(_ arguments: [String], into app: XCUIApplication) {
        if let index = app.launchArguments.firstIndex(of: "-ui-testing") {
            app.launchArguments.insert(contentsOf: arguments, at: index)
        } else {
            app.launchArguments += arguments
        }
    }

    private static let appBundleIdentifier = "com.keevault.app"

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
    /// On macOS 14+ this list is trimmed to the caller's OWN windows unless the
    /// process holds Screen Recording permission — which is exactly why the
    /// harness cannot assume it sees the whole screen.
    private func orderedScreenWindows() -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 1, rect.height > 1 else {
                return nil
            }
            return ScreenWindow(pid: pid, id: id, rect: rect)
        }
    }

    /// The window-server record for the app window at `rect`.
    private func appScreenWindow(matching rect: CGRect) -> ScreenWindow? {
        guard let pid = appProcessID else { return nil }
        return orderedScreenWindows().first {
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

    /// The app window element with the largest frame (the main window).
    private var mainWindowElement: XCUIElement? {
        app.windows.allElementsBoundByIndex.max { $0.frame.area < $1.frame.area }
    }

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
        if element.elementType == .sheet, let mainWindowElement {
            captureElement = mainWindowElement
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

    /// Snaps the app's main window (largest app-owned window).
    private func snap(_ name: String) async {
        await snapWindow(mainWindowElement, name)
    }

    /// The app window (or attached sheet) that hosts `identifier`.
    ///
    /// Secondary surfaces are addressed by content, never by `windows.firstMatch`:
    /// that returns the main window when the surface failed to open, so the
    /// capture silently mislabels the main window as "settings" or "editor".
    private func surface(hosting identifier: String) -> XCUIElement? {
        let sheet = app.sheets.firstMatch
        if sheet.exists, sheet.descendants(matching: .any)[identifier].exists {
            return sheet
        }
        return app.windows.allElementsBoundByIndex.first {
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

    func testCaptureScreens() async {
        // 1. Database list
        settle(2)
        await snap("01-database-list")

        // 2. Unlock screen
        _ = openFirstDatabaseFromListIfNeeded()
        settle()
        await snap("02-unlock")

        // 3. Unlocked vault root (three-column: groups / entries / detail)
        unlockSuccessfully()
        settle()
        await snap("03-vault-root")

        // 4. Entry detail — must navigate into a group first; the vault root
        //    shows the group tree in the sidebar, and entry rows live in the
        //    content column only after a group is selected.
        openGroup(named: "Work")
        settle()
        await snap("04-group-selected")

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

        // 6. Search focused with results.
        if typeAppShortcut("f") {
            app.typeText("a")
            settle()
            await snap("06-search")
            // Clear the search so later steps see the normal browse UI.
            clearSearchField()
            settle()
        } else {
            noteSkip("06-search", reason: "⌘F could not be delivered")
        }

        // 7. Settings window + each tab.
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
                app.buttons["database-details.close"].firstMatch.click()
                settle()
            } else {
                noteSkip("08a-database-details", reason: "the details sheet never opened")
            }
        } else {
            noteSkip("08a-database-details", reason: "the details toolbar button was not hittable")
        }

        // 9. Back to the main window in a clean state.
        await snap("09-final-state")

        // 10. The three columns and the five-item toolbar at the window's
        //     minimum size (900x620), where crowding and truncation show up.
        shrinkMainWindowToMinimum()
        settle()
        await snap("10-minimum-width")

        attachCaptureReport()
    }

    /// Drags the main window's bottom-right corner far up and left; AppKit
    /// clamps the drag at the scene's `minWidth`/`minHeight`, so the window
    /// lands exactly on its minimum size.
    private func shrinkMainWindowToMinimum() {
        waitForStableForeground()
        guard let window = mainWindowElement, window.exists else {
            noteSkip("10-minimum-width", reason: "no main window to resize")
            return
        }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        let target = corner.withOffset(
            CGVector(dx: -window.frame.width, dy: -window.frame.height)
        )
        corner.press(forDuration: 0.4, thenDragTo: target)
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
        // SwiftUI exposes only the selected Settings tab to XCUITest on macOS
        // 26, even though all five controls are visible and reachable through
        // AppKit accessibility. The pane has a fixed 540pt width, and the
        // system lays the five controls out at stable positions in its toolbar,
        // so address them through window-relative coordinates. Each click is
        // still verified through the identifier on the content it reveals.
        let tabs: [(String, CGFloat, String, String)] = [
            ("Security", 0.292, "settings.tab.security", "07a-settings-security"),
            ("AutoFill", 0.396, "settings.tab.autofill", "07b-settings-autofill"),
            ("Display", 0.500, "settings.tab.display", "07c-settings-display"),
            ("Cloud", 0.604, "settings.tab.cloud", "07d-settings-cloud"),
            ("About", 0.708, "settings.tab.about", "07e-settings-about"),
        ]

        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"].firstMatch
        guard settingsWindow.waitForExistence(timeout: 5) else {
            for (title, _, _, name) in tabs {
                noteSkip(name, reason: "Settings window missing before selecting '\(title)'")
            }
            return
        }

        for (title, horizontalPosition, contentIdentifier, name) in tabs {
            settingsWindow.coordinate(
                withNormalizedOffset: CGVector(dx: horizontalPosition, dy: 0.09)
            ).click()
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
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"].firstMatch
        guard settingsWindow.exists else { return true }

        settingsWindow.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 16, dy: 16))
            .click()
        return settingsWindow.waitForNonExistence(timeout: 5)
    }
}
