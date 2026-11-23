import AppKit
import XCTest

/// Shared by the browser-bridge end-to-end classes: start-up checks, Settings ▸ Browsers,
/// the pairing alert, the paths of the embedded host and the Node drivers, and evidence.
extension MacUITestCase {
    // MARK: - Start-up state

    /// System agents whose alerts float above every app and take its clicks.
    private static var alertAgents: [String] {
        ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
         "com.apple.accessibility.universalAccessAuthWarn", "com.apple.SecurityAgent"]
    }

    /// A system alert left on screen (a consent or privacy prompt) makes every later step fail
    /// in ways that look like product failures, so it fails the test first, naming the alert.
    func failIfSystemAlertIsShown() throws {
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
            throw NSError(domain: "KeeForgeMacUITests", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "A system alert covers the app, so this run cannot test KeeForge; the owner must dismiss it: "
                + shown.joined(separator: "; ")])
        }
    }

    // MARK: - Paths

    func embeddedHostURL() throws -> URL {
        // The runner sits beside the app under test in the build products folder.
        let products = Bundle(for: MacUITestCase.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = products.appendingPathComponent("KeeForge.app/Contents/MacOS/keeforge-browser-host")
        guard FileManager.default.isExecutableFile(atPath: host.path) else {
            throw NSError(domain: "KeeForgeMacUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No embedded host at \(host.path)"])
        }
        return host
    }

    /// A driver in `BrowserExtension/tools/` of the source tree this runner was built from.
    func browserToolURL(_ name: String) throws -> URL {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrowserExtension/tools/\(name)")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(domain: "KeeForgeMacUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No driver script at \(script.path)"])
        }
        return script
    }

    // MARK: - Settings ▸ Browsers

    func openBrowsersSettings() {
        // Also fronts a Settings window left behind another window.
        typeCommandShortcut(",")
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 15), "⌘, did not open Settings")
        selectSettingsTab(named: "Browsers")
        XCTAssertTrue(bridgeSwitchQuery.firstMatch.waitForExistence(timeout: 10), "Browsers tab has no switch")
    }

    private var bridgeSwitchQuery: XCUIElementQuery {
        settingsWindow.descendants(matching: .any).matching(identifier: "settings.browsers.toggle")
    }

    func bridgeSwitch() -> XCUIElement {
        bridgeSwitchQuery.allElementsBoundByIndex.first {
            $0.isHittable && ($0.elementType == .switch || $0.elementType == .checkBox)
        } ?? bridgeSwitchQuery.firstMatch
    }

    func bridgeSwitchValue() -> Int? {
        bridgeSwitch().value as? Int
    }

    func waitForSwitch(_ value: Int) -> Bool {
        waitFor { self.bridgeSwitchValue() == value }
    }

    /// Leaves the bridge on, with no pairing and no unavailability line.
    func switchBridgeOnFromClean() {
        openBrowsersSettings()
        removeAllPairings()
        if bridgeSwitchValue() == 1 { bridgeSwitch().click() }
        XCTAssertTrue(waitForSwitch(0), "The bridge switch did not turn off")
        bridgeSwitch().click()
        XCTAssertTrue(waitForSwitch(1), "The bridge switch did not turn on")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let unavailable = unavailabilityText()
        XCTAssertNil(unavailable, "Settings ▸ Browsers shows an unavailability line: \(unavailable ?? "")")
    }

    func unavailabilityText() -> String? {
        let texts = settingsWindow.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "can’t connect", "isn’t signed", "can’t connect", "isn’t signed"))
        guard texts.firstMatch.exists else { return nil }
        return displayText(of: texts.firstMatch)
    }

    func pairedListShows(_ name: String) -> Bool {
        settingsWindow.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch.exists
    }

    func pairedRemoveButtons() -> XCUIElementQuery {
        settingsWindow.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'settings.browsers.paired.' AND identifier ENDSWITH '.remove'"))
    }

    func removeAllPairings() {
        let removeAll = settingsWindow.buttons["settings.browsers.remove-all"].firstMatch
        guard removeAll.waitForExistence(timeout: 2) else { return }
        removeAll.click()
        confirmRemoval()
        XCTAssertTrue(removeAll.waitForNonExistence(timeout: 10), "Remove All did not empty the list")
    }

    func confirmRemoval() {
        let confirm = app.buttons["settings.browsers.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No removal confirmation")
        confirm.click()
    }

    // MARK: - Pairing alert

    func pairingCodeElement() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "browser-pairing.code").firstMatch
    }

    func pairingTitle(browser: String) -> XCUIElement {
        let title = "Pair with “\(browser)”?"
        return app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
    }

    /// The six-digit code as the alert shows it.
    static func grouped(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// Fronts the database window, which ⌘L needs as key; launching the host can front the Databases window.
    func frontDatabaseWindow(named name: String) {
        app.menuBars.menuBarItems["Window"].firstMatch.click()
        let windowItem = app.menuBars.menuBarItems["Window"].menuItems.matching(
            NSPredicate(format: "title == %@ OR title BEGINSWITH %@", name, "\(name) (")).firstMatch
        XCTAssertTrue(windowItem.waitForExistence(timeout: 5), "No Window-menu item for the database")
        windowItem.click()
    }

    // MARK: - Evidence

    func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A Node driver in `BrowserExtension/tools/`, started outside the runner's sandbox: JSON commands
/// in, JSON lines out.
///
/// The runner is App Sandboxed, so a child it spawns stays in its sandbox and cannot give the host
/// a sandbox of its own. `NSUserUnixTask` runs a script from the runner's Application Scripts
/// folder outside that sandbox, as a browser would start the host.
final class E2EDriverProcess: @unchecked Sendable {
    static let runnerScriptName = "keeforge-e2e-client"
    private let input = Pipe()
    // Held for the driver's lifetime: releasing a pipe closes the end the driver writes to.
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [[String: Any]] = []
    private var raw = ""
    private var nextID = 1
    private var finished = false

    init(script: URL, arguments: [String]) throws {
        let scripts = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
        let launcher = scripts?.appendingPathComponent(Self.runnerScriptName)
        guard let launcher, FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw NSError(domain: "KeeForgeMacUITests", code: 3, userInfo: [NSLocalizedDescriptionKey:
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
        task.execute(withArguments: [script.path] + arguments) { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.finished = true
                self.raw += "[driver finished\(error.map { ": \($0.localizedDescription)" } ?? "")]\n"
            }
        }
    }

    var transcript: String { lock.withLock { raw } }
    var lineCount: Int { lock.withLock { lines.count } }
    var isFinished: Bool { lock.withLock { finished } }

    private func receive(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                // Screenshots travel as base64; the transcript keeps only their size.
                if let png = (object?["result"] as? [String: Any])?["png"] as? String {
                    raw += "{\"id\":\(object?["id"] ?? 0),\"done\":true,\"result\":{\"png\":\"<\(png.count) base64 characters>\"}}\n"
                } else {
                    raw += String(decoding: line, as: UTF8.self) + "\n"
                }
                if let object { lines.append(object) }
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

    /// The `result` of a command that succeeded in the driver.
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

    func stop(timeout: TimeInterval = 3) {
        if !isFinished {
            send(["cmd": "quit"])
            let deadline = Date().addingTimeInterval(timeout)
            while !isFinished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        try? input.fileHandleForWriting.close()
    }
}
