#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacWorkspacePresentation {
    var commandEditor: EntryEditViewModel? {
        didSet { if commandEditor == nil { selectsCreatedEntryInPlace = false } }
    }
    /// A duplicate made from search results or a tag selects the copy where the
    /// list is, instead of revealing it in its group.
    private(set) var selectsCreatedEntryInPlace = false
    var groupEditor: GroupEditViewModel?
    var isShowingNewGroupSheet = false
    var newGroupName = ""
    var newGroupParentID: UUID?
    var groupCreationErrorMessage: String?
    var pendingDeletion: PendingDeletion?
    var pendingMove: PendingMove?
    /// Sidebar groups the user folded. `reset()` keeps it, so it lasts for the
    /// window's life across lock and unlock; it is never written to disk.
    var collapsedGroupIDs: Set<UUID> = []
    /// Sidebar sections the user folded, kept like `collapsedGroupIDs`.
    var collapsedSidebarSections: Set<MacSidebarSnapshot.SectionKind> = []
    /// Mirrors the split view's sidebar collapse, which AppKit owns and autosaves,
    /// so the list header can show the group's path while the sidebar is hidden.
    var isSidebarCollapsed = false
    var isShowingDatabaseDetails = false
    var presentedSaveError: DatabaseSaveError?
    var isCloudReconnectInFlight = false
    /// Bumped by the status card's Resolve…, which brings the Save Conflict alert back.
    private(set) var saveConflictPromptRequestID = 0
    /// Set once by the window's owner; the database list holds the markers.
    @ObservationIgnored var pendingUploads = MacPendingUploads.none
    /// What went wrong with a Push Pending Changes this window asked for, shown in this window.
    private(set) var pushAlert: PendingUploadAlert?
    /// Advanced every minute while the workspace is shown, so "Synced 5 minutes ago" keeps up.
    private(set) var statusClockTick = 0
    /// The list's and the detail pane's copy ticks.
    let copyFeedback = MacCopyFeedback()
    /// Replaced when the selected entry or session changes, which conceals what the old one revealed.
    @ObservationIgnored private var currentDetailModel: MacEntryDetailModel?
    private(set) var lifetimeID = UUID()

    func beginNewEntry(in database: DatabaseViewModel) {
        guard commandEditor == nil, DatabaseCommands(session: database).canNewEntry,
              let targetID = database.workspace.selectedGroupID ?? database.workspaceRootGroupID,
              database.group(withID: targetID) != nil else { return }
        commandEditor = EntryEditViewModel(
            createIn: targetID,
            knownTags: database.tagsInDisplayOrder,
            inheritedTags: database.inheritedTags(forGroupID: targetID)
        )
    }

    func beginEntryEdit(entryID: UUID, in database: DatabaseViewModel) {
        guard commandEditor == nil, database.state == .unlocked, !database.isReadOnly,
              let entry = database.entry(withID: entryID), let key = database.sessionKey else { return }
        commandEditor = EntryEditViewModel(
            editing: entry, sessionKey: key,
            knownTags: database.tagsInDisplayOrder,
            inheritedTags: database.inheritedTags(forEntryID: entryID)
        )
    }

    func beginSelectedEntryEdit(in database: DatabaseViewModel) {
        guard let entryID = database.workspace.commandEntryID else { return }
        beginEntryEdit(entryID: entryID, in: database)
    }

    func beginEntryDuplicate(_ editor: EntryEditViewModel, selectingInPlace: Bool = false) {
        guard commandEditor == nil else { return }
        commandEditor = editor
        selectsCreatedEntryInPlace = selectingInPlace
    }

    /// Where a saved New Entry or Duplicate lands once the editor sheet completes.
    func showCreatedEntry(_ entryID: UUID, in database: DatabaseViewModel) {
        if selectsCreatedEntryInPlace {
            database.workspace.selectedEntryID = entryID
        } else {
            database.revealEntry(entryID)
        }
    }

    /// The selected entry's detail model, kept while that entry stays selected.
    func detailModel(
        for entryID: UUID,
        in database: DatabaseViewModel,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?
    ) -> MacEntryDetailModel {
        if let model = currentDetailModel, model.source == .live(entryID), model.session === database {
            return model
        }
        currentDetailModel?.invalidate()
        let model = MacEntryDetailModel(source: .live(entryID), session: database, copyFeedback: copyFeedback,
                                        currentSession: currentSession)
        currentDetailModel = model
        return model
    }

    func beginGroupEdit(groupID: UUID, in database: DatabaseViewModel) {
        guard groupEditor == nil, database.state == .unlocked, !database.isReadOnly,
              !database.isSyntheticRootGroup(groupID: groupID), let group = database.group(withID: groupID) else { return }
        groupEditor = GroupEditViewModel(
            editing: group,
            isHiddenFromAutoFill: database.isGroupExcludedFromAutoFill(groupID: groupID),
            isExclusionInherited: database.isGroupExclusionInherited(groupID: groupID),
            knownTags: database.tagsInDisplayOrder
        )
    }

    func beginNewGroup(parentID: UUID? = nil) {
        newGroupName = ""
        newGroupParentID = parentID
        groupCreationErrorMessage = nil
        isShowingNewGroupSheet = true
    }

    func dismissNewGroup() {
        newGroupName = ""
        newGroupParentID = nil
        groupCreationErrorMessage = nil
        isShowingNewGroupSheet = false
    }

    func createGroup(named name: String, in database: DatabaseViewModel) {
        guard let parentID = newGroupParentID ?? database.workspace.selectedGroupID ?? database.workspaceRootGroupID else { return }
        do {
            try database.createGroup(named: name, in: parentID)
            dismissNewGroup()
            Task { await database.saveHandlingError() }
        } catch {
            groupCreationErrorMessage = error.localizedDescription
        }
    }

    func beginSelectionDeletion(in database: DatabaseViewModel) {
        MacEntryListSelection.dropHiddenPicks(session: database)
        switch database.deletableSelection {
        case .entry(let entryID):
            pendingDeletion = .entry(PendingEntryDeletion(
                entryID: entryID,
                sendToRecycleBin: !database.isEntryInRecycleBin(entryID: entryID)
            ))
        case .group(let groupID):
            guard let pending = PendingGroupDeletion(groupID: groupID, viewModel: database) else { return }
            pendingDeletion = .group(pending)
        case .entries(let entryIDs):
            pendingDeletion = .entries(entryIDs)
        case nil:
            return
        }
    }

    /// Pushes through the list's one push; its result belongs to this window, not the Databases window.
    @discardableResult
    func pushPendingUploads(in database: DatabaseViewModel) -> Task<Void, Never> {
        let lifetimeID = self.lifetimeID
        let push = pendingUploads.push
        let databaseID = database.databaseReference.id
        return Task { @MainActor in
            let alert = await push(databaseID)
            guard self.lifetimeID == lifetimeID, let alert else { return }
            pushAlert = alert
        }
    }

    func dismissPushAlert() {
        pushAlert = nil
    }

    func advanceStatusClock() {
        statusClockTick += 1
    }

    func requestSaveConflictPrompt() {
        saveConflictPromptRequestID += 1
    }

    @discardableResult
    func reconnectCloud(
        in database: DatabaseViewModel,
        authenticate: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never>? {
        guard !isCloudReconnectInFlight, database.state == .unlocked else { return nil }
        let lifetimeID = self.lifetimeID
        let lockCycleID = database.lockCycleID
        isCloudReconnectInFlight = true
        return Task { @MainActor in
            defer {
                if self.lifetimeID == lifetimeID { isCloudReconnectInFlight = false }
            }
            guard self.lifetimeID == lifetimeID, database.lockCycleID == lockCycleID else { return }
            do {
                try await authenticate()
                guard self.lifetimeID == lifetimeID, database.lockCycleID == lockCycleID else { return }
                database.clearSaveError()
            } catch let error as CloudProviderError where error == .authenticationCancelled {
                return
            } catch {
                guard self.lifetimeID == lifetimeID, database.lockCycleID == lockCycleID else { return }
                database.presentSaveError(error)
            }
        }
    }

    func reset() {
        lifetimeID = UUID()
        commandEditor = nil
        groupEditor = nil
        dismissNewGroup()
        pendingDeletion = nil
        pendingMove = nil
        isShowingDatabaseDetails = false
        presentedSaveError = nil
        isCloudReconnectInFlight = false
        pushAlert = nil
        copyFeedback.clear()
        currentDetailModel?.invalidate()
        currentDetailModel = nil
    }
}
#endif
