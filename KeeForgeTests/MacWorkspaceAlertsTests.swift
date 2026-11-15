#if os(macOS)
import AppKit
import KDBXKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceAlertsTests: XCTestCase {
    private static let fourthButton = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3)
    private var shown: [(alert: NSAlert, answer: @MainActor (NSApplication.ModalResponse) -> Void)] = []

    func testPendingLocalRecoveryOffersDetailsInsteadOfMergeOrReload() async throws {
        let (alerts, session, presentation) = try await makeAlerts()
        defer { alerts.invalidate(); PendingLocalSaveStore.clearAll() }
        try await hitSaveConflict(session)
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        _ = try PendingLocalSaveStore.prepareSource(bytes, for: session.databaseReference.id,
            baseCacheSHA512: FileDigest.sha512(bytes))
        await session.refreshLocalConflictRecovery()
        await settle()
        let alert = MacWorkspaceAlerts.makeAlert(.saveConflict, session: session)
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() }, ["save-conflict.recovery", "save-conflict.cancel"])
        XCTAssertTrue(session.saveConflict?.requiresLocalRecovery == true)
        let draft = session.draft
        presentation.requestSaveConflictPrompt()
        await settle()
        shown.last?.answer(.alertFirstButtonReturn)
        await settle()
        XCTAssertTrue(presentation.isShowingDatabaseDetails)
        XCTAssertEqual(session.draft?.pendingEdits, draft?.pendingEdits)
        XCTAssertNotNil(session.saveConflict)
    }

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

    func testAnAlertUsesItsWindowAndClosesWhenItsConflictClears() async throws {
        let window = NSWindow()
        let (alerts, session, _) = try await makeAlerts(window: window)
        var parent: NSWindow?
        alerts.present = { [weak self] alert, window, answer in
            parent = window
            self?.shown.append((alert, answer))
        }
        try await hitSaveConflict(session)
        await settle()
        XCTAssertTrue(parent === window)
        XCTAssertEqual(alerts.presented?.kind, .saveConflict)
        session.discardDraft()
        await settle()
        XCTAssertNil(alerts.presented)
    }

    func testDeleteSaveErrorAndLockAlertContracts() async throws {
        let (alerts, session, state) = try await makeAlerts()
        let entry = try XCTUnwrap(session.visibleRootGroup?.allEntries.first)
        let pending = PendingDeletion.entry(.init(entryID: entry.id, sendToRecycleBin: true))
        let confirmations: [PendingDeletion] = [pending,
            .entry(.init(entryID: entry.id, sendToRecycleBin: false)),
            .group(.init(groupID: UUID(), groupName: "Work", entryCount: 31, nestedGroupCount: 0, sendToRecycleBin: true)),
            .group(.init(groupID: UUID(), groupName: "Old", entryCount: 14, nestedGroupCount: 1, sendToRecycleBin: false)),
            .entries([UUID(), UUID(), UUID()])]
        for confirmation in confirmations {
            let alert = MacWorkspaceAlerts.makeAlert(.deletion(confirmation.id), session: session, deletion: confirmation)
            XCTAssertEqual(alert.messageText, confirmation.confirmationTitle)
            XCTAssertEqual(alert.informativeText, confirmation.confirmationMessage)
            XCTAssertEqual(alert.buttons.map(\.title), [confirmation.confirmActionTitle, String(localized: "Cancel")])
        }
        state.pendingDeletion = pending
        await settle()
        let delete = try XCTUnwrap(alerts.presented?.alert)
        XCTAssertEqual(delete.messageText, pending.confirmationTitle)
        XCTAssertEqual(delete.informativeText, pending.confirmationMessage)
        XCTAssertEqual(delete.buttons.map(\.title), [pending.confirmActionTitle, String(localized: "Cancel")])
        XCTAssertTrue(delete.buttons[0].hasDestructiveAction)
        shown.last?.answer(.alertSecondButtonReturn)
        await settle()
        XCTAssertNil(state.pendingDeletion)
        XCTAssertFalse(session.isDirty)

        state.presentedSaveError = .unknown("Disk full")
        await settle()
        XCTAssertEqual(alerts.presented?.alert.messageText, String(localized: "Couldn't Save Database"))
        XCTAssertEqual(alerts.presented?.alert.informativeText, "Disk full")
        shown.last?.answer(.alertFirstButtonReturn)
        await settle()
        XCTAssertNil(state.presentedSaveError)

        try session.createGroup(named: "Draft", in: try XCTUnwrap(session.visibleRootGroupID))
        session.lockRequest(manuallyTriggered: true)
        await settle()
        let request = try XCTUnwrap(session.pendingLockRequest)
        let lock = try XCTUnwrap(alerts.presented?.alert)
        XCTAssertEqual(lock.buttons.map(\.title), [String(localized: "Retry Save and Lock"), String(localized: "Lock and Discard"), String(localized: "Keep Editing")])
        XCTAssertEqual(lock.buttons.last?.keyEquivalent, "\u{1b}")
        session.setReadOnly(true)
        let readOnly = MacWorkspaceAlerts.makeAlert(.lockDraft(request, readOnly: true), session: session)
        XCTAssertEqual(readOnly.buttons.map(\.title), [String(localized: "Lock and Discard"), String(localized: "Keep Editing")])
        alerts.invalidate()
    }

    func testLockAndInvalidationEndAlertsWithoutAnswersAndRejectOldDeleteAfterUnlock() async throws {
        for invalidate in [false, true] {
            let (alerts, session, state) = try await makeAlerts()
            let entry = try XCTUnwrap(session.visibleRootGroup?.allEntries.first)
            state.pendingDeletion = .entry(.init(entryID: entry.id, sendToRecycleBin: true))
            await settle()
            let answer = try XCTUnwrap(shown.last?.answer)
            if invalidate { alerts.invalidate() } else { session.lockRequest(force: true) }
            await settle()
            XCTAssertNil(alerts.presented)
            XCTAssertNil(state.pendingDeletion)
            if !invalidate { await session.unlock(password: "testpassword123") }
            answer(.alertFirstButtonReturn)
            await settle()
            XCTAssertFalse(session.isDirty)
            alerts.invalidate()
        }
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

    func testLockAnswersDoNotPresentTheSamePromptAgainWhileTheirTaskStarts() async throws {
        for retry in [false, true] {
            let (alerts, session, _) = try await makeAlerts(save: { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) })
            try session.createGroup(named: "Draft", in: try XCTUnwrap(session.visibleRootGroupID))
            session.lockRequest(manuallyTriggered: true)
            await settle()
            let count = shown.count
            shown.last?.answer(retry ? .alertFirstButtonReturn : .alertThirdButtonReturn)
            for _ in 0..<10 { await settle() }
            XCTAssertEqual(shown.count, count, "The chosen response owns the request until it settles")
            XCTAssertNil(alerts.presented)
            XCTAssertNil(session.pendingLockRequest)
            XCTAssertEqual(session.state, retry ? .locked : .unlocked)
            alerts.invalidate()
        }
    }

    func testDiscardPendingUploadAsksWithCancelAsTheDefaultAndDiscardsThroughTheList() async throws {
        let (alerts, session, presentation) = try await makeAlerts()
        var discarded: [UUID] = []
        presentation.pendingUploads = MacPendingUploads(
            counts: { _ in .init(waiting: 0, conflicts: 1) }, push: { _ in nil },
            discardConflicts: { discarded.append($0) })

        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .discardPendingUpload)
        let alert = try XCTUnwrap(shown.last?.alert)
        XCTAssertEqual(alert.messageText, String(localized: "Discard Pending Upload?"))
        XCTAssertEqual(alert.informativeText, MacDatabasesAlerts.makeDiscardAlert(for: session.databaseReference).informativeText,
                       "The Databases window's wording")
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Discard Upload"), String(localized: "Cancel")])
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() },
                       ["pending-upload-discard.confirm", "pending-upload-discard.cancel"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "Return never discards")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "Cancel is the default")
        try assertEscapeCancels(alert)

        shown.last?.answer(.alertSecondButtonReturn)
        await settle()
        XCTAssertNil(alerts.presented)
        XCTAssertEqual(discarded, [])

        alerts.requestDiscardPendingUpload()
        await settle()
        shown.last?.answer(.alertFirstButtonReturn)
        try await waitUntil { discarded.isEmpty == false }
        XCTAssertEqual(discarded, [session.databaseReference.id])
        XCTAssertEqual(shown.count, 2)
    }

    func testDiscardPendingUploadEndsOnLockAndDropsAStaleAnswer() async throws {
        let (alerts, session, presentation) = try await makeAlerts(save: { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) })
        var discarded = 0
        presentation.pendingUploads = MacPendingUploads(
            counts: { _ in .init(waiting: 0, conflicts: 1) }, push: { _ in nil },
            discardConflicts: { _ in discarded += 1 })

        alerts.requestDiscardPendingUpload()
        await settle()
        let staleAnswer = try XCTUnwrap(shown.last?.answer)
        try session.createGroup(named: "Draft", in: try XCTUnwrap(session.visibleRootGroupID))
        await settle()
        XCTAssertNil(alerts.presented, "A draft that the discard could race ends the alert")
        staleAnswer(.alertFirstButtonReturn)
        await settle()
        XCTAssertEqual(discarded, 0)

        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertNil(alerts.presented, "Refused while the draft is unsaved")
        await session.saveHandlingError()
        alerts.requestDiscardPendingUpload()
        await settle()
        XCTAssertEqual(alerts.presented?.kind, .discardPendingUpload)
        let lockedAnswer = try XCTUnwrap(shown.last?.answer)
        session.lockRequest(force: true)
        await settle()
        XCTAssertNil(alerts.presented, "Lock ends the alert")
        lockedAnswer(.alertFirstButtonReturn)
        await settle()
        XCTAssertEqual(discarded, 0)
    }

    func testTheDatabasesWindowDiscardAlertMatchesWithCancelOnReturnAndEscape() throws {
        let reference = DatabaseReference(
            id: UUID(), nickname: "Vault", filename: "vault.kdbx", bookmarkData: nil, keyFileBookmarkData: nil,
            keyFileFilename: nil, isQuickLaunch: false, lastOpenedAt: nil, addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil, legacyKeychainFilename: nil)
        let alert = MacDatabasesAlerts.makeDiscardAlert(for: reference)
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Discard Upload"), String(localized: "Cancel")])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "Return never discards")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r", "Cancel is the default")
        try assertEscapeCancels(alert)
    }

    // MARK: - Helpers

    private final class ClickRecorder: NSObject {
        var clicks = 0
        @objc func click(_ sender: Any?) { clicks += 1 }
    }

    /// Escape reaches the alert's last button (Cancel) even though Cancel holds Return.
    private func assertEscapeCancels(_ alert: NSAlert, file: StaticString = #filePath, line: UInt = #line) throws {
        alert.layout()
        let cancel = try XCTUnwrap(alert.buttons.last, file: file, line: line)
        let recorder = ClickRecorder()
        cancel.target = recorder
        cancel.action = #selector(ClickRecorder.click(_:))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: alert.window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
            file: file, line: line)
        XCTAssertTrue(alert.window.performKeyEquivalent(with: escape), "Escape is handled", file: file, line: line)
        XCTAssertEqual(recorder.clicks, 1, "Escape clicks Cancel", file: file, line: line)
    }

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
