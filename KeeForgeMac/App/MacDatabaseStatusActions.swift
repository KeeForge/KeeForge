import AppKit

/// What the status card, the hidden-sidebar toolbar items and the notices above
/// the entry list do, through the same recovery paths the banners used.
@MainActor
struct MacDatabaseStatusActions {
    let session: DatabaseViewModel
    let presentation: MacWorkspacePresentation

    func perform(_ action: MacDatabaseStatus.Action, from window: NSWindow?) {
        switch action {
        case .retrySave:
            let session = session
            Task { await session.saveHandlingError() }
        case .resolveConflict:
            presentation.requestSaveConflictPrompt()
        case .reconnect:
            reconnect()
        case .pushPendingUploads:
            guard !presentation.isDiscardingPendingUpload else { return }
            presentation.pushPendingUploads(in: session)
        }
    }

    func perform(_ action: MacDatabaseStatus.Notice.Action, from window: NSWindow?) {
        switch action {
        case .reconnect:
            reconnect()
        case .mergePendingUploads:
            guard !presentation.isDiscardingPendingUpload else { return }
            let session = session
            Task {
                do {
                    try await session.mergePendingUploads()
                } catch {
                    session.presentSaveError(error)
                }
            }
        case .dismissSyncResult:
            session.dismissCloudSyncOutcome()
        }
    }

    func showSettings() { MacWorkspaceCommands(session: session, presentation: presentation).showDatabaseSettings() }
    func syncNow() { MacWorkspaceCommands(session: session, presentation: presentation).syncNow() }
    func lock() { DatabaseCommands(session: session).lock() }

    func explainReadOnly(from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Read-Only Database")
        alert.informativeText = session.readOnlyExplanation
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func reconnect() {
        guard presentation.isCloudReconnectInFlight == false else { return }
        guard let reconnect = MacServerReconnect(reference: session.databaseReference) else {
            session.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }
        let prompt = presentation.serverCredentialPrompt
        presentation.reconnectCloud(in: session) {
            try await reconnect.run(present: prompt.present)
        }
    }
}
