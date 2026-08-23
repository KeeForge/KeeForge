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

    private var visibleGroups: [KPGroup] {
        resolvedGroup?.groups ?? []
    }

    private var visibleEntries: [KPEntry] {
        resolvedGroup?.entries ?? []
    }

    private var isRecycleBin: Bool {
        viewModel.currentRootGroup?.recycleBinUUID == groupID
    }

    /// Whether this level is the database root, where the Tags row belongs.
    /// Same predicate `GroupListSearchModifier` uses to pick the root.
    private var isVisibleRoot: Bool {
        groupID == viewModel.visibleRootGroupID
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

    var body: some View {
        Group {
            if viewModel.searchText.isEmpty {
                if let resolvedGroup {
                    List {
                        // Stays visible at zero tags: its empty state is what
                        // teaches the user how to add one.
                        if isVisibleRoot {
                            Section {
                                tagsRow()
                            }
                        }

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

                        // Describes the group's own contents only; at the root
                        // the Tags section above stays put so the browser is
                        // reachable from an otherwise empty vault.
                        if visibleGroups.isEmpty && visibleEntries.isEmpty {
                            ContentUnavailableView(
                                "Empty Group",
                                systemImage: "folder",
                                description: Text("This group has no entries.")
                            )
                        }
                    }
                    .id(viewModel.contentRevision)
                    .navigationTitle(resolvedGroup.name)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        if showsCompactLockButton {
                            ToolbarItem(placement: .topBarLeading) {
                                // Icon, not text: this sits directly after the
                                // system back label, and two adjacent text
                                // buttons read as one ("Social Lock").
                                Button {
                                    viewModel.lockRequest(manuallyTriggered: true)
                                } label: {
                                    Image(systemName: "lock.fill")
                                }
                                .accessibilityLabel("Lock")
                                .accessibilityIdentifier("lock.button")
                            }
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 12) {
                                if let warningText = viewModel.cloudSyncBannerText {
                                    CloudSyncWarningButton(message: warningText)
                                }

                                if viewModel.isReadOnly {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Read-only database")
                                        .accessibilityIdentifier("database.read-only-indicator")
                                }

                                if viewModel.isReadOnly == false {
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

                                if showsCompactLockButton == false {
                                    Button("Lock") {
                                        viewModel.lockRequest(manuallyTriggered: true)
                                    }
                                    .accessibilityIdentifier("lock.button")
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
                SearchView(viewModel: viewModel, onSelectEntry: onSelectEntry)
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
                    .frame(minWidth: 540, minHeight: 560)
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
                    .frame(minWidth: 540, minHeight: 520)
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
                    .macSearchFocusedCompat(view.$isSearchFieldFocused)
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

    /// The root-level entry point into the tag browser. A plain
    /// `NavigationLink`: every shell that renders this view browses through a
    /// `NavigationStack` (the macOS split view builds its own sidebar Tags
    /// section instead and never shows this row).
    @ViewBuilder
    private func tagsRow() -> some View {
        NavigationLink(value: TagDestination.allTags) {
            TagBrowserRow(viewModel: viewModel)
        }
        .accessibilityIdentifier("group-list.tags-row")
        .macHoverHighlight()
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
    private func entryRow(for entry: KPEntry) -> some View {
        Group {
            if let onSelectEntry {
                Button {
                    onSelectEntry(entry)
                } label: {
                    EntryRow(
                        entry: entry,
                        username: viewModel.resolvingFieldReferences(entry.username),
                        customIconData: viewModel.customIconData(for: entry)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry.navlink")
            } else {
                NavigationLink(value: entry) {
                    EntryRow(
                        entry: entry,
                        username: viewModel.resolvingFieldReferences(entry.username),
                        customIconData: viewModel.customIconData(for: entry)
                    )
                }
                .accessibilityIdentifier("entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            if canMoveEntry(entry) {
                Button("Move to Group") {
                    pendingMove = .entry(entry.id)
                }
                .accessibilityIdentifier("entry-row.move-context")
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

    /// Entries can move when the database accepts edits and the entry is not
    /// recycled — restoring from the bin is the restore flow, not a move.
    private func canMoveEntry(_ entry: KPEntry) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.isEntryInRecycleBin(entryID: entry.id) == false
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

    private var isRecycleBin: Bool {
        viewModel.currentRootGroup?.recycleBinUUID == groupID
    }

    /// Matches `canChangeAutoFillExclusion`: the badge is only shown where the
    /// context menu can actually act on it. KeePass and KeePassXC set
    /// `<EnableSearching>False</EnableSearching>` on the recycle bins they
    /// create, so without the second check every trashed subgroup in a
    /// KeePass-made database would inherit an unactionable badge.
    private var isExcludedFromAutoFill: Bool {
        isRecycleBin == false
            && viewModel.isGroupInRecycleBin(groupID: groupID) == false
            && viewModel.isGroupExcludedFromAutoFill(groupID: groupID)
    }

    var body: some View {
        Group {
            if let group {
                HStack {
                    if !isRecycleBin,
                       let iconData = viewModel.customIconData(for: group),
                       let icon = PlatformImage(data: iconData) {
                        Image(platformImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .frame(width: 22, height: 22)
                            .frame(width: 28)
                    } else {
                        Image(systemName: isRecycleBin ? "trash" : group.systemIconName)
                            .foregroundStyle(.tint)
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

/// The root list's "Tags" row: the database's distinct-tag count over the whole
/// tree. Shown at zero too, so the tag browser is discoverable in a vault that
/// has no tags yet.
struct TagBrowserRow: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        HStack {
            Image(systemName: "tag")
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading) {
                Text("Tags")
                    .font(.body)
                Text("\(viewModel.allTags.count) tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
