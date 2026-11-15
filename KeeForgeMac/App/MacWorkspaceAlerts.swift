import AppKit

/// Window-owned native workspace alerts. Answers belong to the shown lock cycle.
@MainActor
final class MacWorkspaceAlerts {
    enum Kind: Equatable {
        case deletion(String)
        case saveError(DatabaseSaveError)
        case lockDraft(DatabaseViewModel.PendingLockRequest, readOnly: Bool)
        case saveConflict
        case mergeFailure
        case pendingUploadMergeFailure
        case mergeSummary
        case syncFailure
        case pushFailure(PendingUploadAlert)
        case discardPendingUpload
    }

    enum ConflictChoice: Equatable {
        case merge
        case reload
        case saveCopy
        case cancel
    }

    let session: DatabaseViewModel
    private let presentation: MacWorkspacePresentation
    private let window: @MainActor () -> NSWindow?
    /// Shows the alert and reports the button; tests answer without showing anything.
    var present: @MainActor (NSAlert, NSWindow?, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void
        = MacWorkspaceAlerts.presentAsSheet
    private(set) var presented: (kind: Kind, alert: NSAlert)?
    /// The conflict the presented Save Conflict alert asks about.
    private var presentedConflict: SaveConflict?
    private var presentedSheetParent: NSWindow?
    private var wantsConflictPrompt = false
    private var wantsDiscardPrompt = false
    private var lastConflict: SaveConflict?
    private var lastPromptRequestID: Int
    private let observation = MacObservation()
    private var cycle: Int
    private var invalidated = false
    private var lockResponseID: UUID?
    private var endingSheet: NSWindow?
    private var sheetEndObserver: NSObjectProtocol?
    private var presentedDeletion: PendingDeletion?

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation, window: @escaping @MainActor () -> NSWindow?) {
        self.session = session
        self.presentation = presentation
        self.window = window
        cycle = session.lockCycleID
        lastPromptRequestID = presentation.saveConflictPromptRequestID
    }

    isolated deinit {
        observation.cancel()
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        dismissPresented()
    }

    func start() {
        sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.readState())
            }
        }
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] state in
            guard let state else { return }
            self?.apply(state)
        })
    }

    // MARK: - State

    private struct State: Equatable {
        var readOnly: Bool
        var unlocked: Bool
        var cycle: Int
        var deletionID: String?
        var saveError: DatabaseSaveError?
        var lockRequest: DatabaseViewModel.PendingLockRequest?
        var conflict: SaveConflict?
        var promptRequestID: Int
        var hasMergeFailure: Bool
        var hasPendingUploadMergeFailure: Bool
        var hasMergeSummary: Bool
        var hasSyncFailure: Bool
        var isSaving: Bool
        var pushAlert: PendingUploadAlert?
        var isDirty: Bool
        var hasPendingUploadConflict: Bool
        /// Read through the commands so a sheet, a read-only switch, a running discard or the list's counts withdraw the alert.
        var canDiscardPendingUpload: Bool
    }

    private func readState() -> State {
        let hasSyncFailure = if case .failed = session.cloudSyncOutcome { true } else { false }
        return State(
            readOnly: session.isReadOnly,
            unlocked: session.state == .unlocked,
            cycle: session.lockCycleID,
            deletionID: presentation.pendingDeletion?.id,
            saveError: presentation.presentedSaveError,
            lockRequest: session.pendingLockRequest?.reason == .draft ? session.pendingLockRequest : nil,
            conflict: session.saveConflict,
            promptRequestID: presentation.saveConflictPromptRequestID,
            hasMergeFailure: session.mergeFailure != nil,
            hasPendingUploadMergeFailure: session.pendingUploadMergeFailure != nil,
            hasMergeSummary: session.mergeSummaryMessage != nil,
            hasSyncFailure: hasSyncFailure,
            isSaving: session.isSaving,
            pushAlert: presentation.pushAlert,
            isDirty: session.isDirty,
            hasPendingUploadConflict: session.hasPendingUploadConflict,
            canDiscardPendingUpload: canDiscardPendingUpload
        )
    }

    private func apply(_ state: State) {
        guard !invalidated else { return }
        guard state.unlocked, state.cycle == cycle else {
            cycle = state.cycle
            lockResponseID = nil
            wantsConflictPrompt = false
            wantsDiscardPrompt = false
            lastConflict = nil
            lastPromptRequestID = state.promptRequestID
            dismissPresented()
            if presentation.pendingDeletion != nil { presentation.pendingDeletion = nil }
            if presentation.presentedSaveError != nil { presentation.presentedSaveError = nil }
            return
        }
        if let presented {
            switch presented.kind {
            case .deletion(let id) where id != state.deletionID: dismissPresented()
            case .saveError(let error) where error != state.saveError: dismissPresented()
            case .lockDraft(let request, let readOnly) where request != state.lockRequest || readOnly != state.readOnly: dismissPresented()
            default: break
            }
        }
        if state.conflict != nil, state.conflict != lastConflict { wantsConflictPrompt = true }
        if state.promptRequestID != lastPromptRequestID, state.conflict != nil { wantsConflictPrompt = true }
        if state.conflict == nil { wantsConflictPrompt = false }
        lastConflict = state.conflict
        lastPromptRequestID = state.promptRequestID
        // A conflict alert whose conflict cleared or changed asks about nothing; a changed one comes back fresh.
        if presented?.kind == .saveConflict, state.conflict != presentedConflict { dismissPresented() }
        // Discarding is refused once a draft, save or editor could race it, or the conflict is gone.
        if wantsDiscardPrompt || presented?.kind == .discardPendingUpload, !canDiscardPendingUpload {
            wantsDiscardPrompt = false
            if presented?.kind == .discardPendingUpload { dismissPresented() }
        }
        presentNext(state)
    }

    private func presentNext(_ state: State) {
        guard !invalidated, lockResponseID == nil, presented == nil, session.state == .unlocked else { return }
        if let endingSheet, endingSheet.sheetParent != nil { return }
        endingSheet = nil
        let next: Kind? = if let request = state.lockRequest {
            .lockDraft(request, readOnly: state.readOnly)
        } else if let error = state.saveError {
            .saveError(error)
        } else if let id = state.deletionID {
            .deletion(id)
        } else if state.hasMergeFailure {
            .mergeFailure
        } else if state.hasPendingUploadMergeFailure {
            .pendingUploadMergeFailure
        } else if state.hasMergeSummary {
            .mergeSummary
        } else if wantsConflictPrompt, state.isSaving == false {
            .saveConflict
        } else if wantsDiscardPrompt {
            .discardPendingUpload
        } else if let pushAlert = state.pushAlert {
            .pushFailure(pushAlert)
        } else if state.hasSyncFailure {
            .syncFailure
        } else {
            nil
        }
        guard let next else { return }
        if next == .saveConflict { wantsConflictPrompt = false }
        if next == .discardPendingUpload { wantsDiscardPrompt = false }
        show(next)
    }

    // MARK: - Discard Pending Upload

    private var canDiscardPendingUpload: Bool {
        MacWorkspaceCommands(session: session, presentation: presentation).canDiscardPendingUpload
    }

    /// Database ▸ Discard Pending Upload…, asked in this window for this lock cycle.
    func requestDiscardPendingUpload() {
        guard !invalidated, canDiscardPendingUpload else { return }
        wantsDiscardPrompt = true
        presentNext(readState())
    }

    // MARK: - Alerts

    static func makeAlert(_ kind: Kind, session: DatabaseViewModel, deletion: PendingDeletion? = nil) -> NSAlert {
        let alert = NSAlert()
        switch kind {
        case .deletion:
            alert.messageText = deletion?.confirmationTitle ?? ""
            alert.informativeText = deletion?.confirmationMessage ?? ""
            addButton(deletion?.confirmActionTitle ?? String(localized: "Delete"), identifier: "workspace.delete.confirm", to: alert).hasDestructiveAction = true
            addButton(String(localized: "Cancel"), identifier: "workspace.delete.cancel", to: alert).keyEquivalent = "\u{1b}"
        case .saveError(let error):
            alert.messageText = String(localized: "Couldn't Save Database")
            alert.informativeText = error.localizedDescription
            addButton(String(localized: "OK"), identifier: "workspace.save-error.ok", to: alert)
        case .lockDraft(_, let readOnly):
            alert.messageText = String(localized: "Lock and discard unsaved changes?")
            alert.informativeText = String(localized: "Your unsaved entry changes will be lost.")
            if !readOnly {
                addButton(String(localized: "Retry Save and Lock"), identifier: "workspace.lock.retry", to: alert)
            }
            addButton(String(localized: "Lock and Discard"), identifier: "workspace.lock.discard", to: alert).hasDestructiveAction = true
            addButton(String(localized: "Keep Editing"), identifier: "workspace.lock.cancel", to: alert).keyEquivalent = "\u{1b}"
        case .saveConflict:
            alert.messageText = String(localized: "Save Conflict")
            alert.informativeText = String(localized: "The database changed outside KeeForge. Merge both sets of changes, reload it, or save your draft as a sibling conflict copy.")
            addButton(String(localized: "Merge Changes"), identifier: "save-conflict.merge", to: alert)
            addButton(String(localized: "Reload and Re-edit"), identifier: "save-conflict.reload", to: alert)
            addButton(String(localized: "Save as Conflict Copy"), identifier: "save-conflict.save-as-copy", to: alert)
            let cancel = addButton(String(localized: "Cancel"), identifier: "save-conflict.cancel", to: alert)
            cancel.keyEquivalent = "\u{1b}"
        case .mergeFailure:
            alert.messageText = String(localized: "Couldn't Merge Changes")
            alert.informativeText = session.mergeFailure?.message ?? ""
            addButton(String(localized: "OK"), identifier: "merge-failure.ok", to: alert)
        case .pendingUploadMergeFailure:
            alert.messageText = String(localized: "Couldn't Merge Changes")
            alert.informativeText = session.pendingUploadMergeFailure?.message ?? ""
            addButton(String(localized: "OK"), identifier: "pending-upload-merge.failure-ok", to: alert)
        case .mergeSummary:
            alert.messageText = String(localized: "Changes Merged")
            alert.informativeText = session.mergeSummaryMessage ?? ""
            addButton(String(localized: "OK"), identifier: "merge-summary.ok", to: alert)
        case .syncFailure:
            let message = session.cloudSyncOutcome?.message ?? ""
            alert.messageText = String(localized: "Cloud Sync Needs Attention")
            alert.informativeText = String(localized: "\(message)\n\nKeeForge opened the cached copy for now. Cloud sync needs attention before this database can be refreshed from its provider.")
            addButton(String(localized: "OK"), identifier: "cloud-sync-failure.ok", to: alert)
        case .pushFailure(let failure):
            alert.messageText = failure.title
            switch failure.kind {
            case .writeScopeRequired, .notAuthenticated:
                alert.informativeText = failure.message
                let provider = session.databaseReference.cloudProviderKind?.displayName ?? String(localized: "cloud")
                addButton(String(localized: "Reconnect \(provider)"), identifier: "pending-upload-push.reconnect", to: alert)
                addButton(String(localized: "Cancel"), identifier: "pending-upload-push.cancel", to: alert)
                    .keyEquivalent = "\u{1b}"
            case .conflict:
                // The list's wording sends the user to open the database; this window merges in place.
                alert.informativeText = String(
                    localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
                )
                addButton(String(localized: "Merge Changes"), identifier: "pending-upload-push.merge", to: alert)
                addButton(String(localized: "Cancel"), identifier: "pending-upload-push.cancel", to: alert)
                    .keyEquivalent = "\u{1b}"
            case .message:
                alert.informativeText = failure.message
                addButton(String(localized: "OK"), identifier: "pending-upload-push.ok", to: alert)
            }
        case .discardPendingUpload:
            return MacDatabasesAlerts.makeDiscardAlert(for: session.databaseReference)
        }
        return alert
    }

    static func conflictChoice(for response: NSApplication.ModalResponse) -> ConflictChoice {
        switch response {
        case .alertFirstButtonReturn: .merge
        case .alertSecondButtonReturn: .reload
        case .alertThirdButtonReturn: .saveCopy
        default: .cancel
        }
    }

    @discardableResult
    private static func addButton(_ title: String, identifier: String, to alert: NSAlert) -> NSButton {
        let button = alert.addButton(withTitle: title)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    private func show(_ kind: Kind) {
        let deletion = presentation.pendingDeletion
        let alert = Self.makeAlert(kind, session: session, deletion: deletion)
        presentedDeletion = deletion
        let lockCycleID = session.lockCycleID
        let conflict = session.saveConflict
        presented = (kind, alert)
        presentedConflict = kind == .saveConflict ? conflict : nil
        let parent = window().map(Self.topmostSheet(of:))
        presentedSheetParent = parent
        present(alert, parent) { [weak self] response in
            guard let self, presented?.alert === alert else { return }
            presented = nil
            presentedConflict = nil
            let deletion = presentedDeletion
            presentedDeletion = nil
            presentedSheetParent = nil
            guard session.lockCycleID == lockCycleID, session.state == .unlocked else { return }
            if kind == .saveConflict, session.saveConflict != conflict || session.isSaving {
                // Asked again once the save ends, if the same conflict still stands.
                if session.saveConflict != nil { wantsConflictPrompt = true }
            } else {
                respond(to: kind, with: response, deletion: deletion)
            }
            presentNext(readState())
        }
    }

    private func respond(to kind: Kind, with response: NSApplication.ModalResponse, deletion: PendingDeletion?) {
        let session = session
        switch kind {
        case .deletion(let id):
            guard presentation.pendingDeletion?.id == id else { return }
            presentation.pendingDeletion = nil
            if response == .alertFirstButtonReturn { deletion?.performDeletion(viewModel: session) }
        case .saveError(let error):
            if presentation.presentedSaveError == error { presentation.presentedSaveError = nil }
        case .lockDraft(let request, let readOnly):
            guard session.pendingLockRequest == request else { return }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if !readOnly, index == 0 {
                guard !session.isReadOnly else { return }
                runLockResponse { await session.saveAndLockAfterLockRequest() }
            } else if index == (readOnly ? 0 : 1) {
                session.lockRequest(force: true, manuallyTriggered: request.manuallyTriggered)
            } else {
                runLockResponse { await session.continueEditingAfterLockRequest() }
            }
        case .saveConflict:
            switch Self.conflictChoice(for: response) {
            case .merge: run { try await session.mergeAndSave() }
            case .reload: run { try await session.reloadDiscardingDraft() }
            case .saveCopy: run { try await session.saveAsConflictCopy() }
            case .cancel: break
            }
        case .mergeFailure:
            session.dismissMergeFailure()
            // A declined merge returns to the conflict alert, with Reload and Save as Copy.
            if session.saveConflict != nil { wantsConflictPrompt = true }
        case .pendingUploadMergeFailure:
            session.dismissPendingUploadMergeFailure()
        case .mergeSummary:
            session.acknowledgeMergeSummary()
        case .syncFailure:
            session.dismissCloudSyncOutcome()
        case .pushFailure(let failure):
            presentation.dismissPushAlert()
            guard response == .alertFirstButtonReturn else { return }
            let actions = MacDatabaseStatusActions(session: session, presentation: presentation)
            switch failure.kind {
            case .writeScopeRequired, .notAuthenticated:
                guard let provider = session.databaseReference.cloudProviderKind?.displayName else { return }
                actions.perform(MacDatabaseStatus.Action.reconnect(provider: provider), from: window())
            case .conflict:
                actions.perform(MacDatabaseStatus.Notice.Action.mergePendingUploads, from: window())
            case .message:
                break
            }
        case .discardPendingUpload:
            guard response == .alertFirstButtonReturn, canDiscardPendingUpload else { return }
            presentation.discardPendingUploads(in: session)
        }
    }

    private func runLockResponse(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let cycle = session.lockCycleID
        lockResponseID = id
        Task { [weak self] in
            guard let self, !invalidated, session.state == .unlocked,
                  session.lockCycleID == cycle, lockResponseID == id else { return }
            await operation()
            guard lockResponseID == id else { return }
            lockResponseID = nil
            apply(readState())
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        let session = session
        let cycle = session.lockCycleID
        Task { [weak self] in
            guard let self, !invalidated, session.lockCycleID == cycle, session.state == .unlocked else { return }
            do {
                try await operation()
            } catch {
                guard !invalidated, session.lockCycleID == cycle, session.state == .unlocked else { return }
                session.presentSaveError(error)
            }
        }
    }

    func invalidate() {
        invalidated = true
        observation.cancel()
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
        lockResponseID = nil
        dismissPresented()
        presentation.pendingDeletion = nil
        presentation.presentedSaveError = nil
    }

    private func dismissPresented() {
        guard let presented else { return }
        self.presented = nil
        presentedConflict = nil
        presentedDeletion = nil
        let sheet = presented.alert.window
        endingSheet = sheet
        if let parent = sheet.sheetParent ?? presentedSheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        } else if sheet.isVisible {
            NSApp.abortModal()
        }
        presentedSheetParent = nil
    }

    /// An alert raised over a sheet (Database Settings, an editor) attaches to that sheet.
    static func topmostSheet(of window: NSWindow) -> NSWindow {
        var current = window
        while let sheet = current.attachedSheet { current = sheet }
        return current
    }

    static func presentAsSheet(
        _ alert: NSAlert, on window: NSWindow?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        guard let window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response) }
        }
    }
}

/// Remove from List on a locked window's recovery page, asked in that window
/// with the Databases window's wording.
@MainActor
enum MacRemoveFromListAlert {
    enum Kind: Equatable {
        case confirm
        /// The window holds unsaved work or a write in flight.
        case refused
    }

    /// Asks and reports whether to remove; tests answer without showing anything.
    typealias Present = @MainActor (Kind, DatabaseReference, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void

    static func present(
        _ kind: Kind, for reference: DatabaseReference, on window: NSWindow,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let queue = (window.windowController as? DatabaseWindowController)?.removalAlerts else {
            completion(false)
            return
        }
        // Queued: a refusal raised as the confirmation ends waits for it to detach.
        queue.enqueue(makeAlert(kind, for: reference)) { response in
            completion(kind == .confirm && response == .alertFirstButtonReturn)
        }
    }

    static func makeAlert(_ kind: Kind, for reference: DatabaseReference) -> NSAlert {
        let alert = NSAlert()
        switch kind {
        case .confirm:
            alert.messageText = String(localized: "Remove Database?")
            alert.informativeText = String(
                localized: "“\(reference.displayName)” will be removed from KeeForge, including its cached copy and saved biometric key.")
            alert.addButton(withTitle: String(localized: "Remove")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        case .refused:
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Can’t Remove Database")
            alert.informativeText = String(
                localized: "“\(reference.displayName)” has unsaved changes. Save them or close its window, then remove it.")
            alert.addButton(withTitle: String(localized: "OK"))
        }
        return alert
    }
}
