#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacAlertQueueTests: XCTestCase {
    /// Records each alert shown and holds its answer until the test gives it.
    @MainActor
    private final class Presenter {
        var shown: [NSAlert] = []
        var answers: [@MainActor (NSApplication.ModalResponse) -> Void] = []
        var titles: [String] { shown.map(\.messageText) }

        func present(_ alert: NSAlert, _ parent: NSWindow?, _ completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
            shown.append(alert)
            answers.append(completion)
        }

        func answer(_ index: Int, _ response: NSApplication.ModalResponse = .alertFirstButtonReturn) {
            answers[index](response)
        }
    }

    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    // MARK: - Queue

    func testAnAlertRaisedWhileAnotherIsUpWaitsForTheAnswerAndFollowUpsAreNeverDropped() {
        let presenter = Presenter()
        let queue = MacAlertQueue(window: makeWindow(), present: presenter.present)
        var order: [String] = []
        queue.enqueue(alert("First")) { _ in
            order.append("first answered")
            queue.enqueue(self.alert("Follow-up")) { _ in order.append("follow-up answered") }
        }
        queue.enqueue(alert("Second")) { response in order.append("second \(response == .alertSecondButtonReturn)") }
        XCTAssertEqual(presenter.titles, ["First"], "Only one alert at a time")
        XCTAssertEqual(queue.queuedCount, 1)

        presenter.answer(0)
        XCTAssertEqual(order, ["first answered"])
        XCTAssertEqual(presenter.titles, ["First", "Second"], "The waiting alert comes next")
        XCTAssertEqual(queue.queuedCount, 1, "The follow-up raised by the answer queues behind it")

        presenter.answer(1, .alertSecondButtonReturn)
        presenter.answer(2)
        XCTAssertEqual(order, ["first answered", "second true", "follow-up answered"])
        XCTAssertEqual(presenter.titles, ["First", "Second", "Follow-up"])
        XCTAssertNil(queue.presentedAlert)
    }

    func testEndAndWindowCloseDropTheQueueAndIgnoreLateAnswers() {
        for closeWindow in [true, false] {
            let presenter = Presenter()
            let window = makeWindow()
            let queue = MacAlertQueue(window: window, present: presenter.present)
            var answered = 0
            queue.enqueue(alert("Shown")) { _ in answered += 1 }
            queue.enqueue(alert("Waiting")) { _ in answered += 1 }
            if closeWindow { window.close() } else { queue.end() }
            XCTAssertNil(queue.presentedAlert)
            XCTAssertEqual(queue.queuedCount, 0)
            presenter.answer(0)
            XCTAssertEqual(answered, 0, "An answer from before the end does nothing")
            XCTAssertEqual(presenter.titles, ["Shown"], "Nothing queued before the end is shown")
            if !closeWindow {
                queue.enqueue(alert("Later")) { _ in answered += 1 }
                presenter.answer(1)
                XCTAssertEqual(answered, 1, "The queue keeps working after an end")
            }
        }
    }

    func testARealSheetStillDetachingHoldsTheNextAlertAndTheQueueMovesOn() async throws {
        let window = makeWindow()
        let queue = MacAlertQueue(window: window)
        queue.enqueue(alert("First")) { _ in }
        try XCTSkipUnless(window.attachedSheet != nil, "AppKit attached no sheet to a window that was never shown")
        let first = try XCTUnwrap(queue.presentedAlert)
        XCTAssertTrue(window.attachedSheet === first.window)
        var answered: [NSApplication.ModalResponse] = []
        queue.cancel(first)
        queue.enqueue(alert("Second")) { answered.append($0) }
        for _ in 0..<50 where queue.presentedAlert?.messageText != "Second" { await settle() }
        XCTAssertEqual(queue.presentedAlert?.messageText, "Second", "The queue does not stall behind a detaching sheet")
        let second = try XCTUnwrap(queue.presentedAlert)
        XCTAssertNil(first.window.sheetParent)
        XCTAssertTrue(window.attachedSheet === second.window)
        window.endSheet(second.window, returnCode: .alertFirstButtonReturn)
        for _ in 0..<50 where answered.isEmpty { await settle() }
        XCTAssertEqual(answered, [.alertFirstButtonReturn], "The answer runs once the sheet has detached")
        XCTAssertNil(queue.presentedAlert)
        queue.end()
    }

    // MARK: - Databases window

    func testRemoveConfirmationRechecksAndQueuesTheRefusalBehindIt() async throws {
        let reference = try register()
        var unsaved = false
        var removed: [UUID] = []
        let launcher = MacDatabasesLauncherViewModel(references: { [reference] })
        launcher.hasUnsavedWork = { _ in unsaved }
        launcher.removeDatabase = { removed.append($0.id) }
        let presenter = Presenter()
        let alerts = MacDatabasesAlerts(window: makeWindow(), launcher: launcher, list: DatabaseListViewModel(),
            panels: MacFilePanels(present: { _, _ in nil }), present: presenter.present)

        launcher.beginRemoval(reference)
        await settle()
        XCTAssertEqual(presenter.titles, [String(localized: "Remove Database?")])
        XCTAssertEqual(launcher.pendingRemoval?.id, reference.id, "The request stands until it is answered")
        XCTAssertEqual(presenter.shown[0].buttons.first?.accessibilityIdentifier(), "databases.remove.confirm")

        launcher.renameTarget = reference
        await settle()
        XCTAssertEqual(presenter.shown.count, 1, "Rename waits while Remove is up")

        unsaved = true
        presenter.answer(0)
        await settle()
        XCTAssertTrue(removed.isEmpty, "Confirming checks for unsaved work again")
        XCTAssertNil(launcher.pendingRemoval)
        XCTAssertEqual(launcher.refusedRemoval?.id, reference.id)
        XCTAssertEqual(presenter.titles, [String(localized: "Remove Database?"), String(localized: "Rename Database")])
        presenter.answer(1, .alertSecondButtonReturn)
        await settle()
        XCTAssertNil(launcher.renameTarget)
        XCTAssertEqual(presenter.titles.last, String(localized: "Can’t Remove Database"),
                       "The refusal raised while the confirmation ended is shown, not dropped")
        presenter.answer(2)
        XCTAssertNil(launcher.refusedRemoval)

        launcher.selectionAlert = DocumentPickerService.SelectionAlert(title: "Withdrawn", message: "")
        await settle()
        XCTAssertEqual(presenter.titles.last, "Withdrawn")
        launcher.selectionAlert = nil
        await settle()
        unsaved = false
        launcher.beginRemoval(reference)
        await settle()
        XCTAssertEqual(presenter.titles.last, String(localized: "Remove Database?"),
                       "A request cleared elsewhere withdraws its alert and the queue moves on")
        presenter.answer(4)
        await waitUntil { !removed.isEmpty }
        XCTAssertEqual(removed, [reference.id])
        alerts.end()
    }

    func testRenameDiscardSelectionAndKeyFileGoThroughNativePrompts() async throws {
        let reference = try register()
        let list = DatabaseListViewModel()
        list.reload()
        let launcher = MacDatabasesLauncherViewModel(references: { [reference] })
        let presenter = Presenter()
        let keyFile = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var panelRequests = 0
        let alerts = MacDatabasesAlerts(window: makeWindow(), launcher: launcher, list: list,
            panels: MacFilePanels(present: { _, _ in panelRequests += 1; return keyFile }), present: presenter.present)

        launcher.renameTarget = reference
        await settle()
        let field = try XCTUnwrap(presenter.shown[0].accessoryView as? NSTextField)
        field.stringValue = "  Work Vault  "
        presenter.answer(0)
        XCTAssertEqual(DatabaseListStore.databases.first?.nickname, "Work Vault", "Save trims the name")

        launcher.renameTarget = reference
        await settle()
        let second = try XCTUnwrap(presenter.shown[1].accessoryView as? NSTextField)
        XCTAssertEqual(second.stringValue, "Work Vault")
        second.stringValue = "Ignored"
        presenter.answer(1, .alertSecondButtonReturn)
        XCTAssertEqual(DatabaseListStore.databases.first?.nickname, "Work Vault", "Cancel changes nothing")

        launcher.pendingUploadDiscardTarget = reference
        await settle()
        XCTAssertEqual(presenter.titles.last, String(localized: "Discard Pending Upload?"))
        XCTAssertTrue(presenter.shown[2].buttons.first?.hasDestructiveAction == true)
        presenter.answer(2, .alertSecondButtonReturn)

        launcher.selectionAlert = DocumentPickerService.SelectionAlert(title: "Couldn’t Use File", message: "Reason")
        await settle()
        XCTAssertEqual(presenter.titles.last, "Couldn’t Use File")
        presenter.answer(3)

        launcher.keyFileTarget = reference
        await settle()
        await settle()
        await waitUntil { DatabaseListStore.databases.first?.keyFileFilename == keyFile.lastPathComponent }
        XCTAssertEqual(panelRequests, 1)
        XCTAssertNil(launcher.keyFileTarget)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while DatabaseListStore.databases.first?.keyFileFilename != keyFile.lastPathComponent,
              launcher.selectionAlert == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(launcher.selectionAlert)
        XCTAssertEqual(DatabaseListStore.databases.first?.keyFileFilename, keyFile.lastPathComponent)
        alerts.end()
    }

    func testAnAnswerActsOnlyOnTheDatabaseItsAlertWasShownFor() async throws {
        let first = try register()
        let second = try register()
        var removed: [UUID] = []
        let launcher = MacDatabasesLauncherViewModel(references: { [first, second] })
        launcher.removeDatabase = { removed.append($0.id) }
        let presenter = Presenter()
        let alerts = MacDatabasesAlerts(window: makeWindow(), launcher: launcher, list: DatabaseListViewModel(),
            panels: MacFilePanels(present: { _, _ in nil }), present: presenter.present)
        launcher.beginRemoval(first)
        await settle()
        XCTAssertEqual(presenter.shown.count, 1)
        launcher.pendingRemoval = second
        presenter.answer(0)
        XCTAssertTrue(removed.isEmpty, "Remove answered for one database never removes the one that replaced it")
        XCTAssertEqual(launcher.pendingRemoval?.id, second.id)
        await settle()
        XCTAssertEqual(presenter.shown.count, 2, "The replacing request gets its own alert")
        presenter.answer(1)
        await waitUntil { !removed.isEmpty }
        XCTAssertEqual(removed, [second.id])
        alerts.end()
    }

    func testEndClearsRequestsAndDropsLateAnswers() async throws {
        let reference = try register()
        var removed: [UUID] = []
        let launcher = MacDatabasesLauncherViewModel(references: { [reference] })
        launcher.removeDatabase = { removed.append($0.id) }
        let presenter = Presenter()
        let alerts = MacDatabasesAlerts(window: makeWindow(), launcher: launcher, list: DatabaseListViewModel(),
            panels: MacFilePanels(present: { _, _ in nil }), present: presenter.present)
        launcher.beginRemoval(reference)
        await settle()
        launcher.pendingUploadDiscardTarget = reference
        await settle()
        alerts.end()
        presenter.answer(0)
        await settle()
        XCTAssertTrue(removed.isEmpty, "Remove answered after the window closed does nothing")
        XCTAssertEqual(presenter.shown.count, 1, "The queued prompt never appears")
        XCTAssertNil(launcher.pendingRemoval)
        XCTAssertNil(launcher.pendingUploadDiscardTarget)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "The native action did not complete before its deadline")
    }

    private func alert(_ title: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func register() throws -> DatabaseReference {
        let reference = try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self)), autoFillEnabled: false)
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    private func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }
}
#endif
