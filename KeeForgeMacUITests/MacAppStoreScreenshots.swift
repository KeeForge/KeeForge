import AppKit
import CoreGraphics
import ScreenCaptureKit
import XCTest

/// Captures the Mac App Store product-page screenshots from the `demo` vault
/// (password `demo`), the same fixture as `KeeForgeUITests/AppStoreScreenshots`.
/// Skipped unless `APPSTORE_SCREENSHOTS=1` reaches the runner:
///
///     TEST_RUNNER_APPSTORE_SCREENSHOTS=1 xcodebuild test ... \
///         -only-testing:KeeForgeMacUITests/MacAppStoreScreenshots
///
/// Captures are light, of a 1440x900 pt main window, taken from each window's
/// own content through ScreenCaptureKit as in `MacScreenshotAuditUITests`. A
/// capture that cannot be taken is listed in `00-skipped-captures`.
@MainActor
final class MacAppStoreScreenshots: MacUITestCase {
    private static let appBundleIdentifier = "com.keevault.app"
    private static let demoPassword = "demo"
    private static let windowSize = CGSize(width: 1440, height: 900)
    private static let settingsWindowIdentifier = "settings"

    override var databaseFixtures: [DatabaseFixture] {
        [
            DatabaseFixture(resourceName: "demo", injectedFilename: "Personal.kdbx"),
            DatabaseFixture(resourceName: "demo", injectedFilename: "Work.kdbx"),
        ]
    }

    private var isPickerCapture: Bool { name.contains("AutoFillPicker") }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["APPSTORE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Mac App Store screenshot capture runs only with APPSTORE_SCREENSHOTS=1")
        }
        try await super.setUp()
        executionTimeAllowance = 600
    }

    override func configureLaunch(app: XCUIApplication) throws {
        // Flags placed before the bare `-ui-testing` so they parse as pairs.
        var arguments = [
            "-KeeForge.blockScreenCapture", "NO",
            "-KeeForge.appearanceMode", "light",
            "-NSWindow Frame main-AppWindow-1", Self.mainWindowFrameDefault,
        ]
        if isPickerCapture {
            arguments += ["-autofill-picker-harness", "-autofill-picker-store"]
        }
        let index = app.launchArguments.firstIndex(of: "-ui-testing") ?? app.launchArguments.endIndex
        app.launchArguments.insert(contentsOf: arguments, at: index)
        app.launchEnvironment["UI_TEST_HIDE_SEARCH_RESULTS_COUNT"] = "1"
    }

    // MARK: - Walkthrough

    func testCaptureStoreScreens() async {
        settle(2)
        checkMainWindowSize()

        // 02: unlock screen with the password typed, before unlocking.
        openFirstDatabaseFromListIfNeeded()
        let passwordField = app.secureTextFields["unlock.password.field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "Password field did not appear")
        passwordField.click()
        passwordField.typeText(Self.demoPassword)
        settle()
        await snap("02-unlock")

        let unlockButton = app.buttons["unlock.button"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "Unlock button did not appear")
        unlockButton.click()
        XCTAssertTrue(waitForVaultToUnlock(), "The demo vault did not unlock")
        settle()

        // 01: three panes with Discord and its one-time code.
        openGroup(named: "Social")
        openEntry(named: "Discord")
        if !rowQuery(identifier: "entry.totp.code").firstMatch.waitForExistence(timeout: 10) {
            noteSkip("01-entry-detail", reason: "Discord's one-time code row never appeared")
        }
        settle(1.5)
        await snap("01-entry-detail")

        // Keyboard and Settings captures come before the sheets: dismissing a
        // sheet can hand the foreground to another app on a shared machine.

        // 04: search for "git" with a result selected, from the result's own group so the sidebar matches it.
        openGroup(named: "Work")
        settle(0.6)
        if typeAppShortcut("f") {
            app.typeText("git")
            if rowQuery(identifier: "search.entry.navlink").firstMatch.waitForExistence(timeout: 8) {
                settle(0.6)
                clickFirstRow(identifier: "search.entry.navlink")
                if waitForAnyDetailTitle().isEmpty {
                    noteSkip("04-search", reason: "selecting a result did not fill the detail pane")
                } else {
                    settle()
                    await snap("04-search")
                }
            } else {
                noteSkip("04-search", reason: "no results appeared for \"git\"")
            }
            clearSearch()
        } else {
            noteSkip("04-search", reason: "⌘F could not be delivered")
        }

        // 06: Settings, which opens on Security.
        await captureSecuritySettings()

        // 05: editor for an existing, filled-in entry.
        openGroup(named: "Work")
        openEntry(named: "GitHub")
        _ = waitForAnyDetailTitle()
        clickToolbarButton(identifier: "entry-detail.edit", overflowLabel: "Edit")
        if app.textFields["entry-edit.title-field"].waitForExistence(timeout: 8) {
            settle()
            await snapSurface(hosting: "entry-edit.title-field", "05-entry-edit")
            let cancel = app.buttons["entry-edit.cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3), cancel.isHittable {
                cancel.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
            settle()
        } else {
            noteSkip("05-entry-edit", reason: "the editor never opened")
        }

        // 03: database details hub (format and Encryption rows).
        clickToolbarButton(identifier: "database-details.button", overflowLabel: "Database Details")
        if app.buttons["database-details.close"].waitForExistence(timeout: 8) {
            // The header's format summary loads asynchronously.
            settle(2)
            await snapSurface(hosting: "database-details.close", "03-database-details")
            app.buttons["database-details.close"].firstMatch.click()
            settle()
        } else {
            noteSkip("03-database-details", reason: "the details sheet never opened")
        }

        attachCaptureReport()
    }

    /// The Mac AutoFill picker, through the DEBUG `-autofill-picker-harness`
    /// root with the `-autofill-picker-store` entries for a github.com request.
    func testCaptureAutoFillPicker() async {
        let searchField = app.textFields["autofill.search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15), "The picker did not appear")
        settle(2)
        await snap("07-autofill-picker")
        attachCaptureReport()
    }

    private func captureSecuritySettings() async {
        let name = "06-settings-security"
        clickToolbarButton(identifier: "settings.button", overflowLabel: "Settings")
        let settingsWindow = app.windows[Self.settingsWindowIdentifier].firstMatch
        guard settingsWindow.waitForExistence(timeout: 8) else {
            noteSkip(name, reason: "the Settings window never opened")
            return
        }
        // Settings opens on Security; select it anyway in case that changes.
        let securityTab = settingsWindow.descendants(matching: .any).matching(
            NSPredicate(format: "(label == %@ OR title == %@) AND elementType IN %@",
                        "Security", "Security",
                        [XCUIElement.ElementType.button.rawValue,
                         XCUIElement.ElementType.radioButton.rawValue,
                         XCUIElement.ElementType.toolbarButton.rawValue])
        ).allElementsBoundByIndex.first { $0.isHittable }
        securityTab?.click()
        settle(1.5)
        await snapWindow(settingsWindow, name)

        settingsWindow.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 16, dy: 16)).click()
        if !settingsWindow.waitForNonExistence(timeout: 5) {
            app.typeKey("w", modifierFlags: .command)
        }
        settle()
    }

    // MARK: - Window size

    /// The main window's saved frame (`NSWindow Frame <autosave name>`, in
    /// bottom-left screen coordinates), centered on the main screen. XCUITest
    /// corner drags do not resize windows on macOS 27, and AppKit would
    /// otherwise restore whatever frame the last run left.
    private static var mainWindowFrameDefault: String {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let x = screen.minX + max(0, (screen.width - windowSize.width) / 2)
        let y = screen.minY + max(0, (screen.height - windowSize.height) / 2)
        return [x, y, windowSize.width, windowSize.height, screen.minX, screen.minY, screen.width, screen.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: " ")
    }

    private func checkMainWindowSize() {
        guard let size = mainWindowElement?.frame.size,
              abs(size.width - Self.windowSize.width) <= 2,
              abs(size.height - Self.windowSize.height) <= 2 else {
            noteSkip("window-size", reason: "main window is \(String(describing: mainWindowElement?.frame.size)), not \(Self.windowSize)")
            return
        }
    }

    // MARK: - Capture

    private var skippedCaptures: [String] = []

    private func noteSkip(_ name: String, reason: String) {
        skippedCaptures.append("\(name): \(reason)")
    }

    private func attachCaptureReport() {
        guard skippedCaptures.isEmpty == false else { return }
        let report = skippedCaptures.joined(separator: "\n")
        print("APP STORE SCREENSHOTS — skipped captures:\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "00-skipped-captures"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func clearSearch() {
        let searchField = app.searchFields.firstMatch
        if searchField.exists, searchField.isHittable {
            searchField.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
        }
        settle()
    }

    private var appProcessID: pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
            .processIdentifier
    }

    private var mainWindowElement: XCUIElement? {
        app.windows.allElementsBoundByIndex
            .filter { $0.identifier != Self.settingsWindowIdentifier }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private struct ScreenWindow {
        let pid: pid_t
        let id: CGWindowID
        let rect: CGRect
    }

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
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else {
                return nil
            }
            return ScreenWindow(pid: pid, id: id, rect: rect)
        }
    }

    private func appScreenWindow(matching rect: CGRect) -> ScreenWindow? {
        guard let pid = appProcessID else { return nil }
        return orderedScreenWindows().first {
            $0.pid == pid && abs($0.rect.minX - rect.minX) < 3 && abs($0.rect.minY - rect.minY) < 3
                && abs($0.rect.width - rect.width) < 3 && abs($0.rect.height - rect.height) < 3
        }
    }

    private var isAppForeground: Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.appBundleIdentifier,
              let pid = appProcessID,
              let front = orderedScreenWindows().first(where: { $0.rect.width > 200 && $0.rect.height > 200 }) else {
            return false
        }
        return front.pid == pid
    }

    @discardableResult
    private func waitForStableForeground(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == Self.appBundleIdentifier }?
                .activate()
            app.activate()
            settle(0.5)
            if isAppForeground {
                settle(0.3)
                if isAppForeground { return true }
            }
        }
        return false
    }

    /// Sends a ⌘-shortcut only while the app owns the foreground, so it never
    /// lands in another app's window.
    private func typeAppShortcut(_ key: String) -> Bool {
        guard waitForStableForeground() else { return false }
        typeCommandShortcut(key)
        return true
    }

    private nonisolated static func windowImage(id: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            let configuration = SCStreamConfiguration()
            // The runner reports a backing scale of 1, so ask for Retina pixels.
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            configuration.scalesToFit = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch {
            return nil
        }
    }

    private func snapWindow(_ window: @autoclosure () -> XCUIElement?, _ name: String) async {
        guard waitForStableForeground(), let element = window(), element.exists,
              element.frame.width > 1, element.frame.height > 1 else {
            noteSkip(name, reason: "app never held the foreground")
            return
        }
        // ScreenCaptureKit composites an attached sheet into its parent window.
        let captureElement = element.elementType == .sheet ? (mainWindowElement ?? element) : element
        guard let record = appScreenWindow(matching: captureElement.frame) else {
            noteSkip(name, reason: "no window-server record for \(captureElement.frame)")
            return
        }
        guard let image = await Self.windowImage(id: record.id) else {
            noteSkip(name, reason: "window capture failed — grant Screen Recording to KeeForgeMacUITests-Runner")
            return
        }
        let attachment = XCTAttachment(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func snap(_ name: String) async {
        await snapWindow(mainWindowElement, name)
    }

    private func surface(hosting identifier: String) -> XCUIElement? {
        let sheet = app.sheets.firstMatch
        if sheet.exists, sheet.descendants(matching: .any)[identifier].exists {
            return sheet
        }
        return app.windows.allElementsBoundByIndex.first {
            $0.descendants(matching: .any)[identifier].exists
        }
    }

    private func snapSurface(hosting identifier: String, _ name: String) async {
        guard surface(hosting: identifier) != nil else {
            noteSkip(name, reason: "no surface hosting '\(identifier)'")
            return
        }
        await snapWindow(self.surface(hosting: identifier), name)
    }
}
