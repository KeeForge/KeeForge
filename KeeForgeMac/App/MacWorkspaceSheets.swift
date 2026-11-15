import AppKit
import SwiftUI

@MainActor
final class MacWorkspaceSheets {
    let session: DatabaseViewModel
    private let presentation: MacWorkspacePresentation
    private let window: @MainActor () -> NSWindow?
    private let observation = MacObservation()
    private var activeID: String?
    private var wasUnlocked: Bool
    private var cycle: Int
    private var invalidated = false
    private var sheetEndObserver: NSObjectProtocol?
    private var editorCoordinator: DatabaseEditorCoordinator?
    private(set) var sheet: MacFormSheetController?
    var present: @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void = {
        $0.begin(on: $1, completion: $2)
    }

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation, window: @escaping @MainActor () -> NSWindow?) {
        self.session = session
        self.presentation = presentation
        self.window = window
        wasUnlocked = session.state == .unlocked
        cycle = session.lockCycleID
    }

    isolated deinit {
        observation.cancel()
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheet?.end()
        editorCoordinator?.deactivate()
    }

    func start() {
        sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        observation.start(reading: { [weak self] in self?.readState() }, onChange: { [weak self] _ in self?.reconcile() })
    }

    private func readState() {
        _ = session.state
        _ = session.lockCycleID
        _ = session.isSaving
        _ = presentation.isShowingNewGroupSheet
        _ = presentation.groupEditor
        _ = presentation.pendingMove
        _ = presentation.isShowingDatabaseDetails
    }

    private var requestedID: String? {
        if presentation.isShowingNewGroupSheet { return "new" }
        if let editor = presentation.groupEditor { return "edit-\(editor.id)" }
        if let pending = presentation.pendingMove { return "move-\(pending.id)" }
        if presentation.isShowingDatabaseDetails { return "details" }
        return nil
    }

    private func reconcile() {
        guard !invalidated else { return }
        guard session.state == .unlocked, cycle == session.lockCycleID else {
            cycle = session.lockCycleID
            endCurrent()
            if wasUnlocked || requestedID != nil { presentation.reset() }
            wasUnlocked = false
            return
        }
        wasUnlocked = true
        if let sheet {
            if requestedID == activeID { sheet.setBusy(session.isSaving, label: String(localized: "Saving changes...")); return }
            endCurrent()
            // AppKit must finish detaching before another sheet begins.
            Task { @MainActor [weak self] in self?.reconcile() }
            return
        }
        guard let id = requestedID, let parent = window(), parent.attachedSheet == nil else { return }
        let shell: MacFormSheetController
        let lockCycle = session.lockCycleID
        if id == "new" {
            shell = MacFormSheetController(title: String(localized: "New Group"), content: NewGroupSheet(
                name: Binding(get: { [weak self] in self?.presentation.newGroupName ?? "" }, set: { [weak self] value in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.newGroupName = value
                }),
                errorMessage: Binding(get: { [weak self] in self?.presentation.groupCreationErrorMessage }, set: { [weak self] value in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.groupCreationErrorMessage = value
                }),
                onCancel: { [weak self] in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.dismissNewGroup()
                },
                onCreate: { [weak self] name in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.createGroup(named: name, in: session)
                }), size: NSSize(width: 460, height: 240), showsFooter: false)
        } else if let editor = presentation.groupEditor {
            let coordinator = DatabaseEditorCoordinator(group: editor, database: session)
            editorCoordinator = coordinator
            coordinator.activate()
            shell = MacFormSheetController(title: String(localized: "Edit Group"), content: NavigationStack {
                GroupEditView(formViewModel: editor, databaseViewModel: session, coordinator: coordinator) { [weak self] in
                    guard let self, isCurrent(lockCycle), presentation.groupEditor === editor else { return }
                    presentation.groupEditor = nil
                }
            }.macSheetFrame(minHeight: 480), size: NSSize(width: 560, height: 560), showsFooter: false)
        } else if let pending = presentation.pendingMove {
            let model = MacGroupPickerModel(purpose: .move(pending), database: session)
            let picker = MacGroupPickerSheet(model: model)
            shell = MacFormSheetController(title: model.title, content: picker, size: NSSize(width: 500, height: 460),
                                           defaultTitle: model.confirmTitle)
            shell.cancelButton.setAccessibilityIdentifier("move-picker.cancel")
            shell.defaultButton.setAccessibilityIdentifier("move-picker.move")
            shell.canConfirm = model.canConfirm
            picker.onSelectionChange = { [weak shell] in shell?.canConfirm = model.canConfirm }
            picker.onDoubleClick = { [weak shell] in shell?.performDefault() }
        } else {
            shell = MacFormSheetController(title: String(localized: "Database Details"), content:
                DatabaseDetailsView(reference: session.databaseReference, sessionViewModel: session, onClose: { [weak self] in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.isShowingDatabaseDetails = false
                }), size: NSSize(width: 640, height: 560), showsFooter: false)
        }
        sheet = shell
        shell.setBusy(session.isSaving, label: String(localized: "Saving changes..."))
        activeID = id
        present(shell, parent) { [weak self, weak shell] confirmed in
            guard let self, let shell, self.sheet === shell, requestedID == id, isCurrent(lockCycle) else { return }
            if confirmed, !session.isSaving, !session.isReadOnly, let picker = shell.bodyController as? MacGroupPickerSheet,
               picker.model.canConfirm, let destination = picker.model.selection {
                presentation.pendingMove?.apply(destinationGroupID: destination, viewModel: session)
            }
            clearRequest(id)
            self.sheet = nil
            activeID = nil
            editorCoordinator?.deactivate()
            editorCoordinator = nil
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    private func isCurrent(_ lockCycle: Int) -> Bool {
        !invalidated && session.state == .unlocked && session.lockCycleID == lockCycle
    }

    private func clearRequest(_ id: String) {
        if id == "new" { presentation.dismissNewGroup() }
        else if id.hasPrefix("edit-") { presentation.groupEditor = nil }
        else if id.hasPrefix("move-") { presentation.pendingMove = nil }
        else if id == "details" { presentation.isShowingDatabaseDetails = false }
    }

    private func endCurrent() {
        let old = sheet
        sheet = nil
        activeID = nil
        editorCoordinator?.deactivate()
        editorCoordinator = nil
        old?.end()
    }

    func invalidate() {
        invalidated = true
        observation.cancel()
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
        endCurrent()
        presentation.reset()
    }
}
