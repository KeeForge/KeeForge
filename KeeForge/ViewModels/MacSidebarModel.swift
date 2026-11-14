#if os(macOS)
import Foundation

/// The one value a Mac sidebar selection carries. The workspace's mutually
/// exclusive `selectedCollection`, `selectedGroupID` and `selectedTag` stay
/// the source of truth.
enum MacSidebarSelection: Hashable {
    case collection(DatabaseCollection)
    case group(UUID)
    case tag(String)

    @MainActor init?(workspace: DatabaseWorkspaceState) {
        if let collection = workspace.selectedCollection {
            self = .collection(collection)
        } else if let tag = workspace.selectedTag {
            self = .tag(tag)
        } else if let groupID = workspace.selectedGroupID {
            self = .group(groupID)
        } else {
            return nil
        }
    }

    @MainActor func apply(to workspace: DatabaseWorkspaceState) {
        switch self {
        case .collection(let collection): workspace.selectedCollection = collection
        case .group(let groupID): workspace.selectedGroupID = groupID
        case .tag(let tag): workspace.selectedTag = tag
        }
    }
}

extension DatabaseViewModel {
    /// The entries a sidebar selection lists, in display order.
    func entries(for selection: MacSidebarSelection) -> [KPEntry] {
        let entries: [KPEntry] = switch selection {
        case .collection(.allEntries): allEntries
        case .collection(.verificationCodes): verificationCodeEntries
        // The Mac sidebar selects tags and the Recycle Bin as their own rows.
        case .collection(.tags), .collection(.recycleBin): []
        case .group(let groupID): group(withID: groupID)?.entries ?? []
        case .tag(let tag): entries(withTag: tag)
        }
        return sortedEntries(entries)
    }
}
#endif
