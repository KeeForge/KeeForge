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

    func testAnAlertOverARealSheetAttachesToItAndClosesWhenItsConflictClears() async throws {
        // A sheet attaches only to a window on screen (as in MacWindowCoordinatorTests).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        window.beginSheet(editor, completionHandler: nil)
        defer {
            window.endSheet(editor)
            window.close()
        }
        XCTAssertTrue(MacWorkspaceAlerts.topmostSheet(of: window) === editor)

        let (alerts, session, _) = try await makeAlerts(window: window, presentsForReal: true)
        try await hitSaveConflict(session)
        await settle()
        let alert = try XCTUnwrap(alerts.presented?.alert)
        XCTAssertEqual(alerts.presented?.kind, .saveConflict)
        XCTAssertTrue(alert.window.sheetParent === editor, "The alert attaches to the editor sheet")

        session.discardDraft()
        await settle()
        XCTAssertNil(alerts.presented, "An alert for a conflict that cleared closes")
        try await waitUntil { editor.attachedSheet == nil }
    }

    func testAnAnswerToAConflictASaveReplacedIsIgnoredAndTheNewConflictAsksAgain() async throws {
        let gate = SaveGate()
        let saves = SaveCallCounter()
        let reloads = SaveCallCounter()
        let (alerts, session, _) = try await makeAlerts(save: { _, _, _, _, _, _, _ in
            if await saves.increment() == 2 {
                await gate.signalStarted()
                await gate.waitUntilOpen()
            }
            return .conflict(remoteSHA512: Data([1, 2, 3]), remoteData: Data())
        }, reloads: reloads)
        try await hitSaveConflict(session)
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .saveConflict)
        let staleAnswer = try XCTUnwrap(shown.last?.answer)

        // ⌘S with the alert up: the save clears the conflict while it runs.
        try session.createGroup(named: "Second", in: try XCTUnwrap(session.visibleRootGroupID))
        let save = Task { await session.saveHandlingError() }
        await gate.waitUntilStarted()
        await settle()
        XCTAssertTrue(session.isSaving)
        XCTAssertNil(alerts.presented, "The alert closes when the save clears its conflict")

        staleAnswer(.alertSecondButtonReturn)
        do {
            try await session.reloadDiscardingDraft()
            XCTFail("Reload must not run under a save")
        } catch {
            XCTAssertEqual(error as? SaveError, .saveContextUnavailable)
        }
        let reloadCount = await reloads.value
        XCTAssertEqual(reloadCount, 0, "Neither the stale Reload nor a direct one ran during the save")
        XCTAssertEqual(session.state, .unlocked)

        await gate.open()
        await save.value
        await settle()
        XCTAssertNotNil(session.saveConflict)
        XCTAssertEqual(alerts.presented?.kind, .saveConflict, "The save's own conflict asks again")
        XCTAssertEqual(shown.count, 2)
    }

    func testAPushFailureShowsInThisWindowAndOffersReconnect() async throws {
        let (alerts, session, presentation) = try await makeAlerts()
        let failure = PendingUploadAlert(databaseId: session.databaseReference.id, kind: .notAuthenticated,
                                         title: "Reconnect Cloud Account", message: "Sign in again.")
        presentation.pendingUploads = MacPendingUploads(counts: { _ in .init() }, push: { _ in failure })

        await presentation.pushPendingUploads(in: session).value
        await settle()

        XCTAssertEqual(presentation.pushAlert, failure)
        XCTAssertEqual(alerts.presented?.kind, .pushFailure(failure))
        let alert = try XCTUnwrap(shown.last?.alert)
        XCTAssertEqual(alert.messageText, "Reconnect Cloud Account")
        XCTAssertEqual(alert.informativeText, "Sign in again.")
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() },
                       ["pending-upload-push.reconnect", "pending-upload-push.cancel"])
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")

        shown.last?.answer(.alertSecondButtonReturn)
        await settle()
        XCTAssertNil(presentation.pushAlert)
        XCTAssertNil(alerts.presented)
    }

    func testAPushConflictOffersMergeHereAndAResultAfterALockIsDropped() async throws {
        let (_, session, presentation) = try await makeAlerts()
        let conflict = PendingUploadAlert(databaseId: session.databaseReference.id, kind: .conflict,
                                          title: "Pending Upload Conflict", message: "Open the database to merge.")
        let alert = MacWorkspaceAlerts.makeAlert(.pushFailure(conflict), session: session)
        XCTAssertEqual(alert.informativeText, String(
            localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
        ))
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Merge Changes"), String(localized: "Cancel")])

        let gate = SaveGate()
        presentation.pendingUploads = MacPendingUploads(counts: { _ in .init() }, push: { _ in
            await gate.waitUntilOpen()
            return conflict
        })
        let push = presentation.pushPendingUploads(in: session)
        presentation.reset()
        await gate.open()
        await push.value
        XCTAssertNil(presentation.pushAlert, "A lock in between drops the result")
    }

    // MARK: - Helpers

    private func makeAlerts(
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, _, _, _, _ in
            .conflict(remoteSHA512: Data([1, 2, 3]), remoteData: Data())
        },
        reloads: SaveCallCounter = SaveCallCounter(),
        window: NSWindow? = nil,
        presentsForReal: Bool = false
    ) async throws -> (MacWorkspaceAlerts, DatabaseViewModel, MacWorkspacePresentation) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        let session = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
            reloadOperation: { _, _ in
                await reloads.increment()
                throw SaveError.saveContextUnavailable
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
        await session.unlock(password: "testpassword123")
        XCTAssertEqual(session.state, .unlocked)
        addTeardownBlock { @MainActor in session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()
        let alerts = MacWorkspaceAlerts(session: session, presentation: presentation) { window }
        if presentsForReal == false {
            alerts.present = { [weak self] alert, _, answer in self?.shown.append((alert, answer)) }
        }
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
