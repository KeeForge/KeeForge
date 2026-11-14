import AppKit

/// The save-conflict family of alerts (SyncProblems board), the failed Sync
/// Now alert and what a Push Pending Changes from this window reported, as
/// native alerts: SwiftUI's four-button macOS alert drops
/// Cancel and ignores Escape. One per unlocked workspace; releasing it on lock
/// ends any alert still up.
@MainActor
final class MacWorkspaceAlerts {
    enum Kind: Equatable {
        case saveConflict
        case mergeFailure
        case pendingUploadMergeFailure
        case mergeSummary
        case syncFailure
        case pushFailure(PendingUploadAlert)
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
    private var lastConflict: SaveConflict?
    private var lastPromptRequestID: Int
    private let observation = MacObservation()

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation, window: @escaping @MainActor () -> NSWindow?) {
        self.session = session
        self.presentation = presentation
        self.window = window
        lastPromptRequestID = presentation.saveConflictPromptRequestID
    }

    isolated deinit {
        observation.cancel()
        dismissPresented()
    }

    func start() {
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] state in
            guard let state else { return }
            self?.apply(state)
        })
    }

    // MARK: - State

    private struct State: Equatable {
        var conflict: SaveConflict?
        var promptRequestID: Int
        var hasMergeFailure: Bool
        var hasPendingUploadMergeFailure: Bool
        var hasMergeSummary: Bool
        var hasSyncFailure: Bool
        var isSaving: Bool
        var pushAlert: PendingUploadAlert?
    }

    private func readState() -> State {
        let hasSyncFailure = if case .failed = session.cloudSyncOutcome { true } else { false }
        return State(
            conflict: session.saveConflict,
            promptRequestID: presentation.saveConflictPromptRequestID,
            hasMergeFailure: session.mergeFailure != nil,
            hasPendingUploadMergeFailure: session.pendingUploadMergeFailure != nil,
            hasMergeSummary: session.mergeSummaryMessage != nil,
            hasSyncFailure: hasSyncFailure,
            isSaving: session.isSaving,
            pushAlert: presentation.pushAlert
        )
    }

    private func apply(_ state: State) {
        if state.conflict != nil, state.conflict != lastConflict { wantsConflictPrompt = true }
        if state.promptRequestID != lastPromptRequestID, state.conflict != nil { wantsConflictPrompt = true }
        if state.conflict == nil { wantsConflictPrompt = false }
        lastConflict = state.conflict
        lastPromptRequestID = state.promptRequestID
        // A conflict alert whose conflict cleared or changed asks about nothing; a changed one comes back fresh.
        if presented?.kind == .saveConflict, state.conflict != presentedConflict { dismissPresented() }
        presentNext(state)
    }

    private func presentNext(_ state: State) {
        guard presented == nil, session.state == .unlocked else { return }
        let next: Kind? = if state.hasMergeFailure {
            .mergeFailure
        } else if state.hasPendingUploadMergeFailure {
            .pendingUploadMergeFailure
        } else if state.hasMergeSummary {
            .mergeSummary
        } else if wantsConflictPrompt, state.isSaving == false {
            .saveConflict
        } else if let pushAlert = state.pushAlert {
            .pushFailure(pushAlert)
        } else if state.hasSyncFailure {
            .syncFailure
        } else {
            nil
        }
        guard let next else { return }
        if next == .saveConflict { wantsConflictPrompt = false }
        show(next)
    }

    // MARK: - Alerts

    static func makeAlert(_ kind: Kind, session: DatabaseViewModel) -> NSAlert {
        let alert = NSAlert()
        switch kind {
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
        let alert = Self.makeAlert(kind, session: session)
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
            presentedSheetParent = nil
            guard session.lockCycleID == lockCycleID, session.state == .unlocked else { return }
            if kind == .saveConflict, session.saveConflict != conflict || session.isSaving {
                // Asked again once the save ends, if the same conflict still stands.
                if session.saveConflict != nil { wantsConflictPrompt = true }
            } else {
                respond(to: kind, with: response)
            }
            presentNext(readState())
        }
    }

    private func respond(to kind: Kind, with response: NSApplication.ModalResponse) {
        let session = session
        switch kind {
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
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        let session = session
        Task {
            do {
                try await operation()
            } catch {
                session.presentSaveError(error)
            }
        }
    }

    private func dismissPresented() {
        guard let presented else { return }
        self.presented = nil
        presentedConflict = nil
        let sheet = presented.alert.window
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
