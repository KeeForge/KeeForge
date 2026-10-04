import Foundation
import Observation

@MainActor @Observable
final class DatabaseEditorCoordinator {
    private enum Form {
        case entry(EntryEditViewModel)
        case group(GroupEditViewModel)
    }

    private let form: Form
    private let database: DatabaseViewModel
    private let editorID = UUID()
    private var isActive = false
    private var lifetime = UUID()
    private var activatedLockCycle = 0
    private var completionGate = EntryEditCompletionGate()
    private(set) var isSubmitting = false
    var errorMessage: String?

    init(entry: EntryEditViewModel, database: DatabaseViewModel) {
        form = .entry(entry)
        self.database = database
    }

    init(group: GroupEditViewModel, database: DatabaseViewModel) {
        form = .group(group)
        self.database = database
    }

    var isDirty: Bool {
        switch form {
        case .entry(let entry): entry.isDirty
        case .group(let group): group.isDirty
        }
    }

    var canSave: Bool {
        switch form {
        case .entry(let entry): entry.canSave
        case .group(let group): group.canSave
        }
    }

    var isSavingInProgress: Bool { isSubmitting || database.isSaving }

    var pendingLockRequest: DatabaseViewModel.PendingLockRequest? {
        guard isDirty, let request = database.pendingLockRequest,
              request.reason == .openEditor else { return nil }
        return request
    }

    var conflictHasSettled: Bool {
        EntryEditCompletionGate.isSettled(
            hasSaveConflict: database.saveConflict != nil,
            isPresentingMergeResult: database.mergeSummaryMessage != nil || database.mergeFailure != nil,
            isDirty: database.isDirty
        )
    }

    func activate() {
        isActive = true
        activatedLockCycle = database.lockCycleID
        synchronizeUnsavedChanges()
    }

    func synchronizeUnsavedChanges() {
        guard isActive else { return }
        database.setEditorHasUnsavedChanges(isDirty, editorID: editorID)
    }

    func deactivate() {
        isActive = false
        lifetime = UUID()
        completionGate = EntryEditCompletionGate()
        database.setEditorHasUnsavedChanges(false, editorID: editorID)
    }

    func discard(
        resuming request: DatabaseViewModel.PendingLockRequest? = nil,
        onComplete: (EntryEditCompletion) -> Void
    ) {
        guard isActive, isSavingInProgress == false else { return }
        deactivate()
        onComplete(.cancelled)
        if let request { database.resumeLockRequest(request) }
    }

    func continueEditingAfterLockRequest() async {
        await database.continueEditingAfterLockRequest()
    }

    func completeAfterConflictIfSettled(onComplete: (EntryEditCompletion) -> Void) {
        guard isActive, database.lockCycleID == activatedLockCycle, isSubmitting == false,
              let completion = completionGate.conflictSettled(conflictHasSettled) else { return }
        onComplete(completion)
    }

    func save(
        resuming request: DatabaseViewModel.PendingLockRequest? = nil,
        onComplete: (EntryEditCompletion) -> Void
    ) async {
        guard isActive, canSave, isSavingInProgress == false else { return }
        do {
            switch form {
            case .entry(let entry):
                switch entry.mode {
                case .create(let parentGroupID):
                    try database.applyEntryEdit(.createEntry(parentGroupID: parentGroupID, draft: entry.entryDraftPayload))
                case .edit(let entryID):
                    try database.applyEntryEdit(.updateEntry(entryID: entryID, draft: entry.entryDraftPayload))
                }
            case .group(let group):
                try database.updateGroup(groupID: group.groupID, draft: group.makeDraftPayload())
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Once applied, unsaved changes belong to the database draft.
        database.setEditorHasUnsavedChanges(false, editorID: editorID)
        await persist(completion: .saved, resuming: request, onComplete: onComplete)
    }

    func delete(sendToRecycleBin: Bool, onComplete: (EntryEditCompletion) -> Void) async {
        guard isActive, isSavingInProgress == false,
              case .entry(let entry) = form, case .edit(let entryID) = entry.mode else { return }
        do {
            try database.deleteEntry(entryID, sendToRecycleBin: sendToRecycleBin)
            await persist(completion: .deleted, onComplete: onComplete)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist(
        completion: EntryEditCompletion,
        resuming request: DatabaseViewModel.PendingLockRequest? = nil,
        onComplete: (EntryEditCompletion) -> Void
    ) async {
        let submittedLifetime = lifetime
        let lockCycle = database.lockCycleID
        isSubmitting = true
        defer { isSubmitting = false }
        await database.saveHandlingError()
        guard isActive, lifetime == submittedLifetime, database.lockCycleID == lockCycle else { return }

        if let request {
            finish(completion, onComplete: onComplete)
            database.resumeLockRequest(request)
        } else if let saveError = database.saveError {
            errorMessage = saveError.localizedDescription
            database.clearSaveError()
        } else {
            finish(completion, onComplete: onComplete)
        }
    }

    private func finish(_ completion: EntryEditCompletion, onComplete: (EntryEditCompletion) -> Void) {
        if let completion = completionGate.finish(completion, hasSaveConflict: database.saveConflict != nil) {
            onComplete(completion)
        }
    }
}
