import SwiftUI

// The pending row actions every shell raises before it mutates the draft: the
// delete confirmation and the Move-to-Group destination pick. They live here
// rather than on one screen because three surfaces raise them — the iOS/iPad
// group list, the shared entry list behind search and the tag browser, and the
// macOS three-column workspace — and a destructive act must read the same
// wherever it was triggered.

struct PendingEntryDeletion: Identifiable {
    let entryID: UUID
    let sendToRecycleBin: Bool

    var id: String {
        "\(entryID.uuidString)-\(sendToRecycleBin)"
    }
}

struct PendingGroupDeletion: Identifiable {
    let groupID: UUID
    let groupName: String
    let entryCount: Int
    let nestedGroupCount: Int
    let sendToRecycleBin: Bool

    var id: String {
        "\(groupID.uuidString)-\(sendToRecycleBin)"
    }
}

extension PendingGroupDeletion {
    /// Snapshots the subtree counts the confirmation reports; `nil` when the
    /// group has already left the draft.
    @MainActor
    init?(groupID: UUID, viewModel: DatabaseViewModel) {
        guard let summary = viewModel.groupDeletionSummary(forGroupID: groupID) else { return nil }
        self.init(
            groupID: groupID,
            groupName: summary.name,
            entryCount: summary.entryCount,
            nestedGroupCount: summary.nestedGroupCount,
            sendToRecycleBin: viewModel.isGroupInRecycleBin(groupID: groupID) == false
        )
    }
}

enum PendingDeletion: Identifiable {
    case entry(PendingEntryDeletion)
    case group(PendingGroupDeletion)

    var id: String {
        switch self {
        case .entry(let action):
            "entry-\(action.id)"
        case .group(let action):
            "group-\(action.id)"
        }
    }
}

extension PendingDeletion {
    /// The confirmation's title, shared by the iOS `Alert` and the macOS
    /// `confirmationDialog`.
    var confirmationTitle: String {
        switch self {
        case .entry(let action):
            action.sendToRecycleBin
                ? String(localized: "Delete Entry?")
                : String(localized: "Delete Permanently?")
        case .group(let action):
            action.sendToRecycleBin
                ? String(localized: "Delete Group?")
                : String(localized: "Delete Permanently?")
        }
    }

    /// The destructive button's title.
    var confirmActionTitle: String {
        let sendToRecycleBin: Bool
        switch self {
        case .entry(let action):
            sendToRecycleBin = action.sendToRecycleBin
        case .group(let action):
            sendToRecycleBin = action.sendToRecycleBin
        }
        return sendToRecycleBin ? String(localized: "Delete") : String(localized: "Delete Permanently")
    }

    /// The confirmation's explanatory message.
    var confirmationMessage: String {
        switch self {
        case .entry(let action):
            action.sendToRecycleBin
                ? String(localized: "The entry will be moved to the recycle bin.")
                : String(localized: "This entry will be removed immediately and cannot be restored from KeeForge.")
        case .group(let action):
            Self.groupDeletionMessage(for: action)
        }
    }

    /// Performs the deletion and saves, surfacing any error. Shared by both
    /// platforms' confirmations.
    @MainActor
    func performDeletion(viewModel: DatabaseViewModel) {
        do {
            switch self {
            case .entry(let action):
                try viewModel.deleteEntry(action.entryID, sendToRecycleBin: action.sendToRecycleBin)
            case .group(let action):
                try viewModel.deleteGroup(action.groupID, sendToRecycleBin: action.sendToRecycleBin)
            }
            Task { await viewModel.saveHandlingError() }
        } catch {
            viewModel.presentSaveError(error)
        }
    }

    /// Hosts belong on the body's outer container: deleting the last row flips
    /// a list into its empty branch, which would tear a branch-scoped alert
    /// host down while the alert is up.
    @MainActor
    func confirmationAlert(viewModel: DatabaseViewModel) -> Alert {
        Alert(
            title: Text(confirmationTitle),
            message: Text(confirmationMessage),
            primaryButton: .destructive(Text(confirmActionTitle)) {
                performDeletion(viewModel: viewModel)
            },
            secondaryButton: .cancel()
        )
    }

    private static func groupDeletionMessage(for action: PendingGroupDeletion) -> String {
        let contents = "\(entryCountText(action.entryCount)) and \(nestedGroupCountText(action.nestedGroupCount))"
        if action.sendToRecycleBin {
            return String(localized: "\"\(action.groupName)\" contains \(contents). The group and its contents will be moved to the recycle bin.")
        }
        return String(localized: "\"\(action.groupName)\" contains \(contents). The group and its contents will be removed immediately and cannot be restored from KeeForge.")
    }

    private static func entryCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 entry")
            : String(localized: "\(count) entries")
    }

    private static func nestedGroupCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 nested group")
            : String(localized: "\(count) nested groups")
    }
}

/// Identifies the item whose Move-to-Group picker is showing, so
/// `sheet(item:)` has an `Identifiable` to key on.
enum PendingMove: Identifiable {
    case entry(UUID)
    case group(UUID)

    var id: String {
        switch self {
        case .entry(let entryID):
            "entry-\(entryID.uuidString)"
        case .group(let groupID):
            "group-\(groupID.uuidString)"
        }
    }
}

extension PendingMove {
    /// Resolved when the picker is built rather than when the menu was tapped,
    /// so the destinations reflect the tree as it is now.
    @MainActor
    func destinationOptions(viewModel: DatabaseViewModel) -> [DatabaseViewModel.MoveDestinationOption] {
        switch self {
        case .entry(let entryID):
            viewModel.moveDestinationOptions(forEntryID: entryID)
        case .group(let groupID):
            viewModel.moveDestinationOptions(forGroupID: groupID)
        }
    }

    @MainActor
    func apply(destinationGroupID: UUID, viewModel: DatabaseViewModel) {
        do {
            switch self {
            case .entry(let entryID):
                try viewModel.moveEntry(entryID: entryID, toGroupID: destinationGroupID)
            case .group(let groupID):
                try viewModel.moveGroup(groupID: groupID, toGroupID: destinationGroupID)
            }
            Task {
                await viewModel.saveHandlingError()
            }
        } catch {
            viewModel.presentSaveError(error)
        }
    }
}
