import AppKit
import CoreGraphics
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
/// The harness only ever screenshots the app's own windows — it never falls
/// back to `XCUIApplication.screenshot()`, which on macOS captures the entire
/// desktop and would leak whatever the user has on screen.
@MainActor
final class MacScreenshotAuditUITests: MacUITestCase {

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT"] == "1" else {
            throw XCTSkip("Screenshot audit runs only with SCREENSHOT_AUDIT=1")
        }
        try await super.setUp()
    }

    override func configureLaunch(app: XCUIApplication) throws {
        if ProcessInfo.processInfo.environment["SCREENSHOT_AUDIT_DARK"] == "1" {
            // Force the process into dark appearance regardless of the host's
            // system setting (the app follows the system when its appearance
            // preference is "System", which is the default in tests).
            //
            // NSUserDefaults argument parsing pairs `-key value`, and the base
            // class deliberately keeps the bare `-ui-testing` flag LAST so it is
            // not swallowed as another key's value. Insert this `-key value`
            // pair BEFORE `-ui-testing` to preserve that invariant.
            // Seed the app's own appearance preference (`@AppStorage`) to dark;
            // the app renders with `preferredColorScheme`, so an OS-level
            // `-AppleInterfaceStyle` override does not reach it when the
            // preference is "System".
            let darkArgs = ["-KeeForge.appearanceMode", "dark"]
            if let index = app.launchArguments.firstIndex(of: "-ui-testing") {
                app.launchArguments.insert(contentsOf: darkArgs, at: index)
            } else {
                app.launchArguments += darkArgs
            }
        }
    }

    private static let appBundleIdentifier = "com.keevault.app"

    /// PID of the running app-under-test.
    private var appProcessID: pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
            .processIdentifier
    }

    /// True when the physically frontmost real on-screen window belongs to the
    /// app-under-test.
    ///
    /// `CGWindowListCopyWindowInfo` returns window *metadata* (no Screen
    /// Recording permission required, unlike image capture), ordered front to
    /// back. `XCUIElement.screenshot()` region-captures the screen behind the
    /// element, so it only stays leak-proof when the app actually owns the
    /// frontmost pixels — this check gates every capture on exactly that, so the
    /// harness can never grab the user's other windows or desktop.
    private func isAppWindowFrontmost() -> Bool {
        guard let pid = appProcessID,
              let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 200, bounds.height > 200 else {
                continue
            }
            // First (frontmost) real window decides: it must be ours.
            return (info[kCGWindowOwnerPID as String] as? pid_t) == pid
        }
        return false
    }

    /// The app window element with the largest frame (the main window).
    private var mainWindowElement: XCUIElement? {
        app.windows.allElementsBoundByIndex.max { $0.frame.area < $1.frame.area }
    }

    /// Raises the app over other apps as forcefully as the test process can:
    /// `XCUIApplication.activate()` plus `NSRunningApplication.activate()`.
    private func forceActivateApp() {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
            .activate()
        app.activate()
    }

    /// Waits until the app owns the frontmost pixels for two consecutive checks
    /// (a stable foreground, not a momentary flicker), re-activating as needed.
    ///
    /// NOTE: the frontmost check depends on `CGWindowListCopyWindowInfo` seeing
    /// other apps' windows, which requires Screen Recording permission for the
    /// runner. Without it the runner sees only its own app's windows, so the
    /// check can only confirm the app is frontmost among its OWN windows — it
    /// falls back to a best-effort forced activation. With the permission (e.g.
    /// on a clean CI runner) the check is a true physical-frontmost gate.
    @discardableResult
    private func waitForStableForeground(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            forceActivateApp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if isAppWindowFrontmost() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if isAppWindowFrontmost() {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    return true
                }
            }
        }
        return false
    }

    /// Captures a window element via `XCUIElement.screenshot()`, but only while
    /// the app is confirmed to own the frontmost pixels — checked immediately
    /// before AND after the capture, so a focus flip mid-capture discards the
    /// image instead of leaking. If the app cannot be held in the foreground
    /// (e.g. the machine is actively in use during the run), attach nothing.
    private func snapWindow(_ window: @autoclosure () -> XCUIElement?, _ name: String) {
        guard waitForStableForeground(), let element = window(), element.exists else { return }
        // A zero/near-zero frame element cannot be screenshotted (XCUITest
        // raises "Image creation failed"); skip rather than fail the run.
        guard element.frame.width > 1, element.frame.height > 1 else { return }
        guard isAppWindowFrontmost() else { return }

        let shot = element.screenshot()

        // Discard if focus flipped to another app during the capture.
        guard isAppWindowFrontmost() else { return }

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Snaps the app's main window (largest app-owned window).
    private func snap(_ name: String) {
        snapWindow(mainWindowElement, name)
    }

    /// Snaps the frontmost app window (an editor sheet or the settings window).
    private func snapFrontWindow(_ name: String) {
        snapWindow(app.windows.firstMatch, name)
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testCaptureScreens() {
        // 1. Database list
        settle(2)
        snap("01-database-list")

        // 2. Unlock screen
        _ = openFirstDatabaseFromListIfNeeded()
        settle()
        snap("02-unlock")

        // 3. Unlocked vault root (three-column: groups / entries / detail)
        unlockSuccessfully()
        settle()
        snap("03-vault-root")

        // 4. Entry detail — must navigate into a group first; the vault root
        //    shows the group tree in the sidebar, and entry rows live in the
        //    content column only after a group is selected.
        openGroup(named: "Work")
        settle()
        snap("04-group-selected")

        let entry = app.buttons.matching(identifier: "entry.navlink").firstMatch
        if entry.waitForExistence(timeout: 10) {
            entry.click()
            settle()
            snap("05-entry-detail")
        }

        // NOTE ON ORDERING: the keyboard-driven captures (⌘F search, ⌘, settings)
        // come BEFORE the entry editor. A modal sheet hands the foreground back
        // to whatever app was active before the test on a shared machine, after
        // which ⌘-shortcuts no longer reach the app. Keeping the sheet last means
        // the search/settings captures run while the app still holds focus from
        // the entry clicks above.

        // 6. Search focused with results.
        typeCommandShortcut("f")
        app.typeText("a")
        settle()
        snap("06-search")
        // Clear the search so later steps see the normal browse UI.
        clearSearchField()
        settle()

        // 7. Settings window + each tab.
        typeCommandShortcut(",")
        settle(1.5)
        captureSettingsTabs()
        // Close the settings window.
        typeCommandShortcut("w")
        settle()

        // 8. Entry edit sheet (⌘N) — last, because presenting/dismissing it can
        //    drop the app out of the foreground. Best effort: re-focus an entry,
        //    open the editor, snap the frontmost window (the sheet), then cancel.
        forceActivateApp()
        let editorEntry = app.buttons.matching(identifier: "entry.navlink").firstMatch
        if editorEntry.waitForExistence(timeout: 5), editorEntry.isHittable {
            editorEntry.click()
        }
        typeCommandShortcut("n")
        if app.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) {
            settle(0.6)
            snapFrontWindow("08-entry-editor-sheet")
            let cancelButton = app.buttons["entry-edit.cancel"].firstMatch
            if cancelButton.waitForExistence(timeout: 3), cancelButton.isHittable {
                cancelButton.click()
            }
            settle()
        }

        // 9. Back to the main window in a clean state.
        snap("09-final-state")
    }

    private func clearSearchField() {
        let searchField = app.searchFields.firstMatch
        if searchField.exists, searchField.isHittable {
            searchField.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
        }
    }

    private func captureSettingsTabs() {
        let tabIdentifiers = [
            ("settings.tab.security", "07a-settings-security"),
            ("settings.tab.display", "07b-settings-display"),
            ("settings.tab.cloud", "07c-settings-cloud"),
            ("settings.tab.about", "07d-settings-about"),
        ]

        for (tabIdentifier, name) in tabIdentifiers {
            // TabView tab items surface as buttons or radio buttons depending on
            // the macOS version; try both, best effort.
            let tabButton = app.buttons[tabIdentifier].firstMatch
            let tabRadio = app.radioButtons[tabIdentifier].firstMatch
            if tabButton.waitForExistence(timeout: 2), tabButton.isHittable {
                tabButton.click()
            } else if tabRadio.exists, tabRadio.isHittable {
                tabRadio.click()
            }
            settle(0.6)
            // The settings window is frontmost while it is open.
            snapFrontWindow(name)
        }
    }
}
