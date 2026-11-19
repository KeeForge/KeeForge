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

    private var client: E2EDriverProcess?

    override func tearDown() async throws {
        if let client {
            if (testRun?.totalFailureCount ?? 0) > 0 { attachText(client.transcript, named: "client-transcript-on-failure") }
            client.stop()
        }
        client = nil
        try await super.tearDown()
    }

    func testBrowserBridgeEndToEnd() throws {
        try failIfSystemAlertIsShown()
        // The client starts first, so a missing launcher costs seconds, not the whole run.
        let hostURL = try embeddedHostURL()
        let client = try E2EDriverProcess(script: try browserToolURL("e2e-client.mjs"), arguments: ["--host", hostURL.path])
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
        XCTAssertTrue(pairingTitle(browser: Self.browserName).waitForExistence(timeout: 5), "The alert does not name the browser")
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
        frontDatabaseWindow(named: "kitchen-sink")
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

    // MARK: - Client

    private func request(_ client: E2EDriverProcess, _ type: String, _ fields: [String: Any] = [:],
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
}
