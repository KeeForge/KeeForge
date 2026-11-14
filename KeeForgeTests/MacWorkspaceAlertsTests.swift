#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceAlertsTests: XCTestCase {
    private static let fourthButton = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3)
    private var shown: [(alert: NSAlert, answer: @MainActor (NSApplication.ModalResponse) -> Void)] = []

    func testTheSaveConflictAlertHasCancelOnEscapeAndResolveBringsItBack() async throws {
        let (alerts, session, presentation) = try await makeAlerts()
        try await hitSaveConflict(session)
        await settle()

        XCTAssertEqual(alerts.presented?.kind, .saveConflict)
        let alert = try XCTUnwrap(shown.last?.alert)
        XCTAssertEqual(alert.messageText, String(localized: "Save Conflict"))
        XCTAssertEqual(alert.informativeText, String(localized: "The database changed outside KeeForge. Merge both sets of changes, reload it, or save your draft as a sibling conflict copy."))
        XCTAssertEqual(alert.buttons.map(\.title), [
            String(localized: "Merge Changes"), String(localized: "Reload and Re-edit"),
            String(localized: "Save as Conflict Copy"), String(localized: "Cancel"),
        ])
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() }, [
            "save-conflict.merge", "save-conflict.reload", "save-conflict.save-as-copy", "save-conflict.cancel",
        ])
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}", "Escape cancels")

        shown.last?.answer(Self.fourthButton)
        await settle()
        XCTAssertNil(alerts.presented)
        XCTAssertNotNil(session.saveConflict, "Cancel leaves the conflict for Resolve…")
        XCTAssertEqual(shown.count, 1, "Cancelling does not bring it straight back")

        presentation.requestSaveConflictPrompt()
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .saveConflict)
        XCTAssertEqual(shown.count, 2)
    }

    func testADeclinedMergeReturnsToTheConflictAlert() async throws {
        let (alerts, session, _) = try await makeAlerts()
        try await hitSaveConflict(session)
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .saveConflict)

        shown.last?.answer(.alertFirstButtonReturn)
        try await waitUntil { session.mergeFailure != nil }
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .mergeFailure)
        let failure = try XCTUnwrap(shown.last?.alert)
        XCTAssertEqual(failure.messageText, String(localized: "Couldn't Merge Changes"))
        XCTAssertEqual(failure.buttons.map { $0.accessibilityIdentifier() }, ["merge-failure.ok"])

        shown.last?.answer(.alertFirstButtonReturn)
        await settle()
        XCTAssertNil(session.mergeFailure)
        XCTAssertEqual(alerts.presented?.kind, .saveConflict, "OK hands back Reload and Save as Copy")
    }

    func testAnAnswerAfterALockDoesNothing() async throws {
        let (alerts, session, _) = try await makeAlerts()
        try await hitSaveConflict(session)
        await settle()
        let answer = try XCTUnwrap(shown.last?.answer)

        session.lockRequest(force: true)
        answer(.alertFirstButtonReturn)
        await settle()
        XCTAssertNil(alerts.presented)
        XCTAssertNil(session.mergeFailure)
        XCTAssertEqual(shown.count, 1)
    }

    func testResponsesMapToTheConflictChoices() {
        XCTAssertEqual(MacWorkspaceAlerts.conflictChoice(for: .alertFirstButtonReturn), .merge)
        XCTAssertEqual(MacWorkspaceAlerts.conflictChoice(for: .alertSecondButtonReturn), .reload)
        XCTAssertEqual(MacWorkspaceAlerts.conflictChoice(for: .alertThirdButtonReturn), .saveCopy)
        XCTAssertEqual(MacWorkspaceAlerts.conflictChoice(for: Self.fourthButton), .cancel)
        XCTAssertEqual(MacWorkspaceAlerts.conflictChoice(for: .cancel), .cancel)
    }

    func testAnAlertOverASheetAttachesToTheSheet() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(MacWorkspaceAlerts.topmostSheet(of: window) === window)
    }

    // MARK: - Helpers

    private func makeAlerts() async throws -> (MacWorkspaceAlerts, DatabaseViewModel, MacWorkspacePresentation) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        let session = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _, _, _, _ in .conflict(remoteSHA512: Data([1, 2, 3]), remoteData: Data()) },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()
        let alerts = MacWorkspaceAlerts(session: session, presentation: presentation) { nil }
        alerts.present = { [weak self] alert, _, answer in self?.shown.append((alert, answer)) }
        alerts.start()
        return (alerts, session, presentation)
    }

    private func hitSaveConflict(_ session: DatabaseViewModel) async throws {
        let rootID = try XCTUnwrap(session.visibleRootGroupID)
        try session.createGroup(named: "Draft", in: rootID)
        await session.saveHandlingError()
        XCTAssertNotNil(session.saveConflict)
    }

    private func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where condition() == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}
#endif
