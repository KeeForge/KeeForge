import AppKit
import XCTest

/// The browser bridge end to end: the signed, sandboxed app against its real embedded
/// native-messaging host, driven by the extension's own `Connection` in Node
/// (`BrowserExtension/tools/e2e-client.mjs`). Unit tests cannot reach two signed sandboxed
/// processes meeting in the app-group socket, the real pairing alert, or Settings.
final class MacBrowserBridgeUITests: MacUITestCase {
    private static let browserName = "KeeForge E2E Browser"
    private static let origin = "https://alpha.example.com"

    override var databaseFixtures: [DatabaseFixture] {
        [DatabaseFixture(resourceName: "kitchen-sink", injectedFilename: "kitchen-sink.kdbx")]
    }

    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-KeeForge.blockScreenCapture", "NO"]
    }

    private var client: BridgeClient?

    override func tearDown() async throws {
        if let client {
            if testRun?.hasSucceeded == false { attachText(client.transcript, named: "client-transcript-on-failure") }
            client.stop()
        }
        client = nil
        try await super.tearDown()
    }

    func testBrowserBridgeEndToEnd() throws {
        try failIfSystemAlertIsShown()
        // The client starts first, so a missing launcher costs seconds, not the whole run.
        let hostURL = try embeddedHostURL()
        let client = try BridgeClient(script: try clientScriptURL(), host: hostURL)
        self.client = client
        let ready = try XCTUnwrap(client.waitForEvent("client-ready", after: 0, timeout: 10) { _ in true },
                                  "The client did not start through NSUserUnixTask:\n\(client.transcript)")
        XCTAssertEqual(ready["parentSandboxed"] as? Bool, false,
                       "The client runs inside the runner's sandbox, so the host cannot get its own:\n\(client.transcript)")
        unlockSuccessfully()
        let databaseWindow = self.databaseWindow

        // 9 (start). A previous run may have left the switch on or a pairing behind.
        openBrowsersSettings()
        removeAllPairings()
        if bridgeSwitchValue() == 1 { bridgeSwitch().click() }
        XCTAssertTrue(waitForSwitch(0), "The bridge switch did not turn off")

        // 2. Switch on through the UI; no unavailability line.
        snap("01-browsers-off")
        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(1), "The bridge switch did not turn on")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        snap("02-browsers-on")
        let unavailable = unavailabilityText()
        XCTAssertNil(unavailable, "Settings ▸ Browsers shows an unavailability line: \(unavailable ?? "")")

        // 3. The client launches the real embedded host.
        let opened = client.send(["cmd": "open"])
        XCTAssertNotNil(client.waitForEvent("host-frame", after: 0, timeout: 10) { _ in true },
                        "The host did not answer within 10 seconds. A host stuck in sandbox initialization waits on a system alert:\n\(client.transcript)")
        XCTAssertEqual(client.waitForResult(opened, timeout: 15)?["state"] as? String, "unpaired",
                       "A fresh client did not reach the app:\n\(client.transcript)")

        // 4. A pairing is shown with the client's code and refused with Return.
        let declined = client.send(["cmd": "pair", "name": Self.browserName])
        let firstCode = try XCTUnwrap(client.waitForEvent("pair-code", id: declined, timeout: 20)?["code"] as? String,
                                      "The client never got a pairing code:\n\(client.transcript)")
        let alertCode = pairingCodeElement()
        XCTAssertTrue(alertCode.waitForExistence(timeout: 10), "No pairing alert appeared")
        XCTAssertEqual(alertCode.value as? String, MacBrowserBridgeUITests.grouped(firstCode),
                       "The alert's code differs from the client's")
        XCTAssertTrue(pairingTitle().waitForExistence(timeout: 5), "The alert does not name the browser")
        let allowAtFirstSight = app.buttons["browser-pairing.allow"].firstMatch.isEnabled
        snap("04-pairing-alert")
        app.typeKey(.return, modifierFlags: [])
        let declineResult = try XCTUnwrap(client.waitForResult(declined, timeout: 15))
        XCTAssertEqual(declineResult["error"] as? String, "pairing-declined", "Return did not decline: \(declineResult)")
        XCTAssertTrue(alertCode.waitForNonExistence(timeout: 5), "The pairing alert stayed after Return")
        XCTAssertFalse(pairedListShows(Self.browserName), "A declined browser is listed as paired")
        attachText("Allow enabled when first queried: \(allowAtFirstSight)", named: "04-allow-state")

        // 5. After the cooldown, pair and allow; then status, matches and credential.
        RunLoop.current.run(until: Date().addingTimeInterval(11))
        let allowed = client.send(["cmd": "pair", "name": Self.browserName])
        let secondCode = try XCTUnwrap(client.waitForEvent("pair-code", id: allowed, timeout: 20)?["code"] as? String,
                                       "The second pairing got no code:\n\(client.transcript)")
        XCTAssertTrue(alertCode.waitForExistence(timeout: 10), "No pairing alert for the second attempt")
        XCTAssertEqual(alertCode.value as? String, MacBrowserBridgeUITests.grouped(secondCode))
        let allow = app.buttons["browser-pairing.allow"].firstMatch
        waitUntilEnabled(allow, timeout: 5)
        XCTAssertTrue(allow.isEnabled, "Allow never became enabled")
        snap("05-pairing-allow-armed")
        allow.click()
        let pairResult = try XCTUnwrap(client.waitForResult(allowed, timeout: 15))
        XCTAssertEqual(pairResult["state"] as? String, "ready", "Allow did not pair: \(pairResult)")

        let status = try request(client, "status")
        XCTAssertEqual(status["unlocked"] as? Int, 1, "status: \(status)")
        let matches = try request(client, "matches", ["origin": Self.origin])
        let entries = matches["entries"] as? [[String: Any]] ?? []
        let alpha = try XCTUnwrap(entries.first { $0["title"] as? String == "Alpha Login" }, "matches: \(matches)")
        XCTAssertEqual(alpha["username"] as? String, "alpha-user")
        XCTAssertEqual(alpha["exact"] as? Bool, true)
        let entry = try XCTUnwrap(alpha["entry"] as? String), db = try XCTUnwrap(alpha["db"] as? String)
        let credential = try request(client, "credential", ["entry": entry, "db": db, "origin": Self.origin])
        XCTAssertEqual(credential["username"] as? String, "alpha-user")
        XCTAssertEqual(credential["password"] as? String, "GroupTagAlpha1")
        XCTAssertNil(credential["totp"])
        // Alpha Login has no code, so a code-only request is unavailable.
        let codeOnly = try request(client, "credential", ["entry": entry, "db": db, "origin": Self.origin, "totp": true])
        XCTAssertEqual(codeOnly["ok"] as? Bool, false)
        XCTAssertEqual(codeOnly["error"] as? String, "unavailable", "code-only: \(codeOnly)")
        XCTAssertNil(codeOnly["password"])

        // 6. Settings lists the browser; Remove… and the same key is unpaired.
        openBrowsersSettings()
        XCTAssertTrue(waitFor { self.pairedListShows(Self.browserName) }, "Settings does not list the paired browser")
        snap("06-paired-browser-listed")
        let remove = pairedRemoveButtons().firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        let beforeRemoval = client.lineCount
        remove.click()
        confirmRemoval()
        XCTAssertTrue(waitFor { !self.pairedListShows(Self.browserName) }, "The removed browser is still listed")
        snap("06-paired-browser-removed")
        let closedByRemoval = client.waitForEvent("state", after: beforeRemoval, timeout: 5) { $0["reason"] as? String == "closed" }
        attachText("Connection closed after removal: \(closedByRemoval != nil)", named: "06-removal-closes")
        _ = client.call(["cmd": "close"])
        let reopened = try XCTUnwrap(client.call(["cmd": "open"], timeout: 20))
        XCTAssertEqual(reopened["reason"] as? String, "unpaired", "A removed browser was not refused: \(reopened)")

        // 7. Pair again; switching off reaches the live connection, and a new connect finds no app.
        let third = client.send(["cmd": "pair", "name": Self.browserName])
        XCTAssertNotNil(client.waitForEvent("pair-code", id: third, timeout: 20), "Third pairing got no code")
        XCTAssertTrue(alertCode.waitForExistence(timeout: 10))
        waitUntilEnabled(allow, timeout: 5)
        allow.click()
        XCTAssertEqual(try XCTUnwrap(client.waitForResult(third, timeout: 15))["state"] as? String, "ready")
        let beforeOff = client.lineCount
        openBrowsersSettings()
        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(0))
        let offState = client.waitForEvent("state", after: beforeOff, timeout: 10) {
            ["disabled", "closed"].contains($0["reason"] as? String ?? "")
        }
        XCTAssertNotNil(offState, "Switching off did not reach the client:\n\(client.transcript)")
        _ = client.call(["cmd": "close"])
        let offOpen = try XCTUnwrap(client.call(["cmd": "open"], timeout: 20))
        XCTAssertEqual(offOpen["state"] as? String, "app-unavailable", "Connect while off: \(offOpen)")
        XCTAssertEqual(offOpen["reason"] as? String, "not-running")
        snap("07-switched-off")

        // 8. Switched on again and locked: matches is locked, and unlock fronts the window.
        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(1))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        _ = client.call(["cmd": "close"])
        let onAgain = try XCTUnwrap(client.call(["cmd": "open"], timeout: 20))
        XCTAssertEqual(onAgain["state"] as? String, "ready", "The paired client did not reconnect: \(onAgain)")
        // The host's launch fronted the Databases window; Lock needs the database window key.
        app.menuBars.menuBarItems["Window"].firstMatch.click()
        let windowItem = app.menuBars.menuBarItems["Window"].menuItems.matching(
            NSPredicate(format: "title == %@ OR title BEGINSWITH %@", "kitchen-sink", "kitchen-sink (")).firstMatch
        XCTAssertTrue(windowItem.waitForExistence(timeout: 5), "No Window-menu item for the database")
        windowItem.click()
        typeCommandShortcut("l")
        XCTAssertTrue(waitForLockedState(in: databaseWindow), "⌘L did not lock the database")
        let lockedMatches = try request(client, "matches", ["origin": Self.origin])
        XCTAssertEqual(lockedMatches["error"] as? String, "locked", "matches while locked: \(lockedMatches)")
        openBrowsersSettings()
        let passwordField = databaseWindow.secureTextFields["unlock.password.field"]
        XCTAssertFalse(waitForKeyboardFocus(passwordField, timeout: 1), "Settings should be key before unlock")
        let unlockReply = try request(client, "unlock", ["db": db])
        XCTAssertEqual(unlockReply["ok"] as? Bool, true, "unlock: \(unlockReply)")
        XCTAssertTrue(waitForKeyboardFocus(passwordField, timeout: 5), "unlock did not front the locked window")
        snap("08-unlock-fronted")

        // 9. Remove All through the UI, then switch off.
        openBrowsersSettings()
        XCTAssertTrue(waitFor { self.pairedListShows(Self.browserName) })
        removeAllPairings()
        XCTAssertTrue(waitFor { !self.pairedListShows(Self.browserName) }, "Remove All left the browser listed")
        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(0))
        snap("09-clean")
        attachText(client.transcript, named: "client-transcript")
        attachText("host: \(hostURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", named: "host-path")
    }

    // MARK: - Start-up state

    /// System agents whose alerts float above every app and take its clicks.
    private static let alertAgents = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                                      "com.apple.accessibility.universalAccessAuthWarn", "com.apple.SecurityAgent"]

    /// A system alert left on screen (a consent or privacy prompt) makes every later step fail
    /// in ways that look like product failures, so it fails the test first, naming the alert.
    private func failIfSystemAlertIsShown() throws {
        var shown: [String] = []
        for identifier in Self.alertAgents {
            let agent = XCUIApplication(bundleIdentifier: identifier)
            guard agent.state != .notRunning else { continue }
            let windows = agent.windows.allElementsBoundByIndex + agent.dialogs.allElementsBoundByIndex
            for window in windows where window.exists && window.frame.width > 1 {
                let texts = window.staticTexts.allElementsBoundByIndex.prefix(3).map(displayText(of:))
                shown.append("\(identifier): \(texts.joined(separator: " / "))")
            }
        }
        guard shown.isEmpty else {
            snap("00-system-alert")
            throw NSError(domain: "MacBrowserBridgeUITests", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "A system alert covers the app, so this run cannot test KeeForge; the owner must dismiss it: "
                + shown.joined(separator: "; ")])
        }
    }

    // MARK: - Client

    private func request(_ client: BridgeClient, _ type: String, _ fields: [String: Any] = [:],
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let reply = client.send(["cmd": "request", "type": type, "fields": fields])
        let result = try XCTUnwrap(client.waitForResult(reply, timeout: 20, any: true),
                                   "\(type) got no reply:\n\(client.transcript)", file: file, line: line)
        if let error = result["error"] as? String, result["done"] as? Bool == false {
            XCTFail("\(type) failed in the client: \(error)\n\(client.transcript)", file: file, line: line)
            return [:]
        }
        return result["result"] as? [String: Any] ?? [:]
    }

    private func embeddedHostURL() throws -> URL {
        // The runner sits beside the app under test in the build products folder.
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = products.appendingPathComponent("KeeForge.app/Contents/MacOS/keeforge-browser-host")
        guard FileManager.default.isExecutableFile(atPath: host.path) else {
            throw NSError(domain: "MacBrowserBridgeUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No embedded host at \(host.path)"])
        }
        return host
    }

    private func clientScriptURL() throws -> URL {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrowserExtension/tools/e2e-client.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(domain: "MacBrowserBridgeUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No client script at \(script.path)"])
        }
        return script
    }

    // MARK: - Settings ▸ Browsers

    private func openBrowsersSettings() {
        // Also fronts a Settings window left behind another window.
        typeCommandShortcut(",")
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 15), "⌘, did not open Settings")
        selectSettingsTab(named: "Browsers")
        XCTAssertTrue(bridgeSwitchQuery.firstMatch.waitForExistence(timeout: 10), "Browsers tab has no switch")
    }

    private var bridgeSwitchQuery: XCUIElementQuery {
        settingsWindow.descendants(matching: .any).matching(identifier: "settings.browsers.toggle")
    }

    private func bridgeSwitch() -> XCUIElement {
        bridgeSwitchQuery.allElementsBoundByIndex.first {
            $0.isHittable && ($0.elementType == .switch || $0.elementType == .checkBox)
        } ?? bridgeSwitchQuery.firstMatch
    }

    private func bridgeSwitchValue() -> Int? {
        bridgeSwitch().value as? Int
    }

    private func waitForSwitch(_ value: Int) -> Bool {
        waitFor { self.bridgeSwitchValue() == value }
    }

    private func unavailabilityText() -> String? {
        let texts = settingsWindow.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "can’t connect", "isn’t signed", "can’t connect", "isn’t signed"))
        guard texts.firstMatch.exists else { return nil }
        return displayText(of: texts.firstMatch)
    }

    private func pairedListShows(_ name: String) -> Bool {
        settingsWindow.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch.exists
    }

    private func pairedRemoveButtons() -> XCUIElementQuery {
        settingsWindow.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'settings.browsers.paired.' AND identifier ENDSWITH '.remove'"))
    }

    private func removeAllPairings() {
        let removeAll = settingsWindow.buttons["settings.browsers.remove-all"].firstMatch
        guard removeAll.waitForExistence(timeout: 2) else { return }
        removeAll.click()
        confirmRemoval()
        XCTAssertTrue(removeAll.waitForNonExistence(timeout: 10), "Remove All did not empty the list")
    }

    private func confirmRemoval() {
        let confirm = app.buttons["settings.browsers.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No removal confirmation")
        confirm.click()
    }

    // MARK: - Pairing alert

    private func pairingCodeElement() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "browser-pairing.code").firstMatch
    }

    private func pairingTitle() -> XCUIElement {
        let title = "Pair with “\(Self.browserName)”?"
        return app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
    }

    static func grouped(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }

    // MARK: - Evidence

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// `e2e-client.mjs`, started outside the runner's sandbox: JSON commands in, JSON lines out.
///
/// The runner is App Sandboxed, so a child it spawns stays in its sandbox and cannot give the host
/// a sandbox of its own. `NSUserUnixTask` runs a script from the runner's Application Scripts
/// folder outside that sandbox, as a browser would start the host.
private final class BridgeClient: @unchecked Sendable {
    static let runnerScriptName = "keeforge-e2e-client"
    private let input = Pipe()
    // Held for the client's lifetime: releasing a pipe closes the end the client writes to.
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [[String: Any]] = []
    private var raw = ""
    private var nextID = 1
    private var finished = false

    init(script: URL, host: URL) throws {
        let scripts = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
        let launcher = scripts?.appendingPathComponent(Self.runnerScriptName)
        guard let launcher, FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw NSError(domain: "MacBrowserBridgeUITests", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "No executable \(launcher?.path ?? "Application Scripts folder (is the runner sandboxed?)"). "
                + "Install BrowserExtension/tools/e2e-client-launcher.sh there as \(Self.runnerScriptName)."])
        }
        let task = try NSUserUnixTask(url: launcher)
        task.standardInput = input.fileHandleForReading
        task.standardOutput = output.fileHandleForWriting
        task.standardError = errors.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            self.lock.withLock { self.raw += "[stderr] " + text }
        }
        task.execute(withArguments: [script.path, "--host", host.path]) { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.finished = true
                self.raw += "[client finished\(error.map { ": \($0.localizedDescription)" } ?? "")]\n"
            }
        }
    }

    var transcript: String { lock.withLock { raw } }
    var lineCount: Int { lock.withLock { lines.count } }

    private func receive(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                raw += String(decoding: line, as: UTF8.self) + "\n"
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { lines.append(object) }
            }
        }
    }

    @discardableResult
    func send(_ command: [String: Any]) -> Int {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        var command = command
        command["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: command) else { return id }
        data.append(0x0A)
        lock.withLock { raw += "> " + String(decoding: data, as: UTF8.self) }
        input.fileHandleForWriting.write(data)
        return id
    }

    /// The `result` of a command that succeeded in the client.
    func call(_ command: [String: Any], timeout: TimeInterval = 20) -> [String: Any]? {
        waitForResult(send(command), timeout: timeout)
    }

    /// The command's `result`, or with `any` the whole reply line, including a failure.
    func waitForResult(_ id: Int, timeout: TimeInterval, any: Bool = false) -> [String: Any]? {
        guard let line = waitFor(after: 0, timeout: timeout, { $0["id"] as? Int == id && $0["done"] != nil }) else { return nil }
        if any { return line }
        if line["done"] as? Bool == true { return line["result"] as? [String: Any] }
        return ["error": line["error"] ?? "unknown"]
    }

    func waitForEvent(_ name: String, id: Int, timeout: TimeInterval) -> [String: Any]? {
        waitFor(after: 0, timeout: timeout) { $0["event"] as? String == name && $0["id"] as? Int == id }
    }

    func waitForEvent(_ name: String, after start: Int, timeout: TimeInterval,
                      _ predicate: @escaping ([String: Any]) -> Bool) -> [String: Any]? {
        waitFor(after: start, timeout: timeout) { $0["event"] as? String == name && predicate($0) }
    }

    private func waitFor(after start: Int, timeout: TimeInterval, _ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let snapshot = lock.withLock { lines }
            if start < snapshot.count, let match = snapshot[start...].first(where: predicate) { return match }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    func stop() {
        if !lock.withLock({ finished }) {
            send(["cmd": "quit"])
            let deadline = Date().addingTimeInterval(3)
            while !lock.withLock({ finished }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        try? input.fileHandleForWriting.close()
    }
}
