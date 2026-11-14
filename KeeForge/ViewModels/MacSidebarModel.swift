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
        case .collection(.passkeys): passkeyEntries
        // The Mac sidebar selects tags and the Recycle Bin as their own rows.
        case .collection(.tags), .collection(.recycleBin): []
        case .group(let groupID): group(withID: groupID)?.entries ?? []
        case .tag(let tag): entries(withTag: tag)
        }
        return sortedEntries(entries)
    }
}

/// The identity of one sidebar row, stable across snapshots so an outline can
/// keep expansion and selection while the tree changes underneath it.
enum MacSidebarItemID: Hashable {
    case section(MacSidebarSnapshot.SectionKind)
    /// A section's explanatory line when it has no rows, never selected.
    case caption(MacSidebarSnapshot.SectionKind)
    case collection(DatabaseCollection)
    case group(UUID)
    case tag(String)

    /// `nil` for a section header or caption, which are never selected.
    var selection: MacSidebarSelection? {
        switch self {
        case .section, .caption: nil
        case .collection(let collection): .collection(collection)
        case .group(let groupID): .group(groupID)
        case .tag(let tag): .tag(tag)
        }
    }
}

/// What a sidebar cell draws as its icon; the cell resolves it to an image.
enum MacSidebarIcon: Hashable {
    case standard(Int)
    /// A custom icon's image data from `KPMeta.customIcons`, so a merge that
    /// replaces the image changes the value; the standard icon is for data that
    /// does not decode.
    case custom(Data, standardIconID: Int)
    case symbol(String)
    /// The "#" a tag row shows.
    case tag
    /// The Deleted Entries row's trash tile.
    case recycleBin
}

/// The Mac sidebar's rows, built from one session: Library, the group tree,
/// tags (or a caption while there are none), and a Recycle Bin section with a
/// Deleted Entries row for the bin's own entries and the deleted groups
/// beneath it, left out while the bin is empty or absent.
struct MacSidebarSnapshot: Equatable {
    enum SectionKind: Hashable, CaseIterable {
        case library
        case groups
        case tags
        case recycleBin
    }

    struct Section: Equatable, Identifiable {
        let kind: SectionKind
        let nodes: [Node]

        var id: MacSidebarItemID {
            .section(kind)
        }
    }

    struct Node: Equatable, Identifiable {
        let id: MacSidebarItemID
        let title: String
        let icon: MacSidebarIcon?
        let count: Int?
        let children: [Node]
        let accessibilityIdentifier: String
        /// A group inside the Recycle Bin, drawn dimmed.
        var isDeleted = false

        var selection: MacSidebarSelection? {
            id.selection
        }

        var isSelectable: Bool {
            selection != nil
        }
    }

    static let libraryCollections: [DatabaseCollection] = [.allEntries, .verificationCodes, .passkeys]

    let sections: [Section]

    func section(_ kind: SectionKind) -> Section? {
        sections.first { $0.kind == kind }
    }

    /// Every group row that has subgroups, for Expand and Collapse All Groups.
    var collapsibleGroupIDs: Set<UUID> {
        var ids: Set<UUID> = []
        func visit(_ nodes: [Node]) {
            for node in nodes {
                if case .group(let groupID) = node.id, node.children.isEmpty == false { ids.insert(groupID) }
                visit(node.children)
            }
        }
        visit(sections.flatMap(\.nodes))
        return ids
    }

    @MainActor
    static func make(session: DatabaseViewModel) -> MacSidebarSnapshot {
        guard let root = session.currentRootGroup else { return MacSidebarSnapshot(sections: []) }
        let recycleBinID = root.recycleBinUUID
        let customIcons = session.currentMeta?.customIcons ?? [:]

        /// A group counts every entry in its subtree, the recycle bin's left out.
        func node(for group: KPGroup, isDeleted: Bool = false) -> Node {
            let icon: MacSidebarIcon = if let customIconID = group.customIconUUID, let data = customIcons[customIconID] {
                .custom(data, standardIconID: group.iconID)
            } else {
                .standard(group.iconID)
            }
            let children = session.sortedGroups(group.groups).filter { $0.id != recycleBinID }
                .map { node(for: $0, isDeleted: isDeleted) }
            return Node(
                id: .group(group.id),
                title: group.name,
                icon: icon,
                count: children.reduce(group.entries.count) { $0 + ($1.count ?? 0) },
                children: children,
                accessibilityIdentifier: "group.navlink",
                isDeleted: isDeleted
            )
        }

        let counts = session.collectionCounts
        var sections = [
            Section(kind: .library, nodes: libraryCollections.map { collection in
                Node(
                    id: .collection(collection),
                    title: collection.title,
                    icon: .symbol(collection.systemImage),
                    count: counts[collection],
                    children: [],
                    accessibilityIdentifier: "sidebar.collection.\(collection.rawValue)"
                )
            }),
        ]

        let groupsRootID = session.workspaceRootGroupID
        let groupsRoot = groupsRootID == root.id ? root : groupsRootID.flatMap(session.group(withID:))
        sections.append(Section(kind: .groups, nodes: groupsRoot.map { [node(for: $0)] } ?? []))

        let tags = session.tagsInDisplayOrder
        let tagNodes = tags.enumerated().map { index, tag in
            Node(
                id: .tag(tag),
                title: tag,
                icon: .tag,
                count: session.entryCount(forTag: tag),
                children: [],
                accessibilityIdentifier:
                    "tag-list.row.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))"
            )
        }
        sections.append(Section(kind: .tags, nodes: tagNodes.isEmpty ? [
            Node(
                id: .caption(.tags),
                title: String(localized: "No tags yet. Tags you add to entries appear here."),
                icon: nil,
                count: nil,
                children: [],
                accessibilityIdentifier: "sidebar.tags.empty"
            ),
        ] : tagNodes))

        // The bin's group row lists its own entries, as Deleted Entries.
        if let recycleBin = session.recycleBinGroup, recycleBin.entries.isEmpty == false || recycleBin.groups.isEmpty == false {
            let deletedEntries = Node(
                id: .group(recycleBin.id),
                title: String(localized: "Deleted Entries"),
                icon: .recycleBin,
                count: recycleBin.entries.count,
                children: [],
                accessibilityIdentifier: "group.navlink"
            )
            let deletedGroups = session.sortedGroups(recycleBin.groups).map { node(for: $0, isDeleted: true) }
            sections.append(Section(kind: .recycleBin, nodes: [deletedEntries] + deletedGroups))
        }
        return MacSidebarSnapshot(sections: sections)
    }
}

/// Which context-menu actions a sidebar group row offers, and the identifiers
/// UI tests find them by.
struct MacSidebarGroupActions: Equatable {
    static let newSubgroupIdentifier = "group-row.new-subgroup"
    static let editIdentifier = "group-row.edit-context"
    static let restoreIdentifier = "group-row.restore-context"
    static let moveIdentifier = "group-row.move-context"
    static let deleteIdentifier = "group-row.delete-context"
    static let deletePermanentlyIdentifier = "group-row.delete-permanent"

    let canAddSubgroup: Bool
    let canEdit: Bool
    let canRestore: Bool
    let canMove: Bool
    let canDelete: Bool
    /// Inside the Recycle Bin a delete cannot be undone.
    let deletesPermanently: Bool

    @MainActor
    init(groupID: UUID, session: DatabaseViewModel) {
        guard session.isSaving == false, session.isReadOnly == false, session.group(withID: groupID) != nil else {
            self.init(canAddSubgroup: false, canEdit: false, canRestore: false, canMove: false, canDelete: false,
                      deletesPermanently: false)
            return
        }
        let isInRecycleBin = session.isGroupInRecycleBin(groupID: groupID)
        let isProtected = session.isGroupProtectedFromDeletion(groupID: groupID)
        // The Recycle Bin and everything inside it stay non-editable.
        let isEditable = session.currentRootGroup?.recycleBinUUID != groupID && isInRecycleBin == false
        self.init(
            canAddSubgroup: isEditable,
            canEdit: isEditable && session.isSyntheticRootGroup(groupID: groupID) == false,
            canRestore: session.canRestore(.group(groupID)),
            canMove: isEditable && isProtected == false,
            canDelete: isProtected == false,
            deletesPermanently: isInRecycleBin
        )
    }

    private init(
        canAddSubgroup: Bool, canEdit: Bool, canRestore: Bool, canMove: Bool, canDelete: Bool, deletesPermanently: Bool
    ) {
        self.canAddSubgroup = canAddSubgroup
        self.canEdit = canEdit
        self.canRestore = canRestore
        self.canMove = canMove
        self.canDelete = canDelete
        self.deletesPermanently = deletesPermanently
    }

    var deleteTitle: String {
        deletesPermanently ? String(localized: "Delete Permanently") : String(localized: "Delete")
    }

    var deleteAccessibilityIdentifier: String {
        deletesPermanently ? Self.deletePermanentlyIdentifier : Self.deleteIdentifier
    }

    var offersAnyAction: Bool {
        canAddSubgroup || canEdit || canRestore || canMove || canDelete
    }
}

/// Dragging list entries onto a sidebar group: what the drag pasteboard
/// carries, and whether a drop moves the entries. A drop is a Move to Group…
/// through `PendingMove`, save included; the Recycle Bin is no destination.
@MainActor
struct MacEntryDrop {
    /// Private, so other apps find nothing they read; each item is one entry.
    static let pasteboardType = "com.keeforge.mac.entry-drag"

    let session: DatabaseViewModel
    /// The window presentation's lifetime, which a lock renews.
    let windowID: UUID
    private let isFrozen: Bool

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation) {
        self.session = session
        windowID = presentation.lifetimeID
        isFrozen = presentation.freezesWorkspace(session)
    }

    private var isWritable: Bool {
        session.state == .unlocked && isFrozen == false && session.isReadOnly == false
    }

    private func isMovable(_ entryID: UUID) -> Bool {
        session.entry(withID: entryID) != nil && EntryRowActions(entryID: entryID, session: session).canMove
    }

    /// Nil for an entry that cannot move, so its row starts no drag.
    func pasteboardData(forEntryID entryID: UUID) -> Data? {
        guard isWritable, isMovable(entryID) else { return nil }
        return Self.bytes(session.databaseReference.id) + Self.bytes(windowID) + Self.bytes(entryID)
    }

    /// A UUID's 16 raw bytes; an item is the database, window and entry IDs back to back.
    private static func bytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    /// Nil when any item is unreadable or comes from another window or database.
    func entryIDs(from items: [Data]) -> Set<UUID>? {
        guard items.isEmpty == false else { return nil }
        let source = Self.bytes(session.databaseReference.id) + Self.bytes(windowID)
        var entryIDs: Set<UUID> = []
        for data in items {
            guard data.count == source.count + 16, data.prefix(source.count) == source else { return nil }
            let entry = Data(data.suffix(16))
            entryIDs.insert(entry.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) })
        }
        return entryIDs
    }

    /// Move to Group…'s gates: a writable database, movable entries, a group the
    /// picker offers, and at least one entry not already there.
    func canDrop(_ entryIDs: Set<UUID>, onto target: MacSidebarItemID) -> Bool {
        guard isWritable, case .group(let groupID) = target, entryIDs.isEmpty == false,
              entryIDs.allSatisfy(isMovable),
              session.moveDestinationOptions(forEntryIDs: entryIDs).contains(where: { $0.id == groupID }) else {
            return false
        }
        return entryIDs.contains { session.parentGroupID(forEntryID: $0) != groupID }
    }

    @discardableResult
    func drop(_ entryIDs: Set<UUID>, onto target: MacSidebarItemID) -> Bool {
        guard canDrop(entryIDs, onto: target), case .group(let groupID) = target else { return false }
        let move: PendingMove = if entryIDs.count == 1, let entryID = entryIDs.first {
            .entry(entryID)
        } else {
            .entries(entryIDs)
        }
        move.apply(destinationGroupID: groupID, viewModel: session)
        return true
    }
}
#endif
