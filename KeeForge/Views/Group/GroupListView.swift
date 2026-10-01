import SwiftUI

struct GroupListView: View {
    /// Identifies the group whose icon picker is showing. A wrapper rather than a bare
    /// `UUID?` so `sheet(item:)` has an `Identifiable` to key on without retroactively
    /// conforming a standard-library type.
    struct PendingIconChange: Identifiable {
        let groupID: UUID

        var id: UUID { groupID }
    }

    let groupID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// macOS drill-down: when set, group rows call this instead of pushing a
    /// `NavigationLink` (pushed sidebar stacks render zero-height on macOS).
    var onSelectGroup: ((UUID) -> Void)? = nil
    /// iPad split view: when set, New Entry hands its editor to the host so it
    /// opens in the detail column instead of being pushed into this sidebar.
    var onCreateEntry: ((EntryEditViewModel) -> Void)? = nil
    /// iPad split view: same hand-off for the group editor.
    var onEditGroup: ((GroupEditViewModel) -> Void)? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showSettings = false
    @State private var activeEditor: EntryEditViewModel?
    /// The group editor's form state, or `nil` when no editor is presented.
    @State private var activeGroupEditor: GroupEditViewModel?
    @State private var pendingDeletion: PendingDeletion?
    @State private var isShowingNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var groupCreationErrorMessage: String?
    /// The group whose icon picker is presented, or `nil` when none is.
    @State private var pendingIconChange: PendingIconChange?
    /// The entry or group whose Move-to-Group picker is presented, or `nil`.
    @State private var pendingMove: PendingMove?
    #if os(macOS)
    @FocusState private var isSearchFieldFocused: Bool
    #endif

    private var resolvedGroup: KPGroup? {
        viewModel.group(withID: groupID)
    }

    /// The view the database root shows; `nil` on pushed levels, which always
    /// browse their own group.
    private var rootViewMode: DatabaseViewModel.ViewMode? {
        groupID == viewModel.visibleRootGroupID ? viewModel.viewMode : nil
    }

    /// The group whose contents are listed: the recycle bin while the root
    /// shows that view, this level's group otherwise.
    private var listedGroup: KPGroup? {
        rootViewMode == .recycleBin ? viewModel.recycleBinGroup : resolvedGroup
    }

    /// The recycle bin is opened from the view menu, never as a group row.
    private var visibleGroups: [KPGroup] {
        let recycleBinID = viewModel.currentRootGroup?.recycleBinUUID
        return listedGroup?.groups.filter { $0.id != recycleBinID } ?? []
    }

    private var visibleEntries: [KPEntry] {
        listedGroup?.entries ?? []
    }

    private var isRecycleBin: Bool {
        guard let listedGroup else { return false }
        return viewModel.currentRootGroup?.recycleBinUUID == listedGroup.id
    }

    private var showsCompactLockButton: Bool {
        // `\.horizontalSizeClass` does not exist on macOS; the Mac app always
        // uses the regular layout.
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// An app built with the iOS 27 SDK folds trailing bar items into an
    /// overflow menu when an inline title needs their room, which would put
    /// Lock behind it under a long title. The pinned placement keeps the items
    /// and truncates the title instead.
    private var databaseActionsPlacement: ToolbarItemPlacement {
        #if compiler(>=6.4)
        #if os(iOS)
        if #available(iOS 27.0, *) {
            return .topBarPinnedTrailing
        }
        #endif
        #endif
        return .topBarTrailing
    }

    var body: some View {
        Group {
            if viewModel.searchText.isEmpty {
                if let resolvedGroup {
                    List {
                        browsingRows
                    }
                    .id(viewModel.contentRevision)
                    .navigationTitle(navigationTitle(for: resolvedGroup))
                    .navigationBarTitleDisplayMode(rootViewMode == nil ? .large : .inline)
                    .modifier(GroupListViewMenu(view: self))
                    .toolbar {
                        ToolbarItem(placement: databaseActionsPlacement) {
                            HStack(spacing: 12) {
                                // Leads the trailing group rather than sitting
                                // beside the system back button, which made an
                                // accidental lock a one-tap mistake.
                                Button {
                                    viewModel.lockRequest(manuallyTriggered: true)
                                } label: {
                                    if showsCompactLockButton {
                                        // Compact bars are all icons; a text
                                        // label would be the odd wide one out.
                                        Image(systemName: "lock.fill")
                                    } else {
                                        Text("Lock")
                                    }
                                }
                                .accessibilityLabel("Lock")
                                .accessibilityIdentifier("lock.button")

                                if let warningText = viewModel.cloudSyncBannerText {
                                    CloudSyncWarningButton(message: warningText)
                                }

                                if viewModel.isReadOnly {
                                    ReadOnlyIndicator(explanation: viewModel.readOnlyExplanation)
                                }

                                if viewModel.isReadOnly == false, rootViewMode != .recycleBin {
                                    Menu {
                                        Button("New Entry", systemImage: "doc.badge.plus") {
                                            let editor = EntryEditViewModel(
                                                createIn: resolvedGroup.id,
                                                knownTags: viewModel.tagsInDisplayOrder,
                                                inheritedTags: viewModel.inheritedTags(forGroupID: resolvedGroup.id)
                                            )
                                            if let onCreateEntry {
                                                onCreateEntry(editor)
                                            } else {
                                                activeEditor = editor
                                            }
                                        }

                                        Button("New Group", systemImage: "folder.badge.plus") {
                                            newGroupName = ""
                                            isShowingNewGroupSheet = true
                                        }
                                    } label: {
                                        Image(systemName: "plus")
                                    }
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
                                .accessibilityIdentifier("sort.menu")

                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .accessibilityIdentifier("settings.button")
                            }
                        }
                    }
                    .sheet(isPresented: $showSettings) {
                        DatabaseDetailsView(
                            reference: viewModel.databaseReference,
                            sessionViewModel: viewModel
                        )
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
                                do {
                                    try viewModel.createGroup(named: name, in: resolvedGroup.id)
                                    newGroupName = ""
                                    groupCreationErrorMessage = nil
                                    isShowingNewGroupSheet = false
                                    Task {
                                        await viewModel.saveHandlingError()
                                    }
                                } catch {
                                    groupCreationErrorMessage = error.localizedDescription
                                }
                            }
                        )
                    }
                    .sheet(item: $pendingIconChange) { pending in
                        // Resolved here rather than captured when the menu was tapped, so
                        // the picker highlights the icon the group actually has now.
                        if let group = viewModel.group(withID: pending.groupID) {
                            GroupIconPickerView(
                                groupName: group.name,
                                selectedIconID: group.iconID
                            ) { iconID in
                                changeGroupIcon(iconID, groupID: pending.groupID)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Group Unavailable",
                        systemImage: "folder.badge.questionmark",
                        description: Text("This group no longer exists in the current draft.")
                    )
                }
            } else {
                // The results render inline here, so their deletions go to the
                // host below rather than adding a second, colliding one.
                SearchView(
                    viewModel: viewModel,
                    onSelectEntry: onSelectEntry,
                    onRequestDeletion: { pendingDeletion = $0 }
                )
            }
        }
        .modifier(GroupListSearchModifier(view: self))
        .modifier(GroupListEditorPresentation(view: self))
        .modifier(GroupListGroupEditorPresentation(view: self))
        // On the outer Group: an alert host on the `resolvedGroup` branch would
        // be stranded if the branch vanishes while the alert is up.
        .alert(item: $pendingDeletion, content: deletionAlert)
        // Also on the outer Group, for the same stranding reason. Options are
        // resolved here rather than captured when the menu was tapped, so the
        // picker reflects the tree as it is now.
        .sheet(item: $pendingMove) { pending in
            MoveToGroupPickerView(
                options: pending.destinationOptions(viewModel: viewModel)
            ) { destinationGroupID in
                pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
            }
        }
    }

    /// Presents the entry editor. iOS pushes it onto the navigation stack;
    /// macOS presents a sheet (the sidebar drill-down has no stack to push
    /// onto, and pushed sidebar stacks render zero-height on macOS anyway).
    private struct GroupListEditorPresentation: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .sheet(item: view.$activeEditor) { formViewModel in
                    NavigationStack {
                        EntryEditView(
                            formViewModel: formViewModel,
                            databaseViewModel: view.viewModel
                        ) { _ in
                            view.activeEditor = nil
                        }
                    }
                    .macSheetFrame()
                }
            #else
            content
                .navigationDestination(item: view.$activeEditor) { formViewModel in
                    EntryEditView(
                        formViewModel: formViewModel,
                        databaseViewModel: view.viewModel
                    ) { _ in
                        view.activeEditor = nil
                    }
                }
            #endif
        }
    }

    /// Presents the group editor, with the same iOS-push / macOS-sheet split as
    /// the entry editor. Attached to the body's outer `Group` so a branch that
    /// vanishes mid-edit cannot tear the host down under a presented editor.
    private struct GroupListGroupEditorPresentation: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .sheet(item: view.$activeGroupEditor) { formViewModel in
                    NavigationStack {
                        GroupEditView(
                            formViewModel: formViewModel,
                            databaseViewModel: view.viewModel
                        ) {
                            view.activeGroupEditor = nil
                        }
                    }
                    .macSheetFrame(minHeight: 520)
                }
            #else
            content
                .navigationDestination(item: view.$activeGroupEditor) { formViewModel in
                    GroupEditView(
                        formViewModel: formViewModel,
                        databaseViewModel: view.viewModel
                    ) {
                        view.activeGroupEditor = nil
                    }
                }
            #endif
        }
    }

    /// Turns the database root's title into the view menu. Pushed levels keep
    /// a plain title.
    private struct GroupListViewMenu: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            if view.rootViewMode == nil {
                content
            } else {
                content
                    .toolbarTitleMenu {
                        Section {
                            ForEach(DatabaseViewModel.ViewMode.browsingModes, id: \.self) { mode in
                                viewToggle(for: mode)
                            }
                        }

                        Section {
                            viewToggle(for: .recycleBin)
                        }
                    }
            }
        }

        /// Toggles rather than one `Picker`, whose options cannot be split
        /// into sections inside a menu.
        private func viewToggle(for mode: DatabaseViewModel.ViewMode) -> some View {
            Toggle(
                isOn: Binding(
                    get: { view.viewModel.viewMode == mode },
                    set: { isOn in
                        if isOn {
                            view.viewModel.viewMode = mode
                        }
                    }
                )
            ) {
                Label(mode.title, systemImage: mode.systemImage)
            }
            .accessibilityIdentifier("view-menu.\(mode.rawValue)")
        }
    }

    /// Attaches the search field.
    ///
    /// iOS: every pushed level attaches `.searchable` (navigation-bar drawer),
    /// unchanged legacy behavior.
    ///
    /// macOS: only the ROOT group list attaches `.searchable`. Attaching it on
    /// every pushed level collapses the pushed List to zero height inside the
    /// `NavigationSplitView` sidebar column (SwiftUI layout bug observed on
    /// macOS 26), which made subgroup browsing render an empty sidebar. The
    /// toolbar search field therefore only appears at the vault root, and the
    /// menu-bar Find command (⌘F) focuses it there via
    /// `searchFocusRequestID` + `searchFocused` (macOS 15+).
    private struct GroupListSearchModifier: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(macOS)
            if view.groupID == view.viewModel.visibleRootGroupID {
                content
                    .searchable(
                        text: view.$viewModel.searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search entries"
                    )
                    .searchFocused(view.$isSearchFieldFocused)
                    .onChange(of: view.viewModel.searchFocusRequestID) { _, _ in
                        view.isSearchFieldFocused = true
                    }
            } else {
                content
            }
            #else
            content
                .searchable(
                    text: view.$viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search entries"
                )
            #endif
        }
    }

    /// The Groups view keeps the database's own name as the root title; the
    /// other views are titled after themselves.
    private func navigationTitle(for group: KPGroup) -> String {
        switch rootViewMode {
        case .groups, nil:
            group.name
        case let mode?:
            mode.title
        }
    }

    @ViewBuilder
    private var browsingRows: some View {
        switch rootViewMode {
        case .allEntries:
            flatEntriesSection(
                viewModel.allEntries,
                summary: allEntriesSummary,
                emptyTitle: "No Entries",
                emptyDescription: "This database has no entries."
            )
        case .verificationCodes:
            flatEntriesSection(
                viewModel.verificationCodeEntries,
                showsVerificationCodes: true,
                summary: String(
                    localized: "Every entry with a verification code, across all groups. Tap an entry to open it."
                ),
                emptyTitle: "No Verification Codes",
                emptyDescription: "Entries with a verification code appear here."
            )
        case .tags:
            TagListRows(viewModel: viewModel)
        case .recycleBin:
            groupContents(
                emptyTitle: "Recycle Bin Is Empty",
                emptyDescription: "Deleted entries and groups appear here."
            )
        case .groups, nil:
            groupContents(
                emptyTitle: "Empty Group",
                emptyDescription: "This group has no entries."
            )
        }
    }

    @ViewBuilder
    private func groupContents(
        emptyTitle: LocalizedStringKey,
        emptyDescription: LocalizedStringKey
    ) -> some View {
        if !visibleGroups.isEmpty {
            Section("Groups") {
                ForEach(viewModel.sortedGroups(visibleGroups).map(\.id), id: \.self) { subgroupID in
                    groupRow(for: subgroupID)
                }
            }
        }

        if !visibleEntries.isEmpty {
            Section("Entries") {
                ForEach(viewModel.sortedEntries(visibleEntries)) { entry in
                    entryRow(for: entry)
                }
            }
        }

        if visibleGroups.isEmpty && visibleEntries.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: rootViewMode?.systemImage ?? "folder",
                description: Text(emptyDescription)
            )
        }
    }

    /// Entries drawn from the whole database, so each row says where its entry
    /// lives.
    @ViewBuilder
    private func flatEntriesSection(
        _ entries: [KPEntry],
        showsVerificationCodes: Bool = false,
        summary: String,
        emptyTitle: LocalizedStringKey,
        emptyDescription: LocalizedStringKey
    ) -> some View {
        if entries.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: rootViewMode?.systemImage ?? "folder",
                description: Text(emptyDescription)
            )
        } else {
            Section {
                ForEach(viewModel.sortedEntries(entries)) { entry in
                    entryRow(for: entry, showsFolderPath: true, showsVerificationCode: showsVerificationCodes)
                }
            } footer: {
                Text(summary)
                    .accessibilityIdentifier("group-list.summary")
            }
        }
    }

    private var allEntriesSummary: String {
        let entries = String(localized: "\(viewModel.allEntries.count) entries")
        let groupCount = viewModel.allEntriesGroupCount
        guard groupCount > 0 else { return entries }
        let groups = String(localized: "\(groupCount) groups")
        return String(localized: "\(entries) in \(groups)")
    }

    @ViewBuilder
    private func groupRow(for groupID: UUID) -> some View {
        Group {
            if let onSelectGroup {
                Button {
                    onSelectGroup(groupID)
                } label: {
                    GroupRow(groupID: groupID, viewModel: viewModel)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("group.navlink")
            } else {
                NavigationLink(value: groupID) {
                    GroupRow(groupID: groupID, viewModel: viewModel)
                }
                .accessibilityIdentifier("group.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            if canEditGroup(groupID) {
                Button("Edit Group") {
                    guard let editor = makeGroupEditor(groupID) else { return }
                    if let onEditGroup {
                        onEditGroup(editor)
                    } else {
                        activeGroupEditor = editor
                    }
                }
                .accessibilityIdentifier("group-row.edit-context")
            }

            if canMoveGroup(groupID) {
                Button("Move to Group") {
                    pendingMove = .group(groupID)
                }
                .accessibilityIdentifier("group-row.move-context")
            }

            if canChangeGroupIcon(groupID) {
                Button("Change Icon") {
                    pendingIconChange = PendingIconChange(groupID: groupID)
                }
                .accessibilityIdentifier("group-row.change-icon-context")
            }

            if canChangeAutoFillExclusion(groupID) {
                Button(autoFillExclusionButtonTitle(for: groupID)) {
                    toggleAutoFillExclusion(groupID)
                }
                .accessibilityIdentifier("group-row.autofill-exclusion-context")
            }

            if canDeleteGroup(groupID) {
                Button(groupDeleteButtonTitle(for: groupID), role: .destructive) {
                    preparePendingGroupDeletion(groupID)
                }
                .accessibilityIdentifier(groupDeleteContextIdentifier(for: groupID))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDeleteGroup(groupID) {
                Button(groupDeleteButtonTitle(for: groupID), role: .destructive) {
                    preparePendingGroupDeletion(groupID)
                }
                .accessibilityIdentifier("group-row.delete-swipe")
            }
        }
    }

    @ViewBuilder
    private func entryRow(
        for entry: KPEntry,
        showsFolderPath: Bool = false,
        showsVerificationCode: Bool = false
    ) -> some View {
        let row = EntryRow(
            entry: entry,
            username: viewModel.resolvingFieldReferences(entry.username),
            customIconData: viewModel.customIconData(for: entry),
            folderPath: showsFolderPath ? viewModel.folderPath(forEntryID: entry.id) : nil
        )
        Group {
            if showsVerificationCode, let config = entry.totpConfig, let sessionKey = viewModel.sessionKey {
                VerificationCodeRow(
                    title: entry.title.isEmpty ? String(localized: "(untitled)") : entry.title,
                    detail: verificationCodeDetail(for: entry),
                    config: config,
                    sessionKey: sessionKey
                ) {
                    open(entry)
                }
            } else if let onSelectEntry {
                Button {
                    onSelectEntry(entry)
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry.navlink")
            } else {
                NavigationLink(value: entry) {
                    row
                }
                .accessibilityIdentifier("entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            EntryRowCopyActions(entry: entry, viewModel: viewModel)

            EntryRowDuplicateAction(entryID: entry.id, viewModel: viewModel) { editor in
                if let onCreateEntry {
                    onCreateEntry(editor)
                } else {
                    activeEditor = editor
                }
            }

            EntryRowMoveAction(entryID: entry.id, viewModel: viewModel) { move in
                pendingMove = move
            }

            if viewModel.isReadOnly == false {
                Button(isRecycleBin ? "Delete Permanently" : "Delete", role: .destructive) {
                    pendingDeletion = .entry(
                        PendingEntryDeletion(
                            entryID: entry.id,
                            sendToRecycleBin: !isRecycleBin
                        )
                    )
                }
                .accessibilityIdentifier(
                    isRecycleBin ? "entry-row.delete-permanent" : "entry-row.delete-context"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.isReadOnly == false {
                Button(isRecycleBin ? "Delete Permanently" : "Delete", role: .destructive) {
                    pendingDeletion = .entry(
                        PendingEntryDeletion(
                            entryID: entry.id,
                            sendToRecycleBin: !isRecycleBin
                        )
                    )
                }
                .accessibilityIdentifier("entry-row.delete-swipe")
            }
        }
    }

    /// What tapping a `NavigationLink(value: entry)` row does in each shell:
    /// the regular-width workspace selects, the compact stack pushes.
    private func open(_ entry: KPEntry) {
        if let onSelectEntry {
            onSelectEntry(entry)
        } else {
            viewModel.navigationPath.append(entry)
        }
    }

    private func verificationCodeDetail(for entry: KPEntry) -> String {
        [viewModel.resolvingFieldReferences(entry.username), viewModel.folderPath(forEntryID: entry.id) ?? ""]
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }

    private func canDeleteGroup(_ groupID: UUID) -> Bool {
        viewModel.isReadOnly == false && viewModel.isGroupProtectedFromDeletion(groupID: groupID) == false
    }

    private func groupDeleteButtonTitle(for groupID: UUID) -> String {
        viewModel.isGroupInRecycleBin(groupID: groupID) ? "Delete Permanently" : "Delete"
    }

    /// Same eligibility as the icon and AutoFill shortcuts: the Recycle Bin and
    /// everything inside it stay non-editable, and nothing is editable in a
    /// read-only database.
    private func canEditGroup(_ groupID: UUID) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.currentRootGroup?.recycleBinUUID != groupID
            && viewModel.isGroupInRecycleBin(groupID: groupID) == false
    }

    /// Built when the menu item is tapped rather than per render, so the form
    /// opens on the group's state at that moment.
    private func makeGroupEditor(_ groupID: UUID) -> GroupEditViewModel? {
        guard let group = viewModel.group(withID: groupID) else { return nil }
        return GroupEditViewModel(
            editing: group,
            isHiddenFromAutoFill: viewModel.isGroupExcludedFromAutoFill(groupID: groupID),
            isExclusionInherited: viewModel.isGroupExclusionInherited(groupID: groupID),
            knownTags: viewModel.tagsInDisplayOrder
        )
    }

    /// `canEditGroup` plus the deletion-protection screen, which also covers
    /// the roots the draft would refuse to reparent.
    private func canMoveGroup(_ groupID: UUID) -> Bool {
        canEditGroup(groupID)
            && viewModel.isGroupProtectedFromDeletion(groupID: groupID) == false
    }

    /// Same eligibility as the AutoFill toggle, for the same reasons: nothing is
    /// editable in a read-only database, and the Recycle Bin row always draws a trash
    /// can regardless of the stored `iconID`, so picking an icon there would appear to
    /// do nothing.
    private func canChangeGroupIcon(_ groupID: UUID) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.currentRootGroup?.recycleBinUUID != groupID
            && viewModel.isGroupInRecycleBin(groupID: groupID) == false
    }

    private func changeGroupIcon(_ iconID: Int, groupID: UUID) {
        do {
            try viewModel.setGroupIcon(iconID, groupID: groupID)
            Task {
                await viewModel.saveHandlingError()
            }
        } catch {
            viewModel.presentSaveError(error)
        }
    }

    private func canChangeAutoFillExclusion(_ groupID: UUID) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.currentRootGroup?.recycleBinUUID != groupID
            && viewModel.isGroupInRecycleBin(groupID: groupID) == false
    }

    private func autoFillExclusionButtonTitle(for groupID: UUID) -> String {
        if viewModel.isGroupExcludedFromAutoFill(groupID: groupID) {
            return viewModel.isGroupExclusionInherited(groupID: groupID)
                ? String(localized: "Show in Search & AutoFill (Overrides Parent)")
                : String(localized: "Show in Search & AutoFill")
        }
        return String(localized: "Hide from Search & AutoFill")
    }

    private func toggleAutoFillExclusion(_ groupID: UUID) {
        let shouldExclude = viewModel.isGroupExcludedFromAutoFill(groupID: groupID) == false
        do {
            try viewModel.setGroupExcludedFromAutoFill(shouldExclude, groupID: groupID)
            Task {
                await viewModel.saveHandlingError()
            }
        } catch {
            viewModel.presentSaveError(error)
        }
    }

    private func groupDeleteContextIdentifier(for groupID: UUID) -> String {
        viewModel.isGroupInRecycleBin(groupID: groupID)
            ? "group-row.delete-permanent"
            : "group-row.delete-context"
    }

    private func preparePendingGroupDeletion(_ groupID: UUID) {
        guard let pending = PendingGroupDeletion(groupID: groupID, viewModel: viewModel) else { return }
        pendingDeletion = .group(pending)
    }

    private func deletionAlert(for deletion: PendingDeletion) -> Alert {
        deletion.confirmationAlert(viewModel: viewModel)
    }
}

struct NewGroupSheet: View {
    @Binding var name: String
    @Binding var errorMessage: String?
    let onCancel: () -> Void
    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("group-create.name-field")
                }
            }
            .macGroupedForm()
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("group-create.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("group-create.confirm")
                }
            }
            .alert("Couldn’t Create Group", isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 180)
    }
}

struct GroupRow: View {
    let groupID: UUID
    @Bindable var viewModel: DatabaseViewModel

    private var group: KPGroup? {
        viewModel.group(withID: groupID)
    }

    /// Matches `canChangeAutoFillExclusion`: the badge is only shown where the
    /// context menu can actually act on it. KeePass and KeePassXC set
    /// `<EnableSearching>False</EnableSearching>` on the recycle bins they
    /// create, so without the first check every trashed subgroup in a
    /// KeePass-made database would inherit an unactionable badge.
    private var isExcludedFromAutoFill: Bool {
        viewModel.isGroupInRecycleBin(groupID: groupID) == false
            && viewModel.isGroupExcludedFromAutoFill(groupID: groupID)
    }

    var body: some View {
        Group {
            if let group {
                HStack {
                    if let iconData = viewModel.customIconData(for: group),
                       let icon = PlatformImage(data: iconData) {
                        Image(platformImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .frame(width: 22, height: 22)
                            .frame(width: 28)
                    } else {
                        StandardIconView(
                            iconID: group.iconID,
                            fallbackSystemName: "folder.fill",
                            fallbackPalette: .blue
                        )
                            .frame(width: 28)
                    }

                    VStack(alignment: .leading) {
                        Text(group.name)
                            .font(.body)
                        Text("\(viewModel.entryCount(forGroupID: groupID)) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isExcludedFromAutoFill {
                        Spacer(minLength: 4)
                        Image(systemName: "key.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Hidden from Search & AutoFill")
                            .accessibilityIdentifier("group-row.autofill-excluded")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
    }
}

struct EntryRow: View {
    let entry: KPEntry
    /// The subtitle to show; callers pass the entry's username with field
    /// references resolved.
    var username: String
    var customIconData: Data? = nil
    var folderPath: String? = nil

    var body: some View {
        HStack {
            FaviconView(url: entry.url, iconID: entry.iconID, size: 24, customIconData: customIconData)
                .frame(width: 28)

            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
                    .font(.body)
                if !username.isEmpty {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let folderPath, folderPath.isEmpty == false {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .accessibilityHidden(true)
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityIdentifier("entry-row.folder")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isExpired() {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Expired")
                    .accessibilityIdentifier("entry-row.expired")
            }

            if entry.hasPasskey {
                Image(systemName: "person.badge.key.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .accessibilityLabel("Has a passkey")
                    .accessibilityIdentifier("entry-row.passkey")
            }

            if entry.totpConfig != nil {
                Image(systemName: "clock.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Has a verification code")
                    .accessibilityIdentifier("entry-row.totp")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
