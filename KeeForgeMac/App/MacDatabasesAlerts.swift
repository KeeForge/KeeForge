import AppKit

/// The Databases window's prompts as native sheets through one alert queue.
/// The launcher and list models keep each request until it is answered; a
/// request cleared elsewhere withdraws its alert.
@MainActor
final class MacDatabasesAlerts {
    private enum Request: Hashable {
        case remove(UUID)
        case refused(UUID)
        case rename(UUID)
        case discard(UUID)
        case selection(String)
        case pendingUpload(String)
    }

    private let launcher: MacDatabasesLauncherViewModel
    private let list: DatabaseListViewModel
    private let alerts: MacAlertQueue
    private let panels: MacFilePanels
    private let observation = MacObservation()
    private var shown: [Request: NSAlert] = [:]
    private var generation = UUID()

    init(window: NSWindow, launcher: MacDatabasesLauncherViewModel, list: DatabaseListViewModel,
         panels: MacFilePanels = MacFilePanels(),
         present: @escaping MacAlertQueue.Present = MacWorkspaceAlerts.presentAsSheet) {
        self.launcher = launcher
        self.list = list
        self.panels = panels
        alerts = MacAlertQueue(window: window, present: present)
        panels.window = window
        observation.start(reading: { [weak self] in self?.requests() ?? [] }, onChange: { [weak self] requests in
            self?.reconcile(requests)
        })
    }

    /// Ends the shown alert and panel and clears every request; late answers do nothing.
    func end() {
        generation = UUID()
        shown = [:]
        alerts.end()
        panels.cancel()
        launcher.pendingRemoval = nil
        launcher.refusedRemoval = nil
        launcher.renameTarget = nil
        launcher.pendingUploadDiscardTarget = nil
        launcher.selectionAlert = nil
        launcher.keyFileTarget = nil
        if list.pendingUploadAlert != nil { list.dismissPendingUploadAlert() }
    }

    private func requests() -> [Request] {
        var requests: [Request] = []
        if let reference = launcher.pendingRemoval { requests.append(.remove(reference.id)) }
        if let reference = launcher.refusedRemoval { requests.append(.refused(reference.id)) }
        if let reference = launcher.renameTarget { requests.append(.rename(reference.id)) }
        if let reference = launcher.pendingUploadDiscardTarget { requests.append(.discard(reference.id)) }
        if let selection = launcher.selectionAlert { requests.append(.selection(selection.id)) }
        if let pending = list.pendingUploadAlert { requests.append(.pendingUpload(pending.id)) }
        _ = launcher.keyFileTarget
        return requests
    }

    private func reconcile(_ requests: [Request]) {
        for (request, alert) in shown where !requests.contains(request) {
            shown[request] = nil
            alerts.cancel(alert)
        }
        for request in requests where shown[request] == nil {
            guard let alert = makeAlert(request) else { continue }
            shown[request] = alert
            let token = generation
            alerts.enqueue(alert) { [weak self] response in
                guard let self, generation == token, shown[request] === alert else { return }
                shown[request] = nil
                answer(request, response, alert: alert)
            }
        }
        if let reference = launcher.keyFileTarget {
            launcher.keyFileTarget = nil
            chooseKeyFile(for: reference)
        }
    }

    // MARK: - Alerts

    private func makeAlert(_ request: Request) -> NSAlert? {
        switch request {
        case .remove:
            guard let reference = launcher.pendingRemoval else { return nil }
            let alert = MacRemoveFromListAlert.makeAlert(.confirm, for: reference)
            alert.buttons.first?.setAccessibilityIdentifier("databases.remove.confirm")
            return alert
        case .refused:
            return launcher.refusedRemoval.map { MacRemoveFromListAlert.makeAlert(.refused, for: $0) }
        case .rename:
            guard let target = launcher.renameTarget else { return nil }
            let current = list.databases.first { $0.id == target.id } ?? target
            return Self.makeRenameAlert(for: current)
        case .discard:
            return launcher.pendingUploadDiscardTarget.map(Self.makeDiscardAlert)
        case .selection:
            guard let selection = launcher.selectionAlert else { return nil }
            let alert = NSAlert()
            alert.messageText = selection.title
            alert.informativeText = selection.message
            alert.addButton(withTitle: String(localized: "OK"))
            return alert
        case .pendingUpload:
            return list.pendingUploadAlert.map(makePendingUploadAlert)
        }
    }

    /// A request replaced between the click and this answer keeps its own alert; this answer is dropped.
    private func answer(_ request: Request, _ response: NSApplication.ModalResponse, alert: NSAlert) {
        let confirmed = response == .alertFirstButtonReturn
        switch request {
        case .remove(let id):
            guard let reference = launcher.pendingRemoval, reference.id == id else { return }
            launcher.pendingRemoval = nil
            // `remove` checks for unsaved work again; a refusal queues behind this alert.
            if confirmed { Task { await launcher.remove(reference) } }
        case .refused(let id):
            guard launcher.refusedRemoval?.id == id else { return }
            launcher.refusedRemoval = nil
        case .rename(let id):
            guard let reference = launcher.renameTarget, reference.id == id else { return }
            launcher.renameTarget = nil
            guard confirmed, let field = alert.accessoryView as? NSTextField else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            list.setNickname(name.isEmpty ? nil : name, for: reference)
        case .discard(let id):
            guard let reference = launcher.pendingUploadDiscardTarget, reference.id == id else { return }
            launcher.pendingUploadDiscardTarget = nil
            guard confirmed else { return }
            let list = list
            Task { await list.discardConflictedPendingUploads(for: reference) }
        case .selection(let id):
            guard launcher.selectionAlert?.id == id else { return }
            launcher.selectionAlert = nil
        case .pendingUpload(let id):
            guard list.pendingUploadAlert?.id == id else { return }
            let reference = list.pendingUploadAlert.flatMap { pending in
                pending.kind == .conflict ? list.databases.first { $0.id == pending.databaseId } : nil
            }
            list.dismissPendingUploadAlert()
            guard let reference else { return }
            // Answers run once this alert has detached, so the follow-up sheet is never dropped.
            switch response {
            case .alertFirstButtonReturn: launcher.exportRequest = .currentCopy(reference)
            case .alertSecondButtonReturn: launcher.pendingUploadDiscardTarget = reference
            default: break
            }
        }
    }

    private func chooseKeyFile(for reference: DatabaseReference) {
        let token = generation
        Task { [weak self] in
            guard let self, let url = await panels.chooseKeyFile(), token == generation else { return }
            do {
                try await list.setKeyFile(url: url, for: reference)
            } catch {
                launcher.selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
            }
        }
    }

    private func makePendingUploadAlert(_ pending: PendingUploadAlert) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = pending.title
        alert.informativeText = pending.message
        guard pending.kind == .conflict, list.databases.contains(where: { $0.id == pending.databaseId }) else {
            alert.addButton(withTitle: String(localized: "OK"))
            return alert
        }
        alert.addButton(withTitle: DatabaseExportLabels.currentCopy)
            .setAccessibilityIdentifier("pending-upload-conflict.export")
        let discard = alert.addButton(withTitle: String(localized: "Discard Pending Upload…"))
        discard.hasDestructiveAction = true
        discard.setAccessibilityIdentifier("pending-upload-conflict.discard")
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("pending-upload-conflict.cancel")
        return alert
    }

    static func makeRenameAlert(for reference: DatabaseReference) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Database")
        alert.informativeText = String(localized: "Use a custom name for \(reference.filename).")
        let field = NSTextField(string: reference.nickname ?? "")
        field.placeholderString = String(localized: "Nickname")
        field.setAccessibilityLabel(String(localized: "Nickname"))
        field.setAccessibilityIdentifier("databases.rename.field")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    static func makeDiscardAlert(for reference: DatabaseReference) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard Pending Upload?")
        alert.informativeText = String(localized: "The pending change for “\(reference.displayName)” could not be uploaded because the copy in the cloud changed. KeeForge keeps a timestamped backup on this device before discarding it.")
        let discard = alert.addButton(withTitle: String(localized: "Discard Upload"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        discard.setAccessibilityIdentifier("pending-upload-discard.confirm")
        // Cancel is the default (SyncProblems board), so Return never discards.
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\r"
        cancel.setAccessibilityIdentifier("pending-upload-discard.cancel")
        MacAlertEscapeKey.install(in: alert, clicking: cancel)
        return alert
    }
}

/// Escape for an alert whose Cancel button holds Return: NSAlert gives a button only one key.
@MainActor
enum MacAlertEscapeKey {
    static func install(in alert: NSAlert, clicking cancel: NSButton) {
        let escape = NSButton(title: "", target: cancel, action: #selector(NSButton.performClick(_:)))
        escape.keyEquivalent = "\u{1b}"
        // A hidden button takes no key equivalents; a zero-size one draws nothing.
        escape.frame = .zero
        escape.isBordered = false
        escape.setAccessibilityElement(false)
        alert.window.contentView?.addSubview(escape)
    }
}
