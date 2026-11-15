import AppKit

@MainActor
final class MacGroupEditorLockPrompt {
    private(set) var alert: NSAlert?
    private var request: DatabaseViewModel.PendingLockRequest?
    private var answeredRequest: DatabaseViewModel.PendingLockRequest?
    var present: @MainActor (NSAlert, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }

    func reconcile(coordinator: DatabaseEditorCoordinator, parent: NSWindow,
                   isCurrent: @escaping @MainActor () -> Bool, complete: @escaping @MainActor () -> Void) {
        guard let pending = coordinator.pendingLockRequest else { end(); return }
        if answeredRequest == pending { return }
        if request == pending, let alert {
            alert.buttons.first?.isEnabled = coordinator.canSave && !coordinator.isSavingInProgress
            return
        }
        end()
        request = pending
        let alert = NSAlert()
        alert.messageText = String(localized: "Save your changes before locking?")
        alert.informativeText = String(localized: "Your group changes haven't been saved to this database yet.")
        alert.addButton(withTitle: String(localized: "Save and Lock"))
        alert.buttons[0].isEnabled = coordinator.canSave && !coordinator.isSavingInProgress
        alert.addButton(withTitle: String(localized: "Discard and Lock")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Keep Editing")).keyEquivalent = "\u{1b}"
        self.alert = alert
        present(alert, parent) { [weak self, weak alert] response in
            guard let self, let alert, self.alert === alert, request == pending, isCurrent(),
                  coordinator.pendingLockRequest == pending else { return }
            self.alert = nil
            answeredRequest = pending
            switch response {
            case .alertFirstButtonReturn:
                Task { await coordinator.save(resuming: pending) { _ in complete() } }
            case .alertSecondButtonReturn:
                coordinator.discard(resuming: pending) { _ in complete() }
            default:
                Task { await coordinator.continueEditingAfterLockRequest() }
            }
        }
    }

    func end() {
        let old = alert
        alert = nil
        request = nil
        answeredRequest = nil
        if let window = old?.window {
            window.sheetParent?.endSheet(window, returnCode: .cancel)
            window.orderOut(nil)
        }
    }
}
