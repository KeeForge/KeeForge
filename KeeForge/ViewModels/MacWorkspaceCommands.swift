#if os(macOS)
import Foundation

/// The Mac menu bar's window-scoped commands: those that need the window's
/// `MacWorkspacePresentation` as well as its session. `session` is nil while
/// the window is not the command target, which disables every command.
@MainActor
struct MacWorkspaceCommands {
    let session: DatabaseViewModel?
    let presentation: MacWorkspacePresentation

    private var unlocked: DatabaseViewModel? {
        session?.state == .unlocked ? session : nil
    }

    /// Unlocked, with no save running and no inline editor open.
    private var unfrozen: DatabaseViewModel? {
        guard let session = unlocked, presentation.freezesWorkspace(session) == false else { return nil }
        return session
    }

    // MARK: - File

    /// File ▸ Save saves the open inline editor, which writes the database with it; otherwise the database.
    var canSave: Bool {
        guard let session = unlocked else { return false }
        if let editor = presentation.currentEntryEditor(in: session) { return editor.canSave }
        return DatabaseCommands(session: session).canSave
    }

    @discardableResult
    func save() -> Task<Void, Never>? {
        guard canSave, let session else { return nil }
        if presentation.currentEntryEditor(in: session) != nil { return presentation.saveEntryEditor() }
        return DatabaseCommands(session: session).save()
    }

    /// Import outranks every other window sheet, so it waits until none is up rather than ending one.
    var canImportPasswords: Bool {
        guard let session = unfrozen, !presentation.hasWorkspaceSheet else { return false }
        return !session.isReadOnly && !session.isSaving
    }

    func importPasswords() {
        guard canImportPasswords else { return }
        presentation.passwordImport = true
    }

    var canExportDatabase: Bool {
        guard let session else { return false }
        return (try? DatabaseFileAccess.withReadableURL(for: session.databaseReference) {
            FileManager.default.isReadableFile(atPath: $0.path)
        }) == true
    }

    // MARK: - Library

    var canShowCollection: Bool { unfrozen != nil }

    func isShowing(_ collection: DatabaseCollection) -> Bool {
        unlocked?.workspace.selectedCollection == collection
    }

    func show(_ collection: DatabaseCollection) {
        guard let session = unfrozen else { return }
        session.workspace.selectedCollection = collection
    }

    // MARK: - Duplicate and Move

    var canDuplicate: Bool {
        guard let session = unfrozen, let entryID = session.workspace.commandEntryID, session.entry(withID: entryID) != nil else { return false }
        return EntryRowActions(entryID: entryID, session: session).canDuplicate
    }

    /// Search and tag lists select the copy in place, as the row menu does.
    func duplicate() {
        guard canDuplicate, let session, let entryID = session.workspace.commandEntryID,
              let editor = EntryRowActions(entryID: entryID, session: session).makeDuplicateEditor() else { return }
        let selectsInPlace = switch MacEntryListSnapshot.mode(session: session) {
        case .search, .tag: true
        default: false
        }
        presentation.beginEntryDuplicate(editor, in: session, selectingInPlace: selectsInPlace)
    }

    /// The picked entries while several are selected, else the selected entry.
    var pendingMove: PendingMove? {
        guard let session = unfrozen, session.isReadOnly == false else { return nil }
        if let selection = session.workspace.entrySelection {
            return selection.isEmpty ? nil : .entries(selection)
        }
        guard let entryID = session.workspace.selectedEntryID, session.entry(withID: entryID) != nil,
              EntryRowActions(entryID: entryID, session: session).canMove else { return nil }
        return .entry(entryID)
    }

    var canMoveToGroup: Bool { pendingMove != nil }

    func moveToGroup() {
        if let session { MacEntryListSelection.dropHiddenPicks(session: session) }
        guard let pendingMove else { return }
        presentation.pendingMove = pendingMove
    }

    // MARK: - Sort

    var canSort: Bool {
        guard let session = unlocked else { return false }
        return MacEntryListSnapshot.listIsEmpty(session: session) == false
    }

    func setSortOrder(_ order: DatabaseViewModel.SortOrder) {
        guard canSort, let session else { return }
        session.sortOrder = order
    }

    func setSortAscending(_ ascending: Bool) {
        guard canSort, let session else { return }
        session.sortAscending = ascending
    }

    // MARK: - Groups

    private var collapsibleGroupIDs: Set<UUID> {
        guard let session = unlocked else { return [] }
        return MacSidebarSnapshot.make(session: session).collapsibleGroupIDs
    }

    var canExpandAllGroups: Bool {
        presentation.collapsedGroupIDs.isDisjoint(with: collapsibleGroupIDs) == false
    }

    var canCollapseAllGroups: Bool {
        collapsibleGroupIDs.isSubset(of: presentation.collapsedGroupIDs) == false
    }

    func expandAllGroups() {
        guard canExpandAllGroups else { return }
        presentation.collapsedGroupIDs = []
    }

    /// The sidebar keeps the selected row's ancestors unfolded.
    func collapseAllGroups() {
        guard canCollapseAllGroups else { return }
        presentation.collapsedGroupIDs.formUnion(collapsibleGroupIDs)
    }

    // MARK: - Database

    var canSyncNow: Bool {
        guard let session = unlocked else { return false }
        return CloudSyncControls.isVisible(for: session) && session.canSyncCloudNow
    }

    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        guard canSyncNow, let session else { return nil }
        return Task { await session.syncCloudNow() }
    }

    /// Database ▸ Discard Pending Upload…: a conflicted AutoFill upload, with no
    /// unsaved draft, save, editor or discard that it could race, and no sheet up.
    /// Read-only windows show no conflict, and a session that opened the AutoFill
    /// save itself would upload it again on its next save, so neither offers it.
    var canDiscardPendingUpload: Bool {
        guard let session = unfrozen, !presentation.hasWorkspaceSheet, !session.isDirty, !session.isReadOnly,
              !presentation.isDiscardingPendingUpload, !session.holdsPendingUploadPayload else { return false }
        return session.hasPendingUploadConflict
            || presentation.pendingUploads.counts(session.databaseReference.id).conflicts > 0
    }

    var canShowDatabaseSettings: Bool { unlocked != nil }

    func showDatabaseSettings() {
        guard canShowDatabaseSettings else { return }
        presentation.isShowingDatabaseDetails = true
    }

    /// The sheet reports the rekey's other preconditions (a save running, unsaved changes), as before.
    var canChangeMasterKey: Bool {
        guard let session = unlocked else { return false }
        return !session.isReadOnly
    }

    func changeMasterKey() {
        guard canChangeMasterKey else { return }
        presentation.masterKeyChangeRequested = true
        presentation.isShowingDatabaseDetails = true
    }
}
#endif
