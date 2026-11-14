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
    var isShowingDatabaseDetails = false
    var presentedSaveError: DatabaseSaveError?
    var isCloudReconnectInFlight = false
    /// The list's copy ticks, and the detail pane's later.
    let copyFeedback = MacCopyFeedback()
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
        copyFeedback.clear()
    }
}
#endif
