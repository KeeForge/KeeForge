import AppKit
import SwiftUI

@MainActor
final class MacWorkspaceSheets {
    let groupLockPrompt = MacGroupEditorLockPrompt()
    let session: DatabaseViewModel
    private let presentation: MacWorkspacePresentation
    private let window: @MainActor () -> NSWindow?
    private let observation = MacObservation()
    private var activeID: String?
    private var wasUnlocked: Bool
    private var cycle: Int
    private var invalidated = false
    private var sheetEndObserver: NSObjectProtocol?
    private(set) var childSheet: MacFormSheetController?
    private var iconPicker: MacIconPickerController?
    private var databaseSettings: MacDatabaseSettingsSheet?
    private var passwordImport: MacPasswordImportSheet?
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
        groupLockPrompt.end()
        childSheet?.end()
        iconPicker?.end()
        passwordImport?.discard()
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
        _ = session.pendingLockRequest
        _ = presentation.isShowingNewGroupSheet
        _ = presentation.entryIconID
        _ = editorCoordinator?.pendingLockRequest
        _ = presentation.groupEditor
        _ = presentation.pendingMove
        _ = presentation.passwordImport
        _ = presentation.isShowingDatabaseDetails
    }

    private var requestedID: String? {
        if presentation.passwordImport { return "import" }
        if presentation.isShowingNewGroupSheet { return "new" }
        if let id = presentation.entryIconID { return "icon-\(id)" }
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
        if let request = editorCoordinator?.pendingLockRequest, childSheet != nil {
            endChild()
            if editorCoordinator?.isDirty == false {
                session.resumeLockRequest(request)
                return
            }
        }
        if let coordinator = editorCoordinator, let parent = sheet?.window {
            let lockCycle = session.lockCycleID
            groupLockPrompt.reconcile(coordinator: coordinator, parent: parent,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return isCurrent(lockCycle) && editorCoordinator === coordinator
                }, complete: { [weak self] in self?.presentation.groupEditor = nil })
        }
        if let sheet {
            if requestedID == activeID {
                if activeID != "import" { sheet.setBusy(session.isSaving, label: String(localized: "Saving changes...")) }
                return
            }
            endCurrent()
            // AppKit must finish detaching before another sheet begins.
            Task { @MainActor [weak self] in self?.reconcile() }
            return
        }
        guard let id = requestedID, let parent = window(), parent.attachedSheet == nil else { return }
        if id.hasPrefix("icon-"), let entryID = presentation.entryIconID,
           session.isReadOnly || session.entry(withID: entryID) == nil {
            presentation.entryIconID = nil
            Task { @MainActor [weak self] in self?.reconcile() }
            return
        }
        let shell: MacFormSheetController
        let lockCycle = session.lockCycleID
        if id == "import" {
            let importer = MacPasswordImportSheet(session: session, presentation: presentation)
            passwordImport = importer
            shell = importer.shell
        } else if id == "new" {
            let parentID = presentation.newGroupParentID ?? session.workspace.selectedGroupID ?? session.workspaceRootGroupID
            shell = MacFormSheetController(title: String(localized: "New Group"), content: MacNewGroupView(
                name: Binding(get: { [weak self] in self?.presentation.newGroupName ?? "" }, set: { [weak self] value in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.newGroupName = value
                }), parentName: parentID.flatMap(session.group(withID:))?.name ?? "",
                error: Binding(get: { [weak self] in self?.presentation.groupCreationErrorMessage }, set: { _ in }),
                cancel: { [weak self] in self?.presentation.dismissNewGroup() },
                create: { [weak self] in
                    guard let self, isCurrent(lockCycle) else { return }
                    presentation.createGroup(named: presentation.newGroupName, in: session)
                }), size: NSSize(width: 420, height: 200), showsFooter: false)
        } else if let entryID = presentation.entryIconID, let entry = session.entry(withID: entryID) {
            let model = MacIconPickerModel(purpose: .entry,
                selection: entry.customIconUUID.map { .custom(uuid: $0) } ?? .standard(iconID: entry.iconID),
                customIcons: session.customIcons.filter { NSImage(data: $0.data) != nil }, websiteURL: entry.url)
            let picker = MacIconPickerController(title: entry.title.isEmpty ? String(localized: "Entry Icon") : entry.title, model: model, database: session, download: { [weak self] in
                guard let self, isCurrent(lockCycle), !session.isReadOnly else { return }
                try await session.downloadFavicon(forEntryID: entryID)
                await Task { await self.session.saveHandlingError() }.value
            })
            iconPicker = picker
            shell = picker.shell
        } else if let editor = presentation.groupEditor {
            let coordinator = DatabaseEditorCoordinator(group: editor, database: session)
            editorCoordinator = coordinator
            coordinator.activate()
            shell = MacFormSheetController(title: String(localized: "Edit Group"), content:
                MacGroupEditorView(form: editor, database: session, coordinator: coordinator,
                    chooseIcon: { [weak self] in self?.chooseGroupIcon() },
                    chooseParent: { [weak self] in self?.chooseGroupParent() }) { [weak self] in
                    guard let self, isCurrent(lockCycle), presentation.groupEditor === editor else { return }
                    presentation.groupEditor = nil
                }, size: NSSize(width: 600, height: 540), showsFooter: false)
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
            let settings = MacDatabaseSettingsSheet(model: MacDatabaseSettingsModel(reference: session.databaseReference, session: session))
            databaseSettings = settings
            shell = settings.shell
        }
        sheet = shell
        if id != "import" { shell.setBusy(session.isSaving, label: String(localized: "Saving changes...")) }
        activeID = id
        present(shell, parent) { [weak self, weak shell] confirmed in
            guard let self, let shell, self.sheet === shell, requestedID == id, isCurrent(lockCycle) else { return }
            if confirmed, !session.isSaving, !session.isReadOnly, let picker = shell.bodyController as? MacGroupPickerSheet,
               picker.model.canConfirm, let destination = picker.model.selection {
                presentation.pendingMove?.apply(destinationGroupID: destination, viewModel: session)
            }
            if confirmed, !session.isSaving, !session.isReadOnly,
               let entryID = presentation.entryIconID, let iconPicker {
                do {
                    try session.setEntryIcon(iconPicker.model.selection, entryID: entryID)
                    Task { await self.session.saveHandlingError() }
                } catch { session.presentSaveError(error) }
            }
            iconPicker = nil
            groupLockPrompt.end()
            databaseSettings?.model.commitNickname()
            databaseSettings = nil
            passwordImport?.discard()
            passwordImport = nil
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
        if id == "import" { presentation.passwordImport = false }
        else if id == "new" { presentation.dismissNewGroup() }
        else if id.hasPrefix("icon-") { presentation.entryIconID = nil }
        else if id.hasPrefix("edit-") { presentation.groupEditor = nil }
        else if id.hasPrefix("move-") { presentation.pendingMove = nil }
        else if id == "details" { presentation.isShowingDatabaseDetails = false }
    }

    private func endCurrent() {
        groupLockPrompt.end()
        endChild()
        passwordImport?.discard()
        passwordImport = nil
        let old = sheet
        sheet = nil
        iconPicker?.end()
        iconPicker = nil
        activeID = nil
        editorCoordinator?.deactivate()
        editorCoordinator = nil
        databaseSettings?.model.commitNickname()
        old?.end()
        databaseSettings = nil
    }

    func chooseGroupParent() {
        guard let editor = presentation.groupEditor, let parent = sheet?.window,
              childSheet == nil, !session.isSaving, isCurrent(cycle) else { return }
        let model = MacGroupPickerModel(purpose: .move(.group(editor.groupID)), database: session, current: editor.parentGroupID)
        let picker = MacGroupPickerSheet(model: model)
        let child = MacFormSheetController(title: model.title, content: picker, size: NSSize(width: 500, height: 460), defaultTitle: model.confirmTitle)
        child.canConfirm = model.canConfirm
        child.defaultButton.setAccessibilityIdentifier("move-picker.move")
        child.cancelButton.setAccessibilityIdentifier("move-picker.cancel")
        picker.onSelectionChange = { [weak child] in child?.canConfirm = model.canConfirm }
        picker.onDoubleClick = { [weak child] in child?.performDefault() }
        beginChild(child, on: parent) { [weak self] confirmed in
            guard let self, confirmed, model.canConfirm, presentation.groupEditor === editor else { return }
            editor.parentGroupID = model.selection
            editorCoordinator?.synchronizeUnsavedChanges()
        }
    }

    func chooseGroupIcon() {
        guard let editor = presentation.groupEditor, let parent = sheet?.window,
              childSheet == nil, !session.isSaving, isCurrent(cycle) else { return }
        let picker = MacIconPickerController(title: editor.trimmedName,
            model: MacIconPickerModel(purpose: .group, selection: .standard(iconID: editor.iconID)))
        iconPicker = picker
        beginChild(picker.shell, on: parent) { [weak self] confirmed in
            guard let self, confirmed, presentation.groupEditor === editor,
                  case .standard(let id) = picker.model.selection else { return }
            editor.iconID = id
            editorCoordinator?.synchronizeUnsavedChanges()
        }
    }

    private func beginChild(_ child: MacFormSheetController, on parent: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
        childSheet = child
        editorCoordinator?.hasPresentedChild = true
        let cycle = session.lockCycleID
        present(child, parent) { [weak self, weak child] confirmed in
            guard let self, childSheet === child, isCurrent(cycle) else { return }
            childSheet = nil
            iconPicker = nil
            editorCoordinator?.hasPresentedChild = false
            completion(confirmed)
        }
    }

    private func endChild() {
        let child = childSheet
        childSheet = nil
        if child != nil {
            iconPicker?.end()
            iconPicker = nil
        }
        child?.end()
        editorCoordinator?.hasPresentedChild = false
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
