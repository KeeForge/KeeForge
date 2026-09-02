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
    #if os(iOS)
    /// Editor opened from the sidebar (New Entry, Edit Group). Hosted in the
    /// detail column: pushed into the 320–440pt sidebar it left the wide
    /// column idle behind a "Select an Entry" placeholder.
    @State private var detailEditor: DetailEditor?
    #else
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
    /// Deletion confirmation and Move-to-Group destination raised by a sidebar
    /// or entry row. Hosted on the split view for the same reason the group
    /// editor is: rows come and go with the tree, and deleting the last entry
    /// in a column would tear a row-scoped host down mid-presentation.
    @State private var pendingDeletion: PendingDeletion?
    @State private var pendingMove: PendingMove?
    /// Parent for the next group the New Group sheet creates. Set by "New
    /// Subgroup" to target a specific row; otherwise the current selection.
    @State private var newGroupParentID: UUID?
    @State private var isShowingDatabaseDetails = false
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
                #if os(iOS)
                detailEditor = nil
                #endif
            }
            .onChange(of: navigationPath) { _, _ in
                viewModel.selectEntry(nil)
            }
            .onChange(of: viewModel.searchText) { oldValue, newValue in
                guard oldValue != newValue else { return }
                viewModel.selectEntry(nil)
            }
            .modifier(MacCommandHandling(view: self))
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
                    get: { viewModel.pendingLockRequest?.reason == .draft },
                    set: { _ in }
                )
            ) {
                if viewModel.isReadOnly == false {
                    Button("Retry Save and Lock") {
                        Task { await viewModel.saveAndLockAfterLockRequest() }
                    }
                }
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
            #if os(iOS)
            if let detailEditor {
                hostedEditor(detailEditor)
            } else {
                selectionDetail
            }
            #else
            selectionDetail
            #endif
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        Group {
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
        #if os(iOS)
        .appSettingsToolbarButton()
        #endif
    }

    #if os(iOS)
    enum DetailEditor {
        case entry(EntryEditViewModel)
        case group(GroupEditViewModel)
    }

    @ViewBuilder
    private func hostedEditor(_ editor: DetailEditor) -> some View {
        switch editor {
        case .entry(let formViewModel):
            EntryEditView(formViewModel: formViewModel, databaseViewModel: viewModel) { _ in
                detailEditor = nil
            }
        case .group(let formViewModel):
            GroupEditView(formViewModel: formViewModel, databaseViewModel: viewModel) {
                detailEditor = nil
            }
        }
    }
    #endif

    /// macOS: reacts to the menu-bar commands that need a presentation the
    /// workspace owns (New Entry, New Group, Edit Entry, Delete) and hosts the
    /// entry-editor sheet; no-op modifier on iOS.
    private struct MacCommandHandling: ViewModifier {
        let view: RegularDatabaseWorkspaceView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .onChange(of: view.viewModel.newEntryRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginNewEntryFromCommand()
                }
                .onChange(of: view.viewModel.newGroupRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginNewGroup()
                }
                .onChange(of: view.viewModel.editEntryRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginSelectedEntryEdit()
                }
                .onChange(of: view.viewModel.deleteSelectionRequestID) { oldValue, newValue in
                    guard newValue != oldValue else { return }
                    view.beginSelectionDeletion()
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
                    .macSheetFrame()
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
                    onSelectEntry: selectEntry,
                    onCreateEntry: hostEntryEditor,
                    onEditGroup: hostGroupEditor
                )
                .navigationDestination(for: UUID.self) { groupID in
                    GroupListView(
                        groupID: groupID,
                        viewModel: viewModel,
                        onSelectEntry: selectEntry,
                        onCreateEntry: hostEntryEditor,
                        onEditGroup: hostGroupEditor
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

    #if os(iOS)
    /// An editor already on screen keeps its unsaved work; the sidebar's + and
    /// row menus stay reachable while it is up, unlike the compact push.
    private func hostEntryEditor(_ editor: EntryEditViewModel) {
        guard detailEditor == nil else { return }
        detailEditor = .entry(editor)
    }

    private func hostGroupEditor(_ editor: GroupEditViewModel) {
        guard detailEditor == nil else { return }
        detailEditor = .group(editor)
    }
    #endif

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
    /// `NavigationSplitView` (group tree / entries / entry detail). All three
    /// browsing columns are native `List(selection:)`s, so arrow keys,
    /// type-select, and the focus ring come from AppKit; rows keep their
    /// `group.navlink` / `entry.navlink` identifiers, but they surface as
    /// cells rather than buttons (`KeeForgeMacUITests/README.md`).
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
        .searchFocused($isSearchFieldFocused)
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
                    newGroupParentID = nil
                    groupCreationErrorMessage = nil
                    isShowingNewGroupSheet = false
                },
                onCreate: { name in
                    guard let parentID = newGroupParentID ?? viewModel.selectedGroupID ?? viewModel.visibleRootGroupID else { return }
                    do {
                        try viewModel.createGroup(named: name, in: parentID)
                        newGroupName = ""
                        newGroupParentID = nil
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
            .macSheetFrame(minHeight: 520)
        }
        .sheet(item: $pendingMove) { pending in
            MoveToGroupPickerView(
                options: pending.destinationOptions(viewModel: viewModel)
            ) { destinationGroupID in
                pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isShowingDatabaseDetails) {
            DatabaseDetailsView(
                reference: viewModel.databaseReference,
                sessionViewModel: viewModel
            )
            .macSheetFrame()
        }
        // A `confirmationDialog`, not an `.alert(item:)`: two sibling
        // `.alert(item:)` on this view chain (this one plus `presentedSaveError`)
        // collide and SwiftUI silently drops one, so the delete confirmation
        // never presented. The dialog uses a separate presentation channel and
        // co-exists with the alerts.
        .confirmationDialog(
            pendingDeletion?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if $0 == false { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.confirmActionTitle, role: .destructive) {
                deletion.performDeletion(viewModel: viewModel)
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.confirmationMessage)
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

    /// Bridges the sidebar's single native selection onto the two mutually
    /// exclusive selections the view model already owns. A `nil` write is
    /// ignored: clicking the list's empty area must not leave the workspace
    /// with nothing selected and an empty content column.
    private var macSidebarSelection: Binding<MacSidebarSelection?> {
        Binding(
            get: {
                if let tag = viewModel.selectedTag { return .tag(tag) }
                if let groupID = viewModel.selectedGroupID { return .group(groupID) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .group(let groupID):
                    viewModel.selectedGroupID = groupID
                case .tag(let tag):
                    viewModel.selectedTag = tag
                case nil:
                    break
                }
            }
        )
    }

    @ViewBuilder
    private var macSidebarColumn: some View {
        if let rootID = viewModel.visibleRootGroupID, let rootNode = macGroupNode(for: rootID) {
            List(selection: macSidebarSelection) {
                MacGroupTreeRow(
                    node: rootNode,
                    viewModel: viewModel,
                    collapsedGroupIDs: $macCollapsedGroupIDs,
                    onEditGroup: beginGroupEdit,
                    onRequestMove: { pendingMove = $0 },
                    onRequestDeletion: { pendingDeletion = $0 },
                    onRequestNewSubgroup: beginNewSubgroup
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
                MacEntriesColumn(
                    viewModel: viewModel,
                    onOpenEntry: { beginEntryEdit(entryID: $0) },
                    onRequestMove: { pendingMove = $0 },
                    onRequestDuplicate: { beginEntryDuplicate($0) },
                    onRequestDeletion: { pendingDeletion = $0 }
                )
                .id(viewModel.contentRevision)
            }
        } else {
            SearchView(viewModel: viewModel, onSelectEntry: selectEntry)
        }
    }

    // MARK: Toolbar

    /// Database-scoped actions sit in the `.navigation` region, beside the lock
    /// button and over the group/entry columns. `.primaryAction` would park
    /// them at the trailing edge, above the entry detail — next to the detail's
    /// own Edit button, where they read as actions on the selected entry.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.lockRequest(manuallyTriggered: true)
            } label: {
                Image(systemName: "lock.fill")
            }
            .help("Lock Database")
            .accessibilityLabel("Lock Database")
            .accessibilityIdentifier("lock.button")
        }

        ToolbarItemGroup(placement: .navigation) {
            if let warningText = viewModel.cloudSyncBannerText {
                CloudSyncWarningButton(message: warningText)
            }

            if viewModel.isReadOnly {
                ReadOnlyIndicator(isFormatReadOnly: viewModel.isFormatReadOnly)
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
                .accessibilityLabel("Add Entry or Group")
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
            .accessibilityLabel("Sort")
            .accessibilityIdentifier("sort.menu")

            Button {
                isShowingDatabaseDetails = true
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Database Details")
            .accessibilityLabel("Database Details")
            .accessibilityIdentifier("database-details.button")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings.button")
        }
    }

    private func beginNewGroup() {
        newGroupName = ""
        newGroupParentID = nil
        groupCreationErrorMessage = nil
        isShowingNewGroupSheet = true
    }

    /// "New Subgroup" from a sidebar row: creates the group under that specific
    /// group rather than whatever is currently selected.
    private func beginNewSubgroup(parentID: UUID) {
        newGroupName = ""
        newGroupParentID = parentID
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

    /// Opens the editor on the selected entry — the ⌘E command and the entry
    /// row's double-click both land here. `EntryDetailView`'s own Edit button
    /// keeps its editor; this one exists because neither the menu bar nor a
    /// content-column row can reach into the detail column's state.
    @MainActor
    private func beginEntryEdit(entryID: UUID) {
        guard commandEditor == nil, viewModel.isReadOnly == false else { return }
        guard let entry = viewModel.entry(withID: entryID), let sessionKey = viewModel.sessionKey else { return }

        commandEditor = EntryEditViewModel(
            editing: entry,
            sessionKey: sessionKey,
            knownTags: viewModel.tagsInDisplayOrder,
            inheritedTags: viewModel.inheritedTags(forEntryID: entryID)
        )
    }

    /// Opens the prefilled New Entry form the content column's Duplicate item
    /// built, in the workspace's own editor sheet.
    @MainActor
    private func beginEntryDuplicate(_ formViewModel: EntryEditViewModel) {
        guard commandEditor == nil else { return }
        commandEditor = formViewModel
    }

    @MainActor
    private func beginSelectedEntryEdit() {
        guard let entryID = viewModel.selectedEntryID else { return }
        beginEntryEdit(entryID: entryID)
    }

    /// Menu-bar Delete: raises the same `PendingDeletion` confirmation the row
    /// context menus raise, never a direct delete.
    @MainActor
    private func beginSelectionDeletion() {
        switch viewModel.deletableSelection {
        case .entry(let entryID):
            pendingDeletion = .entry(
                PendingEntryDeletion(
                    entryID: entryID,
                    sendToRecycleBin: viewModel.isEntryInRecycleBin(entryID: entryID) == false
                )
            )
        case .group(let groupID):
            guard let pending = PendingGroupDeletion(groupID: groupID, viewModel: viewModel) else { return }
            pendingDeletion = .group(pending)
        case nil:
            return
        }
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
/// What the macOS sidebar's native `List(selection:)` carries. The two cases
/// mirror `DatabaseViewModel.selectedGroupID` / `selectedTag`, which stay the
/// source of truth; this type only exists because one list needs one selection
/// value.
enum MacSidebarSelection: Hashable {
    case group(UUID)
    case tag(String)
}

/// The macOS content column: the selected group's entries in a native
/// `List(selection:)` bound to `DatabaseViewModel.selectedEntryID`, so arrow
/// keys, type-select, and the focus ring come from AppKit rather than being
/// hand-rolled. A dedicated `@Bindable` observing view (not an inline
/// `@ViewBuilder` on the workspace) so it re-renders on
/// `DatabaseViewModel.contentRevision` changes — e.g. after an edit renames an
/// entry, which an inline computed property missed.
private struct MacEntriesColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    /// A row's tap handler consumes the click, so the list never becomes first
    /// responder on its own and the arrow keys would go nowhere; the handler
    /// hands focus over explicitly.
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
                    List(entries, selection: $viewModel.selectedEntryID) { entry in
                        MacEntryRow(
                            entry: entry,
                            viewModel: viewModel,
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
                        guard let entryID = viewModel.selectedEntryID else { return .ignored }
                        onOpenEntry(entryID)
                        return .handled
                    }
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
    let icon: String
    let children: [MacGroupNode]?
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
                // the label consumes the click the list needs to change its
                // selection, and selecting a group is what this row is for.
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
            Image(systemName: node.icon)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .macSelectableRowHover()
        .help(node.name)
        .accessibilityIdentifier("group.navlink")
        .contextMenu {
            if canEdit {
                Button("New Subgroup") {
                    onRequestNewSubgroup(node.id)
                }
                .accessibilityIdentifier("group-row.new-subgroup")

                Button("Edit Group") {
                    onEditGroup(node.id)
                }
                .accessibilityIdentifier("group-row.edit-context")
            }

            if canMove {
                Button("Move to Group") {
                    onRequestMove(.group(node.id))
                }
                .accessibilityIdentifier("group-row.move-context")
            }

            if canDelete {
                Button(deleteTitle, role: .destructive) {
                    requestDeletion()
                }
                .accessibilityIdentifier(
                    viewModel.isGroupInRecycleBin(groupID: node.id)
                        ? "group-row.delete-permanent"
                        : "group-row.delete-context"
                )
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

    /// The iOS row's `canMoveGroup`: editable, plus the deletion-protection
    /// screen that also covers the roots the draft would refuse to reparent.
    private var canMove: Bool {
        canEdit && viewModel.isGroupProtectedFromDeletion(groupID: node.id) == false
    }

    private var deleteTitle: String {
        viewModel.isGroupInRecycleBin(groupID: node.id) ? "Delete Permanently" : "Delete"
    }

    private func requestDeletion() {
        guard let pending = PendingGroupDeletion(groupID: node.id, viewModel: viewModel) else { return }
        onRequestDeletion(.group(pending))
    }
}
#endif
