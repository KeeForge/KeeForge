#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import KeeForge

/// Initial focus and Return/Escape routing for the macOS unlock password field,
/// in a window that is never ordered front. `makeFirstResponder` and the field
/// editor's command dispatch do not need the app to be active; typed key events
/// do, so those stay in `MacSmokeUITests`.
@MainActor
final class MacUnlockPasswordFieldTests: XCTestCase {
    private var window: NSWindow!
    private var sidebar: FocusableView!
    private var pendingTurns: [@MainActor @Sendable () -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        sidebar = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        window.contentView?.addSubview(sidebar)
        pendingTurns = []
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        sidebar = nil
        pendingTurns = []
        try await super.tearDown()
    }

    // MARK: - Initial focus lifecycle

    func testAttachingToWindowTakesFocusFromTheSidebar() {
        let focus = makeFocus()
        let field = makeField(focus: focus)

        focusSidebar()
        window.contentView?.addSubview(field)

        XCTAssertTrue(MacInitialFocus.hasFocus(field))
        runNextTurn()
        XCTAssertFalse(focus.isPending)
        XCTAssertTrue(pendingTurns.isEmpty)
    }

    func testFieldCreatedOutsideAWindowFocusesWhenItsContainerIsMounted() {
        let focus = makeFocus()
        let field = makeField(focus: focus)
        let container = NSView(frame: NSRect(x: 200, y: 0, width: 400, height: 400))
        container.addSubview(field)
        XCTAssertTrue(focus.isPending)
        XCTAssertTrue(pendingTurns.isEmpty)

        focusSidebar()
        window.contentView?.addSubview(container)

        XCTAssertTrue(MacInitialFocus.hasFocus(field))
    }

    func testFocusReclaimedByTheSidebarBeforeTheNextTurnIsReapplied() {
        let focus = makeFocus()
        let field = makeField(focus: focus)
        focusSidebar()
        window.contentView?.addSubview(field)

        window.makeFirstResponder(sidebar)
        runNextTurn()

        XCTAssertTrue(MacInitialFocus.hasFocus(field))
        runNextTurn()
        XCTAssertFalse(focus.isPending)
    }

    func testDeliberateFocusChangeBeforeTheNextTurnIsRespected() {
        let focus = makeFocus()
        let field = makeField(focus: focus)
        let otherControl = NSTextField(frame: NSRect(x: 220, y: 200, width: 200, height: 24))
        window.contentView?.addSubview(otherControl)
        focusSidebar()
        window.contentView?.addSubview(field)

        window.makeFirstResponder(otherControl)
        runNextTurn()

        XCTAssertFalse(MacInitialFocus.hasFocus(field))
        XCTAssertTrue(MacInitialFocus.hasFocus(otherControl))
        XCTAssertFalse(focus.isPending)
        XCTAssertTrue(pendingTurns.isEmpty)
    }

    func testFocusIsNotTakenBackAfterInitialFocusSettled() {
        let focus = makeFocus()
        let field = makeField(focus: focus)
        focusSidebar()
        window.contentView?.addSubview(field)
        runNextTurn()

        focusSidebar()
        field.removeFromSuperview()
        window.contentView?.addSubview(field)

        XCTAssertFalse(MacInitialFocus.hasFocus(field))
        XCTAssertTrue(pendingTurns.isEmpty)
    }

    func testResponderThatKeepsReclaimingFocusIsNotFoughtForever() {
        let focus = makeFocus()
        let field = makeField(focus: focus)
        focusSidebar()
        window.contentView?.addSubview(field)

        var turns = 0
        while !pendingTurns.isEmpty {
            window.makeFirstResponder(sidebar)
            runNextTurn()
            turns += 1
            XCTAssertLessThanOrEqual(turns, MacInitialFocus.maximumAttempts)
        }

        XCTAssertFalse(focus.isPending)
    }

    func testDisabledInitialFocusLeavesTheSidebarFocused() {
        let focus = makeFocus(isEnabled: false)
        let field = makeField(focus: focus)
        focusSidebar()

        window.contentView?.addSubview(field)

        XCTAssertTrue(window.firstResponder === sidebar)
        XCTAssertTrue(pendingTurns.isEmpty)
    }

    // MARK: - Hosted in SwiftUI

    func testHostedSecureFieldBecomesFirstResponderAfterMounting() throws {
        let host = NSHostingView(rootView: makeRepresentable(isSecure: true))
        host.frame = NSRect(x: 200, y: 0, width: 400, height: 400)

        focusSidebar()
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(waitForField(in: host))
        XCTAssertTrue(field is NSSecureTextField)
        XCTAssertEqual(field.accessibilityIdentifier(), "unlock.password.field")
        XCTAssertTrue(waitUntil { MacInitialFocus.hasFocus(field) }, "Unlock field did not take focus from the sidebar")
    }

    func testHostedVisibleFieldBecomesFirstResponderAfterMounting() throws {
        let host = NSHostingView(rootView: makeRepresentable(isSecure: false))
        host.frame = NSRect(x: 200, y: 0, width: 400, height: 400)

        focusSidebar()
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(waitForField(in: host))
        XCTAssertFalse(field is NSSecureTextField)
        XCTAssertTrue(waitUntil { MacInitialFocus.hasFocus(field) }, "Unlock field did not take focus from the sidebar")
    }

    // MARK: - Field editor routing

    func testEscapeAndReturnFromTheFieldEditorReachTheCallbacks() throws {
        var escapes = 0
        var submits = 0
        let host = NSHostingView(rootView: makeRepresentable(
            isSecure: true,
            onSubmit: { submits += 1 },
            onEscape: { escapes += 1 }
        ))
        host.frame = NSRect(x: 200, y: 0, width: 400, height: 400)
        focusSidebar()
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(waitForField(in: host))
        XCTAssertTrue(waitUntil { MacInitialFocus.hasFocus(field) })
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(submits, 0)

        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(submits, 1)
    }

    func testCoordinatorHandlesOnlyEscapeAndReturn() {
        var escapes = 0
        var submits = 0
        let coordinator = MacUnlockPasswordField.Coordinator(makeRepresentable(
            isSecure: true,
            onSubmit: { submits += 1 },
            onEscape: { escapes += 1 }
        ))
        let field = NSSecureTextField()
        let textView = NSTextView()

        XCTAssertTrue(coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(coordinator.control(field, textView: textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(submits, 1)
    }

    func testTextChangesUpdateTheBinding() {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let coordinator = MacUnlockPasswordField.Coordinator(makeRepresentable(isSecure: true, text: binding))
        let field = NSSecureTextField()
        field.stringValue = "hunter2"

        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        XCTAssertEqual(text, "hunter2")
    }

    // MARK: - Helpers

    private func focusSidebar(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.makeFirstResponder(sidebar), file: file, line: line)
        XCTAssertTrue(window.firstResponder === sidebar, file: file, line: line)
    }

    private func makeFocus(isEnabled: Bool = true) -> MacInitialFocus {
        MacInitialFocus(isEnabled: isEnabled) { [weak self] work in
            self?.pendingTurns.append(work)
        }
    }

    private func makeField(focus: MacInitialFocus) -> NSTextField {
        let field = MacUnlockSecureTextField(frame: NSRect(x: 220, y: 100, width: 200, height: 24))
        field.onMoveToWindow = { focus.fieldDidMoveToWindow($0) }
        return field
    }

    private func runNextTurn() {
        let turns = pendingTurns
        pendingTurns = []
        turns.forEach { $0() }
    }

    private func makeRepresentable(
        isSecure: Bool,
        text: Binding<String> = .constant(""),
        onSubmit: @escaping () -> Void = {},
        onEscape: @escaping () -> Void = {}
    ) -> MacUnlockPasswordField {
        MacUnlockPasswordField(
            text: text,
            isSecure: isSecure,
            placeholder: "Enter password",
            accessibilityIdentifier: "unlock.password.field",
            focusOnAppear: true,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
    }

    private func waitForField(in view: NSView) -> NSTextField? {
        var field: NSTextField?
        _ = waitUntil {
            field = Self.firstTextField(in: view)
            return field != nil
        }
        return field
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if view is MacUnlockSecureTextField || view is MacUnlockPlainTextField {
            return view as? NSTextField
        }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return true
    }
}

/// Stands in for the sidebar outline that holds focus when a database row is clicked.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
#endif
