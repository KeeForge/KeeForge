#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import KeeForge

/// The panel is built but never ordered front: `present` only records it.
@MainActor
final class MacLargeTypePanelControllerTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let center = NotificationCenter()
    private var presented: [NSPanel] = []

    func testShowBuildsThePanelFromTheModelOverItsWindowWithTheSharingTypeSetAtCreation() async throws {
        let (session, entry, _) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let window = makeWindow()
        for blocksCapture in [true, false] {
            let controller = makeController(blockCapture: blocksCapture)
            controller.showPassword("Vx7$ k", ofEntry: entry.id, in: session, over: window)

            let panel = try XCTUnwrap(controller.panel)
            XCTAssertTrue(presented.last === panel)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(panel.sharingType, blocksCapture ? .none : .readOnly,
                           "Applied before the panel is first shown, not left to the key-window sweep")
            XCTAssertEqual(controller.model, LargeTypeModel(title: "GitHub", fieldName: String(localized: "Password"),
                                                            value: "Vx7$ k"))
            XCTAssertTrue(controller.isShowing(entryID: entry.id, in: session))
            XCTAssertTrue(panel.contentView is NSHostingView<ModifiedContent<MacLargeTypeView, MacHostingAppearance>>)
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(panel.accessibilityIdentifier(), "large-type.panel")
            XCTAssertEqual(panel.frame.midX, window.frame.midX, accuracy: 0.5)
            XCTAssertEqual(panel.frame.midY, window.frame.midY, accuracy: 0.5)
            XCTAssertEqual(panel.frame.size, MacLargeTypePanelController.contentSize(tileCount: 6, maximumHeight: 800))
            controller.close()
        }
    }

    func testEveryKeyClickAndLossOfKeyStatusClosesThePanelAndReleasesThePlaintext() async throws {
        let (session, entry, _) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()
        let window = makeWindow()
        let triggers: [(String, @MainActor (MacLargeTypePanel) throws -> Void)] = [
            ("Escape", { $0.sendEvent(try Self.key("\u{1B}", code: 53)) }),
            ("a letter", { $0.sendEvent(try Self.key("a", code: 0)) }),
            ("a key equivalent", { XCTAssertTrue($0.performKeyEquivalent(with: try Self.key("q", code: 12, flags: .command))) }),
            ("cancel", { $0.cancelOperation(nil) }),
            ("a click", { $0.sendEvent(try Self.mouse(.leftMouseDown)) }),
            ("a right click", { $0.sendEvent(try Self.mouse(.rightMouseDown)) }),
            ("an other-button click", { $0.sendEvent(try Self.mouse(.otherMouseDown)) }),
            ("losing key status", { $0.resignKey() }),
        ]
        for (name, trigger) in triggers {
            controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
            let panel = try XCTUnwrap(controller.panel, name)
            try trigger(panel)
            assertClosed(controller, panel: panel, name)
        }
    }

    func testTheCloseButtonActionClosesThePanel() async throws {
        let (session, entry, _) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()
        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: makeWindow())
        let panel = try XCTUnwrap(controller.panel)
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<ModifiedContent<MacLargeTypeView, MacHostingAppearance>>)

        view.rootView.content.onClose()
        assertClosed(controller, panel: panel, "Close Large Type")
    }

    func testLockContentChangeAndAnotherSelectionCloseThePanel() async throws {
        let (session, entry, other) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()
        let window = makeWindow()

        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        var panel = try XCTUnwrap(controller.panel)
        session.workspace.selectedEntryID = other.id
        await settle()
        assertClosed(controller, panel: panel, "another entry")

        session.workspace.selectedEntryID = entry.id
        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        panel = try XCTUnwrap(controller.panel)
        session.workspace.beginEntrySelection(with: entry.id)
        await settle()
        assertClosed(controller, panel: panel, "a multiple selection")
        session.workspace.endEntrySelection()

        session.workspace.selectedEntryID = entry.id
        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        panel = try XCTUnwrap(controller.panel)
        let revision = session.contentRevision
        try session.setEntryIcon(.standard(iconID: 3), entryID: entry.id)
        XCTAssertNotEqual(session.contentRevision, revision)
        await settle()
        assertClosed(controller, panel: panel, "a content change")

        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        panel = try XCTUnwrap(controller.panel)
        await settle()
        XCTAssertNotNil(controller.panel, "Nothing changed, so it stays open")
        session.lockRequest(force: true)
        await settle()
        assertClosed(controller, panel: panel, "lock")
    }

    func testItsWindowClosingAndTheAppResigningActiveCloseThePanel() async throws {
        let (session, entry, _) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()
        let window = makeWindow()

        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        var panel = try XCTUnwrap(controller.panel)
        center.post(name: NSWindow.willCloseNotification, object: makeWindow())
        XCTAssertNotNil(controller.panel, "Another window closing leaves it open")
        center.post(name: NSWindow.willCloseNotification, object: window)
        assertClosed(controller, panel: panel, "window close")

        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        panel = try XCTUnwrap(controller.panel)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        assertClosed(controller, panel: panel, "resign active")

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertNil(controller.panel, "A closed panel stops observing")
    }

    func testOpeningAnotherReplacesTheOpenPanel() async throws {
        let (session, entry, other) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()
        let window = makeWindow()

        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: window)
        let first = try XCTUnwrap(controller.panel)
        session.workspace.selectedEntryID = other.id
        controller.showPassword("second", ofEntry: other.id, in: session, over: window)

        XCTAssertNil(first.contentView)
        XCTAssertNil(first.onDismiss)
        let second = try XCTUnwrap(controller.panel)
        XCTAssertFalse(second === first)
        XCTAssertEqual(controller.model?.tiles.map(\.character).joined(), "second")
        XCTAssertTrue(controller.isShowing(entryID: other.id, in: session))
        XCTAssertFalse(controller.isShowing(entryID: entry.id, in: session))
        await settle()
        XCTAssertNotNil(controller.panel, "The first panel's selection stamp no longer applies")
    }

    func testNothingShowsWithoutAWindowForAnotherEntryOrWhileLocked() async throws {
        let (session, entry, other) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController()

        controller.showPassword("hunter2", ofEntry: entry.id, in: session)
        XCTAssertNil(controller.panel, "No window shows this session")
        controller.showPassword("hunter2", ofEntry: other.id, in: session, over: makeWindow())
        XCTAssertNil(controller.panel, "Not the selected entry")
        session.lockRequest(force: true)
        controller.show(LargeTypeModel(title: "T", fieldName: "Password", value: "x"), ofEntry: entry.id,
                        in: session, over: makeWindow())
        XCTAssertNil(controller.panel)
        XCTAssertTrue(presented.isEmpty)
    }

    func testAClickThatJustClosedThePanelDoesNotReopenIt() async throws {
        let (session, entry, other) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let clock = TestClock()
        let controller = MacLargeTypePanelController(present: { _ in }, notificationCenter: center,
                                                     windowLookup: { _ in nil }, now: { clock.now })
        XCTAssertFalse(controller.closedJustNow(entryID: entry.id, in: session))
        controller.showPassword("hunter2", ofEntry: entry.id, in: session, over: makeWindow())
        try XCTUnwrap(controller.panel).resignKey()

        XCTAssertTrue(controller.closedJustNow(entryID: entry.id, in: session))
        XCTAssertFalse(controller.closedJustNow(entryID: other.id, in: session))
        clock.now += 1
        XCTAssertFalse(controller.closedJustNow(entryID: entry.id, in: session))
    }

    func testContentSizeFitsTenTilesARowAndScrollsPastTheMaximumHeight() {
        let tile = MacLargeTypePanelController.tileSize
        let chrome = MacLargeTypePanelController.chromeHeight
        XCTAssertEqual(MacLargeTypePanelController.contentSize(tileCount: 19, maximumHeight: 2000),
                       NSSize(width: 10 * tile.width + 9 * 8 + 40, height: chrome + 2 * tile.height + 8))
        XCTAssertEqual(MacLargeTypePanelController.contentSize(tileCount: 3, maximumHeight: 2000).width,
                       MacLargeTypePanelController.minimumWidth)
        XCTAssertEqual(MacLargeTypePanelController.contentSize(tileCount: 0, maximumHeight: 2000).height,
                       chrome + tile.height)
        XCTAssertEqual(MacLargeTypePanelController.contentSize(tileCount: 400, maximumHeight: 600).height, 600)
    }

    // MARK: - Helpers

    private func assertClosed(_ controller: MacLargeTypePanelController, panel: MacLargeTypePanel, _ trigger: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(controller.panel, trigger, file: file, line: line)
        XCTAssertNil(controller.model, "\(trigger) releases the plaintext", file: file, line: line)
        XCTAssertNil(controller.origin, trigger, file: file, line: line)
        XCTAssertNil(panel.contentView, "\(trigger) drops the hosted tiles", file: file, line: line)
        XCTAssertNil(panel.onDismiss, trigger, file: file, line: line)
        XCTAssertFalse(panel.isVisible, trigger, file: file, line: line)
    }

    private func makeController(blockCapture: Bool = true) -> MacLargeTypePanelController {
        MacLargeTypePanelController(blockCapture: { blockCapture }, present: { [weak self] in self?.presented.append($0) },
                                    notificationCenter: center, windowLookup: { _ in nil })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeSession() async throws -> (DatabaseViewModel, KPEntry, KPEntry) {
        let entry = KPEntry(title: "GitHub", password: try EncryptedValue.encrypt("hunter2", using: key))
        let other = KPEntry(title: "Other", password: try EncryptedValue.encrypt("second", using: key))
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry, other]), key: key, bundle: Bundle(for: Self.self)
        )
        session.workspace.selectedEntryID = entry.id
        return (session, entry, other)
    }

    /// The controller observes the session on the next main-actor turn.
    private func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    private static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1000)
}
#endif
