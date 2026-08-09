import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct RegularDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    /// The iPad sidebar's browsing stack. Type-erased rather than `[UUID]`
    /// because it now carries both group pushes (`UUID`) and tag-browser
    /// pushes (`TagDestination`), the same pair the compact shell's path holds.
    @State private var navigationPath = NavigationPath()
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isCloudReconnectInFlight = false
    #if os(macOS)
    /// Editor presented by the menu-bar New Entry command (⌘N) and the toolbar
    /// add button — a single shared sheet so presentation stays reliable.
    @State private var commandEditor: EntryEditViewModel?
    @State private var isShowingNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var groupCreationErrorMessage: String?
    @State private var macCollapsedGroupIDs: Set<UUID> = []
    /// Group editor presented from a sidebar row's context menu. Hosted on the
    /// split view rather than the row, so collapsing or rebuilding the tree
    /// cannot tear the sheet down mid-edit.
    @State private var groupEditor: GroupEditViewModel?
    @FocusState private var isSearchFieldFocused: Bool
    #endif

    var body: some View {
        decoratedSplitView
            .onChange(of: viewModel.saveError) { _, newValue in
                if let newValue {
                    presentedSaveError = newValue
                }
            }
            .onChange(of: viewModel.visibleRootGroupID) { _, _ in
                // Lock, close, and database switch all land here (the visible
                // root goes nil), clearing pushed group *and* tag destinations.
                navigationPath = NavigationPath()
                viewModel.selectEntry(nil)
            }
            .onChange(of: navigationPath) { _, _ in
                viewModel.selectEntry(nil)
            }
            .onChange(of: viewModel.searchText) { oldValue, newValue in
                guard oldValue != newValue else { return }
                viewModel.selectEntry(nil)
            }
            .modifier(NewEntryCommandHandling(view: self))
            .alert(item: $presentedSaveError) { error in
                Alert(
                    title: Text("Couldn't Save Database"),
                    message: Text(error.localizedDescription),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(
                "Lock and discard unsaved changes?",
                isPresented: Binding(
                    get: { viewModel.pendingLockRequest != nil },
                    set: { _ in }
                )
            ) {
                Button("Lock and Discard", role: .destructive) {
                    let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                    viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
                }
                Button("Keep Editing", role: .cancel) {
                    Task {
                        await viewModel.continueEditingAfterLockRequest()
                    }
                }
            } message: {
                Text("Your unsaved entry changes will be lost.")
            }
    }

    private var decoratedSplitView: some View {
        splitView
            .navigationSplitViewStyle(.balanced)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("regular-workspace.root")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if viewModel.saveError?.isWriteScopeRequired == true {
                        CloudReauthBanner(
                            providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                            isReconnectInFlight: isCloudReconnectInFlight,
                            onReconnect: beginCloudReconnect
                        )
                    }

                    if viewModel.isDirty && viewModel.isSaving == false {
                        UnsavedChangesBanner(viewModel: viewModel)
                    }
                }
            }
            .disabled(viewModel.isSaving)
            .overlay {
                if viewModel.isSaving {
                    DatabaseSavingOverlay()
                }
            }
            .saveConflictAlert(viewModel: viewModel)
    }

    @ViewBuilder
    private var splitView: some View {
        #if os(macOS)
        macSplitView
        #else
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            detailColumn
        }
        #endif
    }

    private var detailColumn: some View {
        NavigationStack {
            if let selectedEntryID = viewModel.selectedEntryID {
                EntryDetailView(
                    entryID: selectedEntryID,
                    viewModel: viewModel,
                    onClose: {
                        viewModel.selectEntry(nil)
                    },
                    onSelectTag: selectTag,
                    popsOnClose: false
                )
            } else if viewModel.searchText.isEmpty {
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

    /// macOS: reacts to the menu-bar New Entry command and hosts the editor
    /// sheet it presents; no-op modifier on iOS.
    private struct NewEntryCommandHandling: ViewModifier {
        let view: RegularDatabaseWorkspaceView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .onChange(of: view.viewModel.newEntryRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginNewEntryFromCommand()
                }
                .sheet(item: view.$commandEditor) { formViewModel in
                    NavigationStack {
                        EntryEditView(
                            formViewModel: formViewModel,
                            databaseViewModel: view.viewModel
                        ) { _ in
                            view.commandEditor = nil
                        }
                    }
                    .frame(minWidth: 540, minHeight: 560)
                }
            #else
            content
            #endif
        }
    }

    #if os(iOS)
    /// iOS/iPadOS sidebar group navigation: a `NavigationStack` pushing
    /// `GroupListView` levels (unchanged legacy behavior). macOS uses the
    /// dedicated three-column `macSplitView` instead.
    @ViewBuilder
    private var sidebarColumn: some View {
        NavigationStack(path: $navigationPath) {
            if let rootID = viewModel.visibleRootGroupID {
                GroupListView(
                    groupID: rootID,
                    viewModel: viewModel,
                    onSelectEntry: selectEntry
                )
                .navigationDestination(for: UUID.self) { groupID in
                    GroupListView(
                        groupID: groupID,
                        viewModel: viewModel,
                        onSelectEntry: selectEntry
                    )
                }
                .navigationDestination(for: TagDestination.self) { destination in
                    switch destination {
                    case .allTags:
                        TagListView(viewModel: viewModel)
                    case .entries(let tag):
                        // Entries are selected, not pushed, in this shell.
                        TagEntriesView(
                            tag: tag,
                            viewModel: viewModel,
                            onSelectEntry: selectEntry
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Vault Not Loaded",
                    systemImage: "lock.doc",
                    description: Text("Unlock a database to browse groups and entries.")
                )
            }
        }
    }
    #endif

    private func selectEntry(_ entry: KPEntry) {
        viewModel.selectEntry(entry.id)
    }

    /// Routes an entry-detail tag chip. The detail column has no browsing stack
    /// of its own in either shell, so instead of pushing inside it, each shell
    /// navigates the surface that owns browsing: the iPad sidebar's stack (the
    /// same place the root Tags row leads), and the macOS sidebar's selection.
    private func selectTag(_ tag: String) {
        #if os(macOS)
        viewModel.selectedTag = tag
        #else
        navigationPath.append(TagDestination.entries(tag: tag))
        #endif
    }

    #if os(macOS)
    // MARK: - macOS three-column workspace

    /// Canonical Mac password-manager layout: a three-column
    /// `NavigationSplitView` (group tree / entries / entry detail). Group and
    /// entry rows stay plain buttons carrying `group.navlink` / `entry.navlink`
    /// so the existing selection-by-identifier smoke helpers keep working, with
    /// a manual sidebar-style highlight standing in for native list selection.
    private var macSplitView: some View {
        NavigationSplitView {
            macSidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } content: {
            macContentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            detailColumn
        }
        .navigationTitle(viewModel.databaseDisplayName)
        .searchable(text: $viewModel.searchText, prompt: "Search entries")
        .macSearchFocusedCompat($isSearchFieldFocused)
        .onChange(of: viewModel.searchFocusRequestID) { _, _ in
            isSearchFieldFocused = true
        }
        .toolbar { macToolbar }
        .onAppear {
            // The tag check keeps a re-fired onAppear from silently clearing a
            // sidebar tag selection — selecting a group deselects the tag.
            if viewModel.selectedGroupID == nil, viewModel.selectedTag == nil {
                viewModel.selectedGroupID = viewModel.visibleRootGroupID
            }
        }
        .sheet(isPresented: $isShowingNewGroupSheet) {
            NewGroupSheet(
                name: $newGroupName,
                errorMessage: $groupCreationErrorMessage,
                onCancel: {
                    newGroupName = ""
                    groupCreationErrorMessage = nil
                    isShowingNewGroupSheet = false
                },
                onCreate: { name in
                    guard let parentID = viewModel.selectedGroupID ?? viewModel.visibleRootGroupID else { return }
                    do {
                        try viewModel.createGroup(named: name, in: parentID)
                        newGroupName = ""
                        groupCreationErrorMessage = nil
                        isShowingNewGroupSheet = false
                        Task { await viewModel.saveHandlingError() }
                    } catch {
                        groupCreationErrorMessage = error.localizedDescription
                    }
                }
            )
        }
        .sheet(item: $groupEditor) { formViewModel in
            NavigationStack {
                GroupEditView(
                    formViewModel: formViewModel,
                    databaseViewModel: viewModel
                ) {
                    groupEditor = nil
                }
            }
            .frame(minWidth: 540, minHeight: 520)
        }
    }

    /// Builds the sidebar row's editor when the menu item is tapped, so the form
    /// opens on the group's state at that moment.
    @MainActor
    private func beginGroupEdit(_ groupID: UUID) {
        guard let group = viewModel.group(withID: groupID) else { return }
        groupEditor = GroupEditViewModel(
            editing: group,
            isHiddenFromAutoFill: viewModel.isGroupExcludedFromAutoFill(groupID: groupID),
            isExclusionInherited: viewModel.isGroupExclusionInherited(groupID: groupID),
            knownTags: viewModel.tagsInDisplayOrder
        )
    }

    // MARK: Sidebar (group tree)

    private func macGroupNode(for groupID: UUID) -> MacGroupNode? {
        guard let group = viewModel.group(withID: groupID) else { return nil }
        let childNodes = viewModel.sortedGroups(group.groups).compactMap { macGroupNode(for: $0.id) }
        let isRecycleBin = viewModel.currentRootGroup?.recycleBinUUID == groupID
        return MacGroupNode(
            id: groupID,
            name: group.name,
            icon: isRecycleBin ? "trash" : group.systemIconName,
            children: childNodes.isEmpty ? nil : childNodes
        )
    }

    @ViewBuilder
    private var macSidebarColumn: some View {
        if let rootID = viewModel.visibleRootGroupID, let rootNode = macGroupNode(for: rootID) {
            List {
                MacGroupTreeRow(
                    node: rootNode,
                    viewModel: viewModel,
                    collapsedGroupIDs: $macCollapsedGroupIDs,
                    onEditGroup: beginGroupEdit
                )

                // Tags beneath the group tree, the way KeePassXC surfaces them.
                // Hidden at zero: unlike the iOS row, this section *is* the
                // list, so an empty one would teach nothing.
                let tags = viewModel.tagsInDisplayOrder
                if tags.isEmpty == false {
                    Section("Tags") {
                        ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                            MacTagRow(tag: tag, fallbackIndex: index, viewModel: viewModel)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Rebuild the tree when the draft changes (group create/delete/
            // rename). Like the content column, the split view can otherwise
            // keep a stale sidebar; `macCollapsedGroupIDs` and the selection are
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

    // MARK: Content (entries)

    @ViewBuilder
    private var macContentColumn: some View {
        // Search wins over a sidebar tag selection: the search field is always-on
        // chrome on macOS, so typing must show results immediately. Clearing the
        // query returns to whatever the sidebar still has selected.
        if viewModel.searchText.isEmpty {
            // The `content:` column of a three-column `NavigationSplitView`
            // caches its subtree on macOS and doesn't re-evaluate on the view
            // model's observation changes (the detail column does), so an
            // edited entry keeps a stale row label without this id. Reading
            // `contentRevision` here also re-runs the body so the id updates.
            if let selectedTag = viewModel.selectedTag {
                TagEntriesView(tag: selectedTag, viewModel: viewModel, onSelectEntry: selectEntry)
                    .id(viewModel.contentRevision)
            } else {
                MacEntriesColumn(viewModel: viewModel, onSelectEntry: selectEntry)
                    .id(viewModel.contentRevision)
            }
        } else {
            SearchView(viewModel: viewModel, onSelectEntry: selectEntry)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            LockDatabaseButton {
                viewModel.lockRequest(manuallyTriggered: true)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let warningText = viewModel.cloudSyncBannerText {
                CloudSyncWarningButton(message: warningText)
            }

            if viewModel.isReadOnly {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .help("Read-only database")
                    .accessibilityIdentifier("database.read-only-indicator")
            } else {
                Menu {
                    Button("New Entry", systemImage: "doc.badge.plus") {
                        viewModel.requestNewEntry()
                    }
                    Button("New Group", systemImage: "folder.badge.plus") {
                        beginNewGroup()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .help("Add Entry or Group")
                .accessibilityIdentifier("entry-list.add-entry")
            }

            Menu {
                Picker("Sort By", selection: $viewModel.sortOrder) {
                    ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                Picker("Sort Direction", selection: $viewModel.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .help("Sort")
            .accessibilityIdentifier("sort.menu")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityIdentifier("settings.button")
        }
    }

    private func beginNewGroup() {
        newGroupName = ""
        groupCreationErrorMessage = nil
        isShowingNewGroupSheet = true
    }

    #endif

    #if os(macOS)
    @MainActor
    private func beginNewEntryFromCommand() {
        guard commandEditor == nil else { return }
        // Target the group the user is looking at (selected in the sidebar),
        // falling back to the visible root. When there is no writable target we
        // do nothing — ⌘N is also disabled in that state in KeeForgeCommands —
        // rather than presenting an editor with no destination group.
        guard let targetGroupID = viewModel.selectedGroupID ?? viewModel.visibleRootGroupID else { return }

        commandEditor = EntryEditViewModel(
            createIn: targetGroupID,
            knownTags: viewModel.tagsInDisplayOrder,
            inheritedTags: viewModel.inheritedTags(forGroupID: targetGroupID)
        )
    }
    #endif

    @MainActor
    private func beginCloudReconnect() {
        guard isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isCloudReconnectInFlight = true
        Task { @MainActor in
            defer { isCloudReconnectInFlight = false }

            do {
                _ = try await provider.authenticate(from: presentationAnchor())
                viewModel.clearSaveError()
            } catch let error as CloudProviderError where error == .authenticationCancelled {
                return
            } catch {
                viewModel.presentSaveError(error)
            }
        }
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
        #else
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #endif
    }
}

#if os(macOS)
/// The macOS content column: the selected group's entries, each a plain button
/// carrying `entry.navlink` with a manual selection highlight. A dedicated
/// `@Bindable` observing view (not an inline `@ViewBuilder` on the workspace) so
/// it re-renders on `DatabaseViewModel.contentRevision` changes — e.g. after an
/// edit renames an entry, which an inline computed property missed.
private struct MacEntriesColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    let onSelectEntry: (KPEntry) -> Void

    private var resolvedGroup: KPGroup? {
        guard let groupID = viewModel.selectedGroupID ?? viewModel.visibleRootGroupID else { return nil }
        return viewModel.group(withID: groupID)
    }

    var body: some View {
        if let group = resolvedGroup {
            let entries = viewModel.sortedEntries(group.entries)
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "tray",
                        description: Text("This group has no entries.")
                    )
                } else {
                    List {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationSubtitle(group.name)
        } else {
            ContentUnavailableView(
                "Select a Group",
                systemImage: "folder",
                description: Text("Choose a group to view its entries.")
            )
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: KPEntry) -> some View {
        let isSelected = viewModel.selectedEntryID == entry.id
        Button {
            onSelectEntry(entry)
        } label: {
            EntryRow(entry: entry, customIconData: viewModel.customIconData(for: entry))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .accessibilityIdentifier("entry.navlink")
        .contextMenu {
            if viewModel.isReadOnly == false {
                Button("Delete", role: .destructive) {
                    do {
                        try viewModel.deleteEntry(
                            entry.id,
                            sendToRecycleBin: viewModel.isEntryInRecycleBin(entryID: entry.id) == false
                        )
                        Task { await viewModel.saveHandlingError() }
                    } catch {
                        viewModel.presentSaveError(error)
                    }
                }
            }
        }
    }
}

/// A macOS sidebar tag row: the tag name with its live-entry count, carrying
/// the same manual selection highlight the group rows use (native list
/// selection is not used anywhere in this sidebar). Selecting one clears the
/// group selection through `DatabaseViewModel`, so exactly one row highlights.
private struct MacTagRow: View {
    let tag: String
    let fallbackIndex: Int
    @Bindable var viewModel: DatabaseViewModel

    private var isSelected: Bool {
        viewModel.selectedTag == tag
    }

    var body: some View {
        Button {
            viewModel.selectedTag = tag
        } label: {
            Label {
                HStack {
                    Text(tag)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(viewModel.entryCount(forTag: tag).formatted())
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
            } icon: {
                Image(systemName: "tag")
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
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
    let icon: String
    let children: [MacGroupNode]?
}

/// Recursive sidebar row. Concrete (not an opaque `some View` helper) so it can
/// reference itself for nested groups. Parent groups render as a
/// `DisclosureGroup` defaulting to expanded; the row itself is a plain button
/// carrying `group.navlink` with a manual sidebar-style selection highlight.
private struct MacGroupTreeRow: View {
    let node: MacGroupNode
    @Bindable var viewModel: DatabaseViewModel
    @Binding var collapsedGroupIDs: Set<UUID>
    /// Asks the workspace to present the group editor; the sheet is hosted
    /// there, not on this row, which comes and goes with the tree.
    let onEditGroup: (UUID) -> Void

    private var isSelected: Bool {
        viewModel.selectedGroupID == node.id
    }

    var body: some View {
        if let children = node.children {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { collapsedGroupIDs.contains(node.id) == false },
                    set: { isExpanded in
                        if isExpanded {
                            collapsedGroupIDs.remove(node.id)
                        } else {
                            collapsedGroupIDs.insert(node.id)
                        }
                    }
                )
            ) {
                ForEach(children) { child in
                    MacGroupTreeRow(
                        node: child,
                        viewModel: viewModel,
                        collapsedGroupIDs: $collapsedGroupIDs,
                        onEditGroup: onEditGroup
                    )
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        Button {
            viewModel.selectedGroupID = node.id
        } label: {
            Label {
                Text(node.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: node.icon)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        )
        .accessibilityIdentifier("group.navlink")
        .contextMenu {
            if canEdit {
                Button("Edit Group") {
                    onEditGroup(node.id)
                }
                .accessibilityIdentifier("group-row.edit-context")
            }

            if canDelete {
                Button(deleteTitle, role: .destructive) {
                    deleteGroup()
                }
            }
        }
    }

    /// Same predicate as the iOS row's `canEditGroup`: the Recycle Bin and
    /// everything inside it stay non-editable, as does a read-only database.
    private var canEdit: Bool {
        viewModel.isReadOnly == false
            && viewModel.currentRootGroup?.recycleBinUUID != node.id
            && viewModel.isGroupInRecycleBin(groupID: node.id) == false
    }

    private var canDelete: Bool {
        viewModel.isReadOnly == false && viewModel.isGroupProtectedFromDeletion(groupID: node.id) == false
    }

    private var deleteTitle: String {
        viewModel.isGroupInRecycleBin(groupID: node.id) ? "Delete Permanently" : "Delete"
    }

    private func deleteGroup() {
        let sendToRecycleBin = viewModel.isGroupInRecycleBin(groupID: node.id) == false
        do {
            try viewModel.deleteGroup(node.id, sendToRecycleBin: sendToRecycleBin)
            Task { await viewModel.saveHandlingError() }
        } catch {
            viewModel.presentSaveError(error)
        }
    }
}
#endif
