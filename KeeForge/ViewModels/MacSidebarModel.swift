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

/// The identity of one sidebar row, stable across snapshots so an outline can
/// keep expansion and selection while the tree changes underneath it.
enum MacSidebarItemID: Hashable {
    case section(MacSidebarSnapshot.SectionKind)
    case collection(DatabaseCollection)
    case group(UUID)
    case tag(String)

    /// `nil` for a section header, which is never selected.
    var selection: MacSidebarSelection? {
        switch self {
        case .section: nil
        case .collection(let collection): .collection(collection)
        case .group(let groupID): .group(groupID)
        case .tag(let tag): .tag(tag)
        }
    }
}

/// What a sidebar cell draws as its icon; the cell resolves it to an image.
enum MacSidebarIcon: Hashable {
    case standard(Int)
    /// A custom icon from `KPMeta.customIcons`, with the stored standard icon
    /// for when its image data does not decode.
    case custom(UUID, standardIconID: Int)
    case symbol(String)
}

/// The Mac sidebar's rows, built from one session: Library, the group tree,
/// tags, and the Recycle Bin as a top-level row with its subtree.
struct MacSidebarSnapshot: Equatable {
    enum SectionKind: Hashable, CaseIterable {
        case library
        case groups
        case tags
        case recycleBin

        var showsHeader: Bool {
            self != .recycleBin
        }
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
        let icon: MacSidebarIcon
        let count: Int?
        let children: [Node]
        let accessibilityIdentifier: String

        var selection: MacSidebarSelection? {
            id.selection
        }

        var isSelectable: Bool {
            selection != nil
        }
    }

    static let libraryCollections: [DatabaseCollection] = [.allEntries, .verificationCodes]

    let sections: [Section]

    func section(_ kind: SectionKind) -> Section? {
        sections.first { $0.kind == kind }
    }

    @MainActor
    static func make(session: DatabaseViewModel) -> MacSidebarSnapshot {
        guard let root = session.currentRootGroup else { return MacSidebarSnapshot(sections: []) }
        let recycleBinID = root.recycleBinUUID
        let customIcons = session.currentMeta?.customIcons ?? [:]

        func node(for group: KPGroup) -> Node {
            let isRecycleBin = group.id == recycleBinID
            let icon: MacSidebarIcon = if isRecycleBin {
                .standard(43)
            } else if let customIconID = group.customIconUUID, customIcons[customIconID] != nil {
                .custom(customIconID, standardIconID: group.iconID)
            } else {
                .standard(group.iconID)
            }
            return Node(
                id: .group(group.id),
                title: group.name,
                icon: icon,
                count: nil,
                children: session.sortedGroups(group.groups).filter { $0.id != recycleBinID }.map(node(for:)),
                accessibilityIdentifier: "group.navlink"
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
        if tags.isEmpty == false {
            sections.append(Section(kind: .tags, nodes: tags.enumerated().map { index, tag in
                Node(
                    id: .tag(tag),
                    title: tag,
                    icon: .symbol("tag"),
                    count: session.entryCount(forTag: tag),
                    children: [],
                    accessibilityIdentifier:
                        "tag-list.row.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))"
                )
            }))
        }

        if let recycleBin = session.recycleBinGroup {
            sections.append(Section(kind: .recycleBin, nodes: [node(for: recycleBin)]))
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
            canEdit: isEditable,
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

/// The sidebar status card for one session: `nil` while there is nothing to
/// report, as for a clean, writable database that is local or in sync.
struct MacDatabaseStatus: Equatable {
    enum Kind: String, Hashable {
        case saving
        case unsavedChanges
        case uploadConflict
        case cloudSyncing
        case cloudSyncWarning
        case pendingUpload
        case readOnly
    }

    enum Tone: Hashable {
        case neutral
        case warning
    }

    struct Line: Equatable, Identifiable {
        let kind: Kind
        let text: String

        var id: Kind {
            kind
        }

        var tone: Tone {
            switch kind {
            case .saving, .cloudSyncing, .pendingUpload: .neutral
            case .unsavedChanges, .uploadConflict, .cloudSyncWarning, .readOnly: .warning
            }
        }

        var systemImage: String {
            switch kind {
            case .saving: "square.and.arrow.down"
            case .unsavedChanges: "exclamationmark.circle.fill"
            case .uploadConflict, .cloudSyncWarning: "exclamationmark.triangle.fill"
            case .cloudSyncing: "arrow.triangle.2.circlepath"
            case .pendingUpload: "icloud.and.arrow.up"
            case .readOnly: "eyeglasses"
            }
        }
    }

    /// The session facts the card reads, already reduced by the rules the
    /// toolbar and banners use.
    struct State: Equatable {
        enum CloudSync: Equatable {
            case syncing(String)
            case warning(String)
        }

        var isSaving = false
        var isDirty = false
        var isReadOnly = false
        var hasPendingUploadConflict = false
        var cloudSync: CloudSync?
        var showsPendingUploadNote = false

        @MainActor
        init(session: DatabaseViewModel) {
            isSaving = session.isSaving
            isDirty = session.isDirty
            isReadOnly = session.isReadOnly
            hasPendingUploadConflict = session.hasPendingUploadConflict
            if CloudSyncControls.isVisible(for: session) {
                if session.isSyncingCloud {
                    cloudSync = .syncing(CloudSyncControls.title(for: session))
                } else if CloudSyncControls.showsWarning(for: session) {
                    cloudSync = .warning(CloudSyncControls.title(for: session))
                }
                showsPendingUploadNote = CloudSyncControls.showsPendingUploadNote(for: session)
            }
        }

        init() {}
    }

    let lines: [Line]

    init?(_ state: State) {
        var lines: [Line] = []
        if state.isSaving {
            lines.append(Line(kind: .saving, text: String(localized: "Saving…")))
        } else {
            // The banners' rule: a save in flight speaks for the draft and the upload.
            if state.isDirty {
                lines.append(Line(kind: .unsavedChanges, text: String(localized: "Changes not saved")))
            }
            if state.hasPendingUploadConflict {
                lines.append(Line(kind: .uploadConflict, text: String(
                    localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
                )))
            }
        }
        switch state.cloudSync {
        case .syncing(let text): lines.append(Line(kind: .cloudSyncing, text: text))
        case .warning(let text): lines.append(Line(kind: .cloudSyncWarning, text: text))
        case nil: break
        }
        if state.showsPendingUploadNote {
            lines.append(Line(
                kind: .pendingUpload,
                text: String(localized: "Changes saved through AutoFill are still waiting to upload.")
            ))
        }
        if state.isReadOnly {
            lines.append(Line(kind: .readOnly, text: String(localized: "Read-only database")))
        }
        guard lines.isEmpty == false else { return nil }
        self.lines = lines
    }

    @MainActor
    static func make(session: DatabaseViewModel) -> MacDatabaseStatus? {
        MacDatabaseStatus(State(session: session))
    }
}
#endif
