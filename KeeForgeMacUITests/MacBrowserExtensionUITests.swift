import CryptoKit
import XCTest

/// The shipped browser extension in a real Chromium, through the real embedded native-messaging host,
/// to the signed app: pair from the in-field menu, fill from the key button, unlock from the menu, the
/// toolbar popup and removal. `BrowserExtension/tools/e2e-browser.mjs` drives a disposable headless
/// Chrome with trusted CDP input; this test drives the app. `MacBrowserBridgeUITests` covers the wire
/// protocol with the extension's code under Node; neither a unit test nor that class reaches Chrome's
/// native-messaging launch, the extension's background and content scripts, or a real page fill.
///
/// Under `-ui-testing` the app's device-owner gate reports no authentication available, so credentials
/// are released without Touch ID: this test does not cover the Touch ID prompt.
final class MacBrowserExtensionUITests: MacUITestCase {
    // Under -ui-testing no owner prompt can be answered, and the bridge refuses to release
    // without one. A grace period makes each unlock the authentication, as it is for a user.
    override var extraLaunchArguments: [String] { ["-KeeForge.authenticationGracePeriod", "fiveMinutes"] }

    private static let site = "alpha.example.com"
    private static let entryTitle = "Alpha Login"
    private static let entryUsername = "alpha-user"
    private static let entryPassword = "GroupTagAlpha1"

    override var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-KeeForge.blockScreenCapture", "NO"]
    }

    private var driver: E2EDriverProcess?

    override func tearDown() async throws {
        if let driver {
            // hasSucceeded is still false while the run has not stopped, so count failures instead.
            if (testRun?.totalFailureCount ?? 0) > 0 {
                if let shot = driver.call(["cmd": "screenshot", "name": "on-failure"], timeout: 10) { attachBrowserShot(shot, named: "browser-on-failure") }
                attachText(driver.transcript, named: "driver-transcript-on-failure")
            }
            driver.stop(timeout: 10)
        }
        driver = nil
        try await super.tearDown()
    }

    func testRealExtensionPairsFillsAndUnlocksInChrome() throws {
        try failIfSystemAlertIsShown()
        // The driver starts first, so a missing launcher costs seconds, not the whole run.
        let host = try embeddedHostURL()
        var arguments = ["--host", host.path]
        if let browser = ProcessInfo.processInfo.environment["KEEFORGE_E2E_BROWSER"], !browser.isEmpty {
            arguments += ["--browser", browser]
        }
        let driver = try E2EDriverProcess(script: try browserToolURL("e2e-browser.mjs"), arguments: arguments)
        self.driver = driver
        let ready = try XCTUnwrap(driver.waitForEvent("driver-ready", after: 0, timeout: 10) { _ in true },
                                  "The driver did not start through NSUserUnixTask:\n\(driver.transcript)")
        XCTAssertEqual(ready["parentSandboxed"] as? Bool, false,
                       "The driver runs inside the runner's sandbox, so the host cannot get its own:\n\(driver.transcript)")
        unlockSuccessfully()
        let databaseWindow = self.databaseWindow

        // 1. Bridge on from a clean state; a host started as a browser starts it reaches the app.
        switchBridgeOnFromClean()
        snap("01-bridge-on")
        let probe = try call(driver, "probeHost", timeout: 15,
                             "A host started as the browser starts it did not answer within 10 seconds")
        XCTAssertEqual((probe["frame"] as? [String: Any])?["event"] as? String, "connected", "host probe: \(probe)")

        // 2. The browser. None installed is a failure, never a skip.
        guard ready["browser"] is String else {
            let searched = (ready["searched"] as? [String] ?? []).joined(separator: ", ")
            throw NSError(domain: "MacBrowserExtensionUITests", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "No Chromium-family browser on this machine, so the real extension cannot be tested. Searched: \(searched). "
                + "Install Google Chrome in /Applications, or Chrome for Testing with "
                + "`npx @puppeteer/browsers install chrome@stable --path ~/Library/Caches/KeeForge-E2E`, "
                + "or set TEST_RUNNER_KEEFORGE_E2E_BROWSER to a Chromium executable."])
        }
        let started = try call(driver, "start", timeout: 60, "The browser did not start with the extension loaded")
        attachText("\(started["product"] ?? "?") extension \(started["extensionId"] ?? "?")", named: "02-browser")
        let login = try call(driver, "openLogin", timeout: 30, "The login page did not load")
        XCTAssertEqual(login["origin"] as? String, "https://\(Self.site)")
        XCTAssertEqual(login["secure"] as? Bool, true)
        XCTAssertEqual(login["buttons"] as? Int, 3, "Key buttons in the user-name, password and code fields: \(login)")

        // 3. Unpaired menu; Pair opens the pairing tab, whose code the app's alert shows; Allow pairs.
        try call(driver, "clickKey", ["field": "u"])
        try call(driver, "waitMenu", ["state": "unpaired", "timeout": 20], timeout: 25,
                 "The first menu did not reach the host and app and show Not paired")
        let pairing = try call(driver, "menuPair", timeout: 40, "Pair in the menu did not show a code")
        let code = try XCTUnwrap(pairing["code"] as? String)
        let alertCode = pairingCodeElement()
        XCTAssertTrue(alertCode.waitForExistence(timeout: 15), "No pairing alert appeared")
        XCTAssertEqual(alertCode.value as? String, Self.grouped(code), "The alert's code differs from the pairing tab's")
        snap("03-pairing-alert")
        let allow = app.buttons["browser-pairing.allow"].firstMatch
        waitUntilEnabled(allow, timeout: 10)
        XCTAssertTrue(allow.isEnabled, "Allow never became enabled")
        allow.click()
        try call(driver, "waitPaired", ["timeout": 20], timeout: 25, "The pairing tab did not report paired after Allow")

        // 4. The open menu lists the fixture login by itself; choosing it fills the page.
        let listed = try call(driver, "waitMenu", ["state": "logins", "title": Self.entryTitle, "timeout": 20], timeout: 25,
                              "The menu did not list \(Self.entryTitle) after pairing")
        XCTAssertEqual(listed["site"] as? String, Self.site)
        let row = (listed["rows"] as? [[String: Any]] ?? []).first { $0["title"] as? String == Self.entryTitle }
        XCTAssertEqual(row?["username"] as? String, Self.entryUsername)
        attachBrowserShot(try call(driver, "screenshot", ["name": "menu-logins"]), named: "04-browser-menu-logins")
        try call(driver, "menuFill", ["title": Self.entryTitle], timeout: 30, "Choosing \(Self.entryTitle) did not fill the page")
        let filled = try fields(driver)
        XCTAssertEqual(filled["u"]?["value"] as? String, Self.entryUsername, "user-name field")
        XCTAssertEqual(filled["p"]?["sha256"] as? String, Self.sha256(Self.entryPassword), "password field holds another value")
        XCTAssertEqual(filled["c"]?["value"] as? String, "", "a login fill wrote the code field")

        // 5. The code field offers only entries with a code; no fixture entry for this site has one.
        try call(driver, "clearFields")
        try call(driver, "clickKey", ["field": "c"])
        let codeMenu = try call(driver, "waitMenu", ["state": "empty"], timeout: 20, "The code field's menu was not empty")
        XCTAssertTrue((codeMenu["status"] as? String ?? "").contains(Self.site), "code menu: \(codeMenu)")
        try call(driver, "closeMenu")

        // 6. Locked: the menu says so, Unlock fronts the locked window, and unlocking there refreshes the menu.
        frontDatabaseWindow(named: "kitchen-sink")
        typeCommandShortcut("l")
        XCTAssertTrue(waitForLockedState(in: databaseWindow), "⌘L did not lock the database")
        openBrowsersSettings()
        let passwordField = databaseWindow.secureTextFields["unlock.password.field"]
        XCTAssertFalse(waitForKeyboardFocus(passwordField, timeout: 1), "Settings should be key before unlock")
        try call(driver, "clickKey", ["field": "u"])
        try call(driver, "waitMenu", ["state": "locked"], timeout: 20, "The menu did not show the locked state")
        attachBrowserShot(try call(driver, "screenshot", ["name": "menu-locked"]), named: "06-browser-menu-locked")
        // A `locked` reply names no database, so the menu's unlock fronts the Databases window (protocol: `unlock`).
        try call(driver, "menuUnlock", timeout: 20)
        XCTAssertTrue(waitForKeyboardFocus(databaseTable, timeout: 10), "Unlock in the menu did not front the Databases window")
        snap("06-unlock-fronted-databases")
        unlockSuccessfully(in: openDatabase(named: "kitchen-sink"))
        try call(driver, "waitMenu", ["state": "logins", "title": Self.entryTitle, "timeout": 20], timeout: 25,
                 "The menu did not list logins again after unlocking in the app")
        try call(driver, "closeMenu")

        // 7. The toolbar popup opens at its fixed width and lists the login.
        let popup = try call(driver, "popup", timeout: 30, "The toolbar popup did not open")
        XCTAssertEqual(popup["htmlWidth"] as? Double, 340, "popup: \(popup)")
        XCTAssertTrue((popup["rows"] as? [[String: Any]] ?? []).contains { $0["title"] as? String == Self.entryTitle },
                      "The popup does not list \(Self.entryTitle): \(popup)")

        // 8. Remove… in Settings, and the menu is back to Not paired.
        openBrowsersSettings()
        let remove = pairedRemoveButtons().firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Settings does not list the paired browser")
        snap("08-paired-browser-listed")
        remove.click()
        confirmRemoval()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 10), "The removed browser is still listed")
        try call(driver, "clickKey", ["field": "u"])
        try call(driver, "waitMenu", ["state": "unpaired", "timeout": 20], timeout: 25, "A removed browser's menu is not Not paired")
        try call(driver, "closeMenu")

        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(0))
        attachText(driver.transcript, named: "driver-transcript")
    }

    // MARK: - Driver

    @discardableResult
    private func call(_ driver: E2EDriverProcess, _ command: String, _ fields: [String: Any] = [:], timeout: TimeInterval = 20,
                      _ failure: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var message = fields
        message["cmd"] = command
        let what = failure ?? command
        let reply = try XCTUnwrap(driver.waitForResult(driver.send(message), timeout: timeout, any: true),
                                  "\(what): no reply within \(Int(timeout)) s\n\(driver.transcript)", file: file, line: line)
        guard reply["done"] as? Bool == true else {
            throw NSError(domain: "MacBrowserExtensionUITests", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "\(what): \(reply["message"] as? String ?? reply["error"] as? String ?? "failed")\n\(driver.transcript)"])
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func fields(_ driver: E2EDriverProcess) throws -> [String: [String: Any]] {
        try call(driver, "fields")["fields"] as? [String: [String: Any]] ?? [:]
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A CDP capture of the login page, menu included; never `screencapture`.
    private func attachBrowserShot(_ result: [String: Any], named name: String) {
        guard let base64 = result["png"] as? String, let data = Data(base64Encoded: base64) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
