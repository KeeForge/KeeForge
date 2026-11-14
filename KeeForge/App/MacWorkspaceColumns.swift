#if os(macOS)
import SwiftUI

struct MacWorkspaceSidebarColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation
    @FocusState private var isMacSidebarFocused: Bool

    private func macGroupNode(for groupID: UUID) -> MacGroupNode? {
        guard let group = viewModel.group(withID: groupID) else { return nil }
        let childNodes = viewModel.sortedGroups(group.groups).compactMap { macGroupNode(for: $0.id) }
        return MacGroupNode(
            group: group,
            recycleBinUUID: viewModel.currentRootGroup?.recycleBinUUID,
            customIcons: viewModel.currentMeta?.customIcons ?? [:],
            children: childNodes.isEmpty ? nil : childNodes
        )
    }

    /// A `nil` write is ignored: clicking the list's empty area must not
    /// leave the workspace with nothing selected and an empty content column.
    private var macSidebarSelection: Binding<MacSidebarSelection?> {
        Binding(
            get: { MacSidebarSelection(workspace: viewModel.workspace) },
            set: { newValue in
                guard let newValue else { return }
                newValue.apply(to: viewModel.workspace)
                // An accessibility click can change the selection without making
                // the list first responder, so each write takes focus as well.
                isMacSidebarFocused = true
            }
        )
    }

    @ViewBuilder
    var body: some View {
        if let rootID = viewModel.visibleRootGroupID, let rootNode = macGroupNode(for: rootID) {
            List(selection: macSidebarSelection) {
                MacGroupTreeRow(
                    node: rootNode,
                    viewModel: viewModel,
                    collapsedGroupIDs: $presentation.collapsedGroupIDs,
                    onEditGroup: { presentation.beginGroupEdit(groupID: $0, in: viewModel) },
                    onRequestMove: { presentation.pendingMove = $0 },
                    onRequestDeletion: { presentation.pendingDeletion = $0 },
                    onRequestNewSubgroup: { presentation.beginNewGroup(parentID: $0) }
                )

                // Tags beneath the group tree, the way KeePassXC surfaces them.
                // Hidden at zero: unlike the iOS row, this section *is* the
                // list, so an empty one would teach nothing.
                let tags = viewModel.tagsInDisplayOrder
                if tags.isEmpty == false {
                    Section("Tags") {
                        ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                            MacTagRow(tag: tag, fallbackIndex: index, viewModel: viewModel)
                                .tag(MacSidebarSelection.tag(tag))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focused($isMacSidebarFocused)
            // Rebuild the tree when the draft changes (group create/delete/
            // rename). Like the content column, the split view can otherwise
            // keep a stale sidebar; `presentation.collapsedGroupIDs` and the selection are
            // external state, so a rebuild preserves expansion and selection.
            .id(viewModel.contentRevision)
        } else {
            ContentUnavailableView(
                "Vault Not Loaded",
                systemImage: "lock.doc",
                description: Text("Unlock a database to browse groups and entries.")
            )
        }
    }

}

struct MacWorkspaceEntriesColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        entries.entrySelectionBar(viewModel: viewModel) { presentation.pendingMove = $0 }
    }

    @ViewBuilder
    private var entries: some View {
        // Search wins over a sidebar tag selection: the search field is always-on
        // chrome on macOS, so typing must show results immediately. Clearing the
        // query returns to whatever the sidebar still has selected.
        if viewModel.searchText.isEmpty {
            // The `content:` column of a three-column `NavigationSplitView`
            // caches its subtree on macOS and doesn't re-evaluate on the view
            // model's observation changes (the detail column does), so an
            // edited entry keeps a stale row label without this id. Reading
            // `contentRevision` here also re-runs the body so the id updates.
            if let selectedTag = viewModel.workspace.selectedTag {
                TagEntriesView(
                    tag: selectedTag,
                    viewModel: viewModel,
                    onSelectEntry: { viewModel.workspace.selectedEntryID = $0.id },
                    onRequestDeletion: { presentation.pendingDeletion = $0 }
                )
                .id(viewModel.contentRevision)
            } else {
                MacGroupEntriesList(
                    viewModel: viewModel,
                    onOpenEntry: { presentation.beginEntryEdit(entryID: $0, in: viewModel) },
                    onRequestMove: { presentation.pendingMove = $0 },
                    onRequestDuplicate: { presentation.beginEntryDuplicate($0) },
                    onRequestDeletion: { presentation.pendingDeletion = $0 }
                )
                .id(viewModel.contentRevision)
            }
        } else {
            // Rendered inline in this column, so its deletions go to the
            // workspace's own host rather than adding a colliding one.
            SearchView(
                viewModel: viewModel,
                onSelectEntry: { viewModel.workspace.selectedEntryID = $0.id },
                onRequestDeletion: { presentation.pendingDeletion = $0 }
            )
        }
    }

}

struct MacWorkspaceDetailColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Bindable var presentation: MacWorkspacePresentation

    var body: some View {
        NavigationStack {
            selectionDetail
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        Group {
            if let selectedEntryID = viewModel.workspace.selectedEntryID {
                EntryDetailView(
                    entryID: selectedEntryID,
                    viewModel: viewModel,
                    onClose: {
                        viewModel.workspace.selectedEntryID = nil
                    },
                    onSelectTag: { viewModel.workspace.selectedTag = $0 },
                    popsOnClose: false
                )
                .id(selectedEntryID)
            } else if viewModel.searchText.isEmpty || viewModel.searchResults.isEmpty {
                // With no matches the sidebar already says "No Results"; the
                // detail must not contradict it with "select a matching entry".
                ContentUnavailableView(
                    "Select an Entry",
                    systemImage: "key.horizontal",
                    description: Text("Choose an entry to view or edit its details.")
                )
                .accessibilityIdentifier("regular-workspace.select-entry-placeholder")
            } else {
                ContentUnavailableView(
                    "Search Results",
                    systemImage: "magnifyingglass",
                    description: Text("Select a matching entry to view its details.")
                )
                .accessibilityIdentifier("regular-workspace.search-results-placeholder")
            }
        }
    }

}

/// The macOS content column: the selected group's entries in a native
/// `List(selection:)` bound to `DatabaseViewModel.workspace.selectedEntryID`, so arrow
/// keys, type-select, and the focus ring come from AppKit rather than being
/// hand-rolled. A dedicated `@Bindable` observing view (not an inline
/// `@ViewBuilder` on the workspace) so it re-renders on
/// `DatabaseViewModel.contentRevision` changes — e.g. after an edit renames an
/// entry, which an inline computed property missed.
private struct MacGroupEntriesList: View {
    @Bindable var viewModel: DatabaseViewModel
    /// A click on a row with a tap handler is not relied on to make the list
    /// first responder (it does on macOS 27.0; earlier releases are
    /// unverified), so the handler hands focus over explicitly.
    @FocusState private var isListFocused: Bool
    /// Double-click and Return; the workspace hosts the editor sheet.
    let onOpenEntry: (UUID) -> Void
    /// Raised to the workspace, which hosts the picker and the confirmation;
    /// a row-scoped host dies with the row the action removes.
    let onRequestMove: (PendingMove) -> Void
    /// Raised to the workspace too, so a duplicate opens the one editor sheet
    /// ⌘N and ⌘E open rather than a second one over this column.
    let onRequestDuplicate: (EntryEditViewModel) -> Void
    let onRequestDeletion: (PendingDeletion) -> Void

    /// A selected collection, else the selected group, else the visible root.
    private var resolvedSelection: MacSidebarSelection? {
        if let collection = viewModel.workspace.selectedCollection { return .collection(collection) }
        guard let groupID = viewModel.workspace.selectedGroupID ?? viewModel.visibleRootGroupID,
              viewModel.group(withID: groupID) != nil else { return nil }
        return .group(groupID)
    }

    var body: some View {
        @Bindable var workspace = viewModel.workspace
        if let selection = resolvedSelection {
            let entries = viewModel.entries(for: selection)
            Group {
                if entries.isEmpty {
                    emptyState(for: selection)
                } else {
                    List(entries, selection: $workspace.selectedEntryID) { entry in
                        MacEntryRow(
                            entry: entry,
                            viewModel: viewModel,
                            showsFolderPath: selection.isCollection,
                            isListFocused: $isListFocused,
                            onOpenEntry: onOpenEntry,
                            onRequestMove: onRequestMove,
                            onRequestDuplicate: onRequestDuplicate,
                            onRequestDeletion: onRequestDeletion
                        )
                    }
                    .listStyle(.inset)
                    .focused($isListFocused)
                    .onKeyPress(.return) {
                        guard let entryID = viewModel.workspace.commandEntryID else { return .ignored }
                        onOpenEntry(entryID)
                        return .handled
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a Group",
                systemImage: "folder",
                description: Text("Choose a group to view its entries.")
            )
        }
    }

    @ViewBuilder
    private func emptyState(for selection: MacSidebarSelection) -> some View {
        switch selection {
        case .collection(.verificationCodes):
            ContentUnavailableView(
                "No Verification Codes",
                systemImage: DatabaseCollection.verificationCodes.systemImage,
                description: Text("Entries with a verification code appear here.")
            )
        case .collection:
            ContentUnavailableView(
                "No Entries",
                systemImage: "tray",
                description: Text("This database has no entries.")
            )
        case .group, .tag:
            ContentUnavailableView(
                "No Entries",
                systemImage: "tray",
                description: Text("This group has no entries.")
            )
        }
    }
}

private extension MacSidebarSelection {
    var isCollection: Bool {
        if case .collection = self { true } else { false }
    }
}

/// A macOS sidebar tag row: the tag name with its live-entry count. Selection
/// is the enclosing `List`'s, tagged `MacSidebarSelection.tag`; writing it
/// clears the group selection through `DatabaseViewModel`, so exactly one
/// sidebar row highlights.
private struct MacTagRow: View {
    let tag: String
    let fallbackIndex: Int
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        Label {
            HStack {
                Text(tag)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(viewModel.entryCount(forTag: tag).formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "tag")
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .macSelectableRowHover()
        .help(tag)
        // Without this the name and the count read as two separate elements.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "tag-list.row.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }
}

/// A node in the macOS sidebar group tree. Precomputed from the draft so the
/// recursive row view is a plain value tree.
struct MacGroupNode: Identifiable {
    let id: UUID
    let name: String
    let iconID: Int
    let customIconData: Data?
    let children: [MacGroupNode]?

    init(group: KPGroup, recycleBinUUID: UUID?, customIcons: [UUID: Data], children: [MacGroupNode]? = nil) {
        let isRecycleBin = group.id == recycleBinUUID
        id = group.id
        name = group.name
        iconID = isRecycleBin ? 43 : group.iconID
        customIconData = isRecycleBin ? nil : group.customIconUUID.flatMap { customIcons[$0] }
        self.children = children
    }
}

/// Recursive sidebar row. Concrete (not an opaque `some View` helper) so it can
/// reference itself for nested groups. Parent groups render as a
/// `DisclosureGroup` defaulting to expanded; every row carries `group.navlink`
/// and its `MacSidebarSelection` tag, so the enclosing `List(selection:)` draws
/// the highlight and handles arrow keys and type-select.
private struct MacGroupTreeRow: View {
    let node: MacGroupNode
    @Bindable var viewModel: DatabaseViewModel
    @Binding var collapsedGroupIDs: Set<UUID>
    /// Asks the workspace to present the group editor; the sheet is hosted
    /// there, not on this row, which comes and goes with the tree.
    let onEditGroup: (UUID) -> Void
    /// Same hand-off for the Move-to-Group picker and the delete confirmation.
    let onRequestMove: (PendingMove) -> Void
    let onRequestDeletion: (PendingDeletion) -> Void
    /// Opens the New Group sheet targeting this row's group as the parent.
    let onRequestNewSubgroup: (UUID) -> Void

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { collapsedGroupIDs.contains(node.id) == false },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroupIDs.remove(node.id)
                } else {
                    collapsedGroupIDs.insert(node.id)
                }
            }
        )
    }

    var body: some View {
        if node.children != nil {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    MacGroupTreeRow(
                        node: child,
                        viewModel: viewModel,
                        collapsedGroupIDs: $collapsedGroupIDs,
                        onEditGroup: onEditGroup,
                        onRequestMove: onRequestMove,
                        onRequestDeletion: onRequestDeletion,
                        onRequestNewSubgroup: onRequestNewSubgroup
                    )
                }
            } label: {
                // No double-click-to-toggle here on purpose: a `TapGesture` on
                // the label is not known to leave the list's selection click
                // alone on every supported macOS (it does on 27.0), and
                // selecting a group is what this row is for.
                // The disclosure triangle stays the way to fold a group.
                row
            }
            .tag(MacSidebarSelection.group(node.id))
        } else {
            row.tag(MacSidebarSelection.group(node.id))
        }
    }

    private var row: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
        } icon: {
            GroupIconView(
                iconID: node.iconID,
                customIconData: node.customIconData,
                size: 18
            )
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .macSelectableRowHover()
        .help(node.name)
        .accessibilityIdentifier("group.navlink")
        .contextMenu {
            let actions = MacSidebarGroupActions(groupID: node.id, session: viewModel)
            if actions.canAddSubgroup {
                Button("New Subgroup") {
                    onRequestNewSubgroup(node.id)
                }
                .accessibilityIdentifier(MacSidebarGroupActions.newSubgroupIdentifier)
            }

            if actions.canEdit {
                Button("Edit Group") {
                    onEditGroup(node.id)
                }
                .accessibilityIdentifier(MacSidebarGroupActions.editIdentifier)
            }

            if actions.canRestore {
                RestoreRowAction(item: .group(node.id), viewModel: viewModel, onChooseDestination: onRequestMove)
            }

            if actions.canMove {
                Button("Move to Group") {
                    onRequestMove(.group(node.id))
                }
                .accessibilityIdentifier(MacSidebarGroupActions.moveIdentifier)
            }

            if actions.canDelete {
                Button(actions.deleteTitle, role: .destructive) {
                    requestDeletion()
                }
                .accessibilityIdentifier(actions.deleteAccessibilityIdentifier)
            }
        }
    }

    private func requestDeletion() {
        guard let pending = PendingGroupDeletion(groupID: node.id, viewModel: viewModel) else { return }
        onRequestDeletion(.group(pending))
    }
}
#endif
