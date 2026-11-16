#if os(macOS)
import AppKit
import Observation
import XCTest
@testable import KeeForge

@MainActor
final class MacBrowserBridgePromptsTests: XCTestCase {
    @MainActor @Observable
    final class Source: MacBrowserPairingSource {
        var pendingPairing: MacBrowserBridgeController.PendingPairing?
        var pairingFailed = false
        @ObservationIgnored var answers: [Bool] = []
        @ObservationIgnored var answeredIDs: [UUID] = []
        @ObservationIgnored var failureClears = 0

        func answerPairing(id: UUID, allow: Bool) {
            answers.append(allow)
            answeredIDs.append(id)
            pendingPairing = nil
        }

        func clearPairingFailure() {
            failureClears += 1
            pairingFailed = false
        }
    }

    @MainActor
    final class Shell: MacBrowserBridgeShell {
        enum Call: Equatable {
            case activate
            case requestAttention
            case showDatabaseWindow(UUID)
            case showDatabasesWindow
            case revealEntry(UUID, UUID)
            case showPairing(MacBrowserPairingAlertContent)
            case dismissPairing
            case showPairingFailure
        }

        var calls: [Call] = []
        var states: [UUID: MacBrowserBridgeWindowState] = [:]
        var answers: [@MainActor (Bool) -> Void] = []
        var visiblePairingAlerts = 0
        var mostVisiblePairingAlerts = 0
        var isActive = true

        func activate() { calls.append(.activate) }
        func requestAttention() { calls.append(.requestAttention) }
        func windowState(of databaseID: UUID) -> MacBrowserBridgeWindowState { states[databaseID] ?? .closed }
        func showDatabaseWindow(_ databaseID: UUID) { calls.append(.showDatabaseWindow(databaseID)) }
        func showDatabasesWindow() { calls.append(.showDatabasesWindow) }
        func revealEntry(_ entryID: UUID, in databaseID: UUID) { calls.append(.revealEntry(entryID, databaseID)) }

        func showPairing(_ content: MacBrowserPairingAlertContent, answer: @escaping @MainActor (Bool) -> Void) {
            calls.append(.showPairing(content))
            answers.append(answer)
            visiblePairingAlerts += 1
            mostVisiblePairingAlerts = max(mostVisiblePairingAlerts, visiblePairingAlerts)
        }

        func dismissPairing() {
            calls.append(.dismissPairing)
            visiblePairingAlerts -= 1
        }

        func showPairingFailure() { calls.append(.showPairingFailure) }

        /// A click: the alert is gone before the answer runs.
        func click(_ index: Int, allow: Bool) {
            visiblePairingAlerts -= 1
            answers[index](allow)
        }
    }

    private func settle() async { for _ in 0..<8 { await Task { @MainActor in }.value } }

    private func pending(_ name: String = "Firefox", code: String = "012345") -> MacBrowserBridgeController.PendingPairing {
        MacBrowserBridgeController.PendingPairing(id: UUID(), browserName: name, code: code)
    }

    // MARK: - Pairing

    func testPendingPairingFrontsKeeForgeAndShowsOneAlert() async {
        let source = Source()
        let shell = Shell()
        let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
        XCTAssertTrue(shell.calls.isEmpty, "Nothing is shown while no pairing waits")

        source.pendingPairing = pending()
        await settle()
        let content = MacBrowserPairingAlertContent(browserName: "Firefox", code: "012345")
        XCTAssertEqual(shell.calls, [.activate, .showPairing(content)])
        XCTAssertEqual(content.title, String(localized: "Pair with “\("Firefox")”?"))
        XCTAssertEqual(content.code, "012 345")
        XCTAssertTrue(source.answers.isEmpty, "Showing the alert answers nothing")

        source.pendingPairing = pending("Chrome", code: "999999")
        await settle()
        XCTAssertEqual(shell.calls.suffix(3), [.dismissPairing, .activate,
            .showPairing(MacBrowserPairingAlertContent(browserName: "Chrome", code: "999999"))])
        XCTAssertEqual(shell.mostVisiblePairingAlerts, 1, "A second pairing never stacks a second alert")
        XCTAssertTrue(source.answers.isEmpty)
        withExtendedLifetime(prompts) {}
    }

    func testAllowAndDontAllowAnswerOnceWithTheirValue() async {
        for allow in [true, false] {
            let source = Source()
            let shell = Shell()
            let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
            let shown = pending()
            source.pendingPairing = shown
            await settle()
            shell.click(0, allow: allow)
            shell.answers[0](allow)
            shell.answers[0](!allow)
            await settle()
            XCTAssertEqual(source.answers, [allow], "Exactly one answer, with the clicked value")
            XCTAssertEqual(source.answeredIDs, [shown.id], "The answer names the pairing the alert showed")
            XCTAssertFalse(shell.calls.contains(.dismissPairing), "An answered alert is not dismissed again")
            XCTAssertEqual(shell.calls.filter { if case .showPairing = $0 { true } else { false } }.count, 1)
            withExtendedLifetime(prompts) {}
        }
    }

    func testPairingEndedElsewhereDismissesWithoutAnswering() async {
        // The controller clears `pendingPairing` on timeout, when the browser goes away, and when the bridge is switched off.
        for ending in ["timeout", "browser closed", "bridge switched off"] {
            let source = Source()
            let shell = Shell()
            let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
            source.pendingPairing = pending()
            await settle()
            source.pendingPairing = nil
            await settle()
            XCTAssertEqual(shell.calls.last, .dismissPairing, ending)
            XCTAssertEqual(shell.visiblePairingAlerts, 0, ending)
            shell.answers[0](true)
            XCTAssertTrue(source.answers.isEmpty, "\(ending): a late answer does nothing")

            source.pendingPairing = pending()
            await settle()
            shell.answers[0](true)
            XCTAssertTrue(source.answers.isEmpty, "\(ending): the old alert's answer never reaches a new pairing")
            shell.click(1, allow: false)
            XCTAssertEqual(source.answers, [false], ending)
            withExtendedLifetime(prompts) {}
        }
    }

    func testFailureIsShownOnceAndCleared() async {
        let source = Source()
        let shell = Shell()
        let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
        source.pairingFailed = true
        await settle()
        XCTAssertEqual(shell.calls, [.activate, .showPairingFailure])
        XCTAssertEqual(source.failureClears, 1)
        XCTAssertFalse(source.pairingFailed)
        await settle()
        XCTAssertEqual(shell.calls, [.activate, .showPairingFailure], "The failure is reported once")
        withExtendedLifetime(prompts) {}
    }

    func testRefusedActivationRequestsAttentionForEveryFront() async {
        let source = Source()
        let shell = Shell()
        shell.isActive = false
        let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
        let content = MacBrowserPairingAlertContent(browserName: "Firefox", code: "012345")
        source.pendingPairing = pending()
        await settle()
        XCTAssertEqual(shell.calls, [.activate, .requestAttention, .showPairing(content)])
        source.pairingFailed = true
        await settle()
        XCTAssertEqual(shell.calls.suffix(3), [.activate, .requestAttention, .showPairingFailure])
        shell.calls = []
        prompts.unlock(databaseID: nil)
        prompts.reveal(entryID: UUID(), databaseID: UUID())
        XCTAssertEqual(shell.calls, [.activate, .requestAttention, .showDatabasesWindow,
                                     .activate, .requestAttention, .showDatabasesWindow])
        shell.isActive = true
        shell.calls = []
        prompts.unlock(databaseID: nil)
        XCTAssertEqual(shell.calls, [.activate, .showDatabasesWindow], "An active app asks for no attention")
    }

    func testCodeIsGroupedAsTwoTriplesKeepingLeadingZeros() {
        XCTAssertEqual(MacBrowserPairingAlertContent.groupedCode("000007"), "000 007")
        XCTAssertEqual(MacBrowserPairingAlertContent.groupedCode("123456"), "123 456")
        XCTAssertEqual(MacBrowserPairingAlertContent(browserName: "B", code: "000007").codeAccessibilityLabel, "0 0 0 0 0 7")
    }

    func testBrowserNameIsPlainSanitizedText() {
        let name = "Evil\u{202E}\n<b>Browser</b>" + String(repeating: "x", count: 100)
        let content = MacBrowserPairingAlertContent(browserName: name, code: "123456")
        let expected = BrowserPairingStore.sanitizedName(name)
        XCTAssertFalse(expected.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(expected.count, 64)
        XCTAssertEqual(content.title, String(localized: "Pair with “\(expected)”?"))
        let alert = MacBrowserPairingAlert.make(content)
        XCTAssertEqual(alert.messageText, content.title, "Markup is shown as typed, never rendered")
        let unnamed = MacBrowserPairingAlertContent(browserName: "\u{202E}\n", code: "123456")
        XCTAssertEqual(unnamed.title, String(localized: "Pair with “\(String(localized: "Unnamed browser"))”?"))
    }

    func testAlertDefaultsToDontAllowOnReturnAndEscape() throws {
        let alert = MacBrowserPairingAlert.make(MacBrowserPairingAlertContent(browserName: "Safari", code: "042042"))
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Don’t Allow"), String(localized: "Allow")])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return refuses")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "", "Return never allows")
        let escape = try XCTUnwrap(alert.window.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.keyEquivalent == "\u{1b}" })
        XCTAssertTrue(escape.target === alert.buttons[0], "Escape refuses")
        let code = try XCTUnwrap(alert.accessoryView as? NSTextField)
        XCTAssertEqual(code.stringValue, "042 042")
        XCTAssertEqual(MacBrowserPairingAlert.allows(.alertFirstButtonReturn), false)
        XCTAssertEqual(MacBrowserPairingAlert.allows(.alertSecondButtonReturn), true)
        XCTAssertNil(MacBrowserPairingAlert.allows(.cancel), "A dismissed alert answers nothing")
    }

    /// With Full Keyboard Access, Space presses the focused button; AppKit would focus Allow, the non-default one.
    func testAllowStartsDisabledUnfocusableAndUnarmedUntilArmed() throws {
        let alert = MacBrowserPairingAlert.make(MacBrowserPairingAlertContent(browserName: "Safari", code: "042042"))
        let refuse = alert.buttons[0], allow = alert.buttons[1]
        XCTAssertFalse(allow.isEnabled)
        XCTAssertTrue(allow.refusesFirstResponder)
        XCTAssertFalse(allow.canBecomeKeyView)
        XCTAssertTrue(alert.window.initialFirstResponder === refuse)
        XCTAssertFalse(MacBrowserPairingAlert.isArmed(alert))
        alert.layout()
        MacBrowserPairingAlert.focusRefusal(in: alert)
        XCTAssertTrue(alert.window.initialFirstResponder === refuse, "Layout does not hand initial focus to Allow")
        XCTAssertFalse(alert.window.firstResponder === allow)
        XCTAssertFalse(allow.acceptsFirstResponder, "Allow cannot take focus before it is armed")
        MacBrowserPairingAlert.arm(alert)
        XCTAssertTrue(allow.isEnabled)
        XCTAssertFalse(allow.refusesFirstResponder, "Once armed, a keyboard user can reach Allow with Tab")
        XCTAssertTrue(MacBrowserPairingAlert.isArmed(alert))
        XCTAssertEqual(MacBrowserPairingAlert.allowDelay, .milliseconds(1500))
    }

    // MARK: - Reveal and unlock

    func testRevealFrontsTheWindowAndSelectsOnlyWhenUnlocked() {
        let source = Source()
        let shell = Shell()
        let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
        let database = UUID(), entry = UUID()

        shell.states[database] = .unlocked
        prompts.reveal(entryID: entry, databaseID: database)
        XCTAssertEqual(shell.calls, [.activate, .showDatabaseWindow(database), .revealEntry(entry, database)])

        for state in [MacBrowserBridgeWindowState.locked, .editing] {
            shell.calls = []
            shell.states[database] = state
            prompts.reveal(entryID: entry, databaseID: database)
            XCTAssertEqual(shell.calls, [.activate, .showDatabaseWindow(database)], "\(state): front and stop")
        }

        shell.calls = []
        prompts.reveal(entryID: entry, databaseID: UUID())
        XCTAssertEqual(shell.calls, [.activate, .showDatabasesWindow], "An unknown database fronts the Databases window")
    }

    func testUnlockFrontsTheNamedWindowOrTheDatabasesWindow() {
        let source = Source()
        let shell = Shell()
        let prompts = MacBrowserBridgePrompts(source: source, shell: shell)
        let locked = UUID(), unlocked = UUID()
        shell.states = [locked: .locked, unlocked: .unlocked]

        prompts.unlock(databaseID: locked)
        XCTAssertEqual(shell.calls, [.activate, .showDatabaseWindow(locked)])
        shell.calls = []
        prompts.unlock(databaseID: unlocked)
        XCTAssertEqual(shell.calls, [.activate, .showDatabaseWindow(unlocked)])
        shell.calls = []
        prompts.unlock(databaseID: nil)
        XCTAssertEqual(shell.calls, [.activate, .showDatabasesWindow])
        shell.calls = []
        prompts.unlock(databaseID: UUID())
        XCTAssertEqual(shell.calls, [.activate, .showDatabasesWindow], "A database with no window fronts the Databases window")
        XCTAssertFalse(shell.calls.contains { if case .revealEntry = $0 { true } else { false } })
    }
}
#endif
