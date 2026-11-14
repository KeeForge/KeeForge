import OneTimeCodes
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
    /// The database-wide list this screen shows, opened from a root tile;
    /// `nil` for the root and the group levels.
    var collection: DatabaseCollection? = nil
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// iPad split view: pushes onto the sidebar's own stack, which is not the
    /// workspace's navigation path.
    var onOpenRoute: ((DatabaseRoute) -> Void)? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showSettings = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var isShowingNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var groupCreationErrorMessage: String?
    /// The group whose icon picker is presented, or `nil` when none is.
    @State private var pendingIconChange: PendingIconChange?
    /// The entry or group whose Move-to-Group picker is presented, or `nil`.
    @State private var pendingMove: PendingMove?
    @State private var pendingEntryIconChange: PendingEntryIconChange?
    @State private var isShowingQRScanner = false
    /// A scanned code waits here until the scanner has dismissed, then opens
    /// the enrollment, which offers the entry to add it to.
    @State private var scannedCode: ScannedCode?
    @State private var codeToEnroll: ScannedCode?

    struct ScannedCode: Identifiable {
        let id = UUID()
        let uri: OTPAuthURI
    }

    private var resolvedGroup: KPGroup? {
        viewModel.group(withID: groupID)
    }

    /// The database root, which shows the tiles above its groups.
    private var isRoot: Bool {
        collection == nil && groupID == viewModel.visibleRootGroupID
    }

    /// The group whose contents are listed: the recycle bin on its own
    /// screen, this level's group otherwise.
    private var listedGroup: KPGroup? {
        collection == .recycleBin ? viewModel.recycleBinGroup : resolvedGroup
    }

    /// The recycle bin opens from its tile, never as a group row.
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

    private var isCompact: Bool {
        // `\.horizontalSizeClass` does not exist on macOS; the Mac app always
        // uses the regular layout.
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var canCreateHere: Bool {
        viewModel.isReadOnly == false && collection != .recycleBin
    }

    /// From iOS 26 compact screens put search and New in a bottom bar.
    private var usesBottomToolbar: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return isCompact
        }
        #endif
        return false
    }

    /// iPhone lays selection mode out like Notes, in the bars; elsewhere a
    /// bar along the bottom edge does it.
    private var usesSelectionToolbar: Bool {
        usesBottomToolbar
    }

    /// "2 Selected" in place of the title while picking entries on iPhone.
    private var selectionTitle: String? {
        guard usesSelectionToolbar, let selection = viewModel.workspace.entrySelection else { return nil }
        return selection.isEmpty
            ? String(localized: "Select Entries")
            : String(localized: "\(selection.count) Selected")
    }

    /// What Select All picks: the movable entries this screen lists.
    private var selectableEntryIDs: [UUID] {
        guard viewModel.searchText.isEmpty else { return [] }
        let entries: [KPEntry] = switch collection {
        case .allEntries: viewModel.allEntries
        case .verificationCodes: viewModel.verificationCodeEntries
        case .tags, .recycleBin: []
        case nil: visibleEntries
        }
        return entries.map(\.id).filter { EntryRowMoveAction.isAvailable(entryID: $0, viewModel: viewModel) }
    }

    var body: some View {
        Group {
            if viewModel.searchText.isEmpty {
                if let resolvedGroup {
                    List {
                        if isRoot {
                            homeSections
                        }
                        browsingRows
                    }
                    .id(viewModel.contentRevision)
                    .navigationTitle(selectionTitle ?? navigationTitle(for: resolvedGroup))
                    .modifier(GroupListSubtitle(subtitle: subtitle(for: resolvedGroup), isTitlePinned: pinsCloudTitle))
                    .toolbar {
                        if usesSelectionToolbar == false || viewModel.workspace.entrySelection == nil {
                        ToolbarItem(placement: .databaseActions) {
                            HStack(spacing: 12) {
                                // Leads the trailing group rather than sitting
                                // beside the system back button, which made an
                                // accidental lock a one-tap mistake.
                                DatabaseLockButton(viewModel: viewModel, isCompact: isCompact)

                                // The root says it in a card of its own.
                                if viewModel.isReadOnly, isRoot == false {
                                    ReadOnlyIndicator(explanation: viewModel.readOnlyExplanation)
                                }

                                if canCreateHere, usesBottomToolbar == false {
                                    addMenu(in: resolvedGroup)
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
                                .accessibilityLabel("Sort By")
                                .accessibilityIdentifier("sort.menu")

                                moreMenu
                            }
                        }
                        }
                    }
                    .modifier(GroupListLeadingTitle(view: self))
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
        .modifier(CloudBrowsingTitleStyle(view: self))
        .modifier(GroupListBottomBar(view: self))
        .modifier(GroupListSearchModifier(view: self))
        // On the outer Group: an alert host on the `resolvedGroup` branch would
        // be stranded if the branch vanishes while the alert is up.
        .alert(item: $pendingDeletion, content: deletionAlert)
        // Also on the outer Group, for the same stranding reason. Options are
        // resolved here rather than captured when the menu was tapped, so the
        // picker reflects the tree as it is now.
        .sheet(item: $pendingMove) { pending in
            MoveToGroupPickerView(
                options: pending.destinationOptions(viewModel: viewModel),
                navigationTitle: pending.navigationTitle
            ) { destinationGroupID in
                pending.apply(destinationGroupID: destinationGroupID, viewModel: viewModel)
            }
        }
        .sheet(item: $pendingEntryIconChange) { pending in
            EntryIconChangeSheet(entryID: pending.entryID, viewModel: viewModel)
        }
        // Covers the inline search results as well as this level's own rows.
        .modifier(
            EntrySelectionChrome(
                viewModel: viewModel,
                usesToolbar: usesSelectionToolbar,
                selectableEntryIDs: selectableEntryIDs
            ) { pendingMove = $0 }
        )
        .modifier(GroupListCodeEnrollment(view: self))
    }

    /// New › Scan QR Code: the scanner, then the same enrollment an
    /// `otpauth://` link opens. On the outer container like the other hosts.
    private struct GroupListCodeEnrollment: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(iOS)
            content
                .sheet(isPresented: view.$isShowingQRScanner, onDismiss: {
                    view.codeToEnroll = view.scannedCode
                    view.scannedCode = nil
                }) {
                    TOTPQRScannerSheet { uri in
                        view.scannedCode = ScannedCode(uri: uri)
                    }
                }
                .sheet(item: view.$codeToEnroll) { code in
                    TOTPEnrollmentDestinationView(databaseViewModel: view.viewModel, uri: code.uri) {
                        view.codeToEnroll = nil
                    }
                }
            #else
            content
            #endif
        }
    }

    /// Actions other than sorting. A divider, not a `Section`: iOS 27 drops
    /// the identifiers of buttons inside a menu section.
    private var moreMenu: some View {
        Menu {
            if canSelectEntries {
                Button("Select Entries", systemImage: "checklist") {
                    viewModel.workspace.beginEntrySelection()
                }
                .accessibilityIdentifier("vault.more.select")
            }

            if CloudSyncControls.isVisible(for: viewModel) {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await viewModel.syncCloudNow() }
                }
                .disabled(viewModel.canSyncCloudNow == false)
                .accessibilityIdentifier("vault.more.sync")
            }

            Divider()

            Button("Database Details", systemImage: "doc.text") {
                showSettings = true
            }
            .accessibilityIdentifier("settings.button")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("vault.more")
    }

    /// Same gate as a row's Select Entries: writable, outside the recycle bin.
    private var canSelectEntries: Bool {
        viewModel.isReadOnly == false
            && viewModel.workspace.entrySelection == nil
            && collection != .tags
            && collection != .recycleBin
            && isRecycleBin == false
    }

    private func addMenu(in group: KPGroup) -> some View {
        Menu {
            Button("New Entry", systemImage: "doc.badge.plus") {
                let editor = EntryEditViewModel(
                    createIn: group.id,
                    knownTags: viewModel.tagsInDisplayOrder,
                    inheritedTags: viewModel.inheritedTags(forGroupID: group.id)
                )
                viewModel.workspace.present(.entry(editor))
            }

            Button("New Group", systemImage: "folder.badge.plus") {
                newGroupName = ""
                isShowingNewGroupSheet = true
            }

            #if os(iOS)
            Divider()

            Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                isShowingQRScanner = true
            }
            .accessibilityIdentifier("entry-list.scan-qr")
            #endif
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add")
        .accessibilityIdentifier("entry-list.add-entry")
    }

    /// The root's sync status and read-only state in words, then its tiles.
    @ViewBuilder
    private var homeSections: some View {
        #if os(iOS)
        if pinsCloudTitle == false, CloudSyncStatusRow.isVisible(for: viewModel) {
            Section {
                CloudSyncStatusRow(viewModel: viewModel)
            }
        }
        #endif
        if viewModel.isReadOnly {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                        Text("Read-only database")
                            .font(Theme.Font.subhead.weight(.semibold))
                        Text(viewModel.readOnlyExplanation)
                            .font(Theme.Font.footnote)
                            .foregroundStyle(Theme.labelSecondary)
                    }
                } icon: {
                    Image(systemName: "lock")
                        .foregroundStyle(Theme.labelSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("database.read-only-indicator")
            }
        }
        Section {
            VaultHomeTiles(counts: viewModel.collectionCounts, isInSidebar: onOpenRoute != nil) { collection in
                openRoute(.collection(collection))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func openRoute(_ route: DatabaseRoute) {
        if let onOpenRoute {
            onOpenRoute(route)
        } else {
            viewModel.workspace.navigationPath.append(route)
        }
    }

    private struct CloudBrowsingTitleStyle: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(iOS)
            if view.pinsCloudTitle {
                content
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(removing: .title)
                    .refreshable { await view.viewModel.syncCloudNow() }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                title
                                Spacer(minLength: 0)
                            }
                            HStack {
                                Spacer(minLength: 0)
                                CloudSyncControls(viewModel: view.viewModel)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.side)
                        .background(Color(.systemBackground))
                    }
            } else if CloudSyncControls.isVisible(for: view.viewModel) {
                content
                    .refreshable { await view.viewModel.syncCloudNow() }
            } else {
                content
            }
            #else
            content
            #endif
        }

        #if os(iOS)
        private var title: some View {
            Group {
                if view.viewModel.searchText.isEmpty == false {
                    Text("Search")
                } else if let group = view.resolvedGroup {
                    Text(view.navigationTitle(for: group))
                }
            }
            .font(.largeTitle.bold())
            .lineLimit(1)
        }
        #endif
    }

    /// The database's name on iPhone sits level with Lock, Sort, and More,
    /// rather than as a large title under them.
    private struct GroupListLeadingTitle: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(iOS)
            if view.isRoot, view.usesBottomToolbar, view.pinsCloudTitle == false,
               view.viewModel.workspace.entrySelection == nil {
                content.toolbarTitleDisplayMode(.inlineLarge)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// Search and New at the bottom of compact screens from iOS 26. On the
    /// outer container, not the list: the first typed letter swaps the list
    /// for the results, and a bar that went with it would take the focused
    /// search field along.
    private struct GroupListBottomBar: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            #if os(iOS)
            if #available(iOS 26.0, *), view.usesBottomToolbar, view.viewModel.workspace.entrySelection == nil {
                content
                    .toolbar {
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                        // New Group's sheet lives on the list, which search replaces.
                        if view.canCreateHere, view.viewModel.searchText.isEmpty, let group = view.resolvedGroup {
                            ToolbarSpacer(.fixed, placement: .bottomBar)
                            ToolbarItem(placement: .bottomBar) {
                                view.addMenu(in: group)
                            }
                        }
                    }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// Attaches the search field to every level, pushed ones included.
    private struct GroupListSearchModifier: ViewModifier {
        let view: GroupListView

        func body(content: Content) -> some View {
            // The system's default place from iOS 26 on: the bottom of the
            // screen on iPhone.
            if #available(iOS 26.0, *) {
                content
                    .searchable(text: view.$viewModel.searchText, prompt: "Search entries")
            } else {
                content
                    .searchable(
                        text: view.$viewModel.searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search entries"
                    )
            }
        }
    }

    /// What the large title's subtitle counts; nil on the root.
    private func subtitle(for group: KPGroup) -> String? {
        switch collection {
        case .allEntries:
            return allEntriesSummary
        case .verificationCodes:
            return String(localized: "\(viewModel.collectionCounts.verificationCodes) entries")
        case .tags:
            return String(localized: "\(viewModel.collectionCounts.tags) tags in this database")
        case .recycleBin:
            return String(localized: "\(viewModel.collectionCounts.recycleBin) items · not counted in All Entries")
        case nil:
            guard isRoot == false else { return nil }
            return SettingsSummaryText.joined([
                String(localized: "\(viewModel.entryCount(forGroupID: group.id)) entries"),
                visibleGroups.isEmpty ? nil : String(localized: "\(visibleGroups.count) subgroups"),
            ])
        }
    }

    /// The count under the large title from iOS 26. Earlier releases keep the
    /// All Entries summary as the list's footer.
    /// A subtitle would otherwise turn the automatic title inline; the design
    /// keeps list screens on a large title.
    private struct GroupListSubtitle: ViewModifier {
        let subtitle: String?
        let isTitlePinned: Bool

        func body(content: Content) -> some View {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                if let subtitle, isTitlePinned == false {
                    content
                        .navigationBarTitleDisplayMode(.large)
                        .navigationSubtitle(Text(subtitle))
                } else {
                    content
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    private var showsSummaryAsSubtitle: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    /// The root is titled after the database, a collection after itself, and
    /// a group level after its group.
    private func navigationTitle(for group: KPGroup) -> String {
        if isRoot {
            return viewModel.databaseDisplayName
        }
        return collection?.title ?? group.name
    }

    /// The iPad sidebar has no toolbar of its own for Sync Now, so it keeps
    /// the controls pinned above the list. On iPhone the root shows the sync
    /// status as a row and the bar's actions stay in the bar.
    private var pinsCloudTitle: Bool {
        #if os(iOS)
        return onSelectEntry != nil && CloudSyncControls.isVisible(for: viewModel)
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var browsingRows: some View {
        switch collection {
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
            if visibleGroups.isEmpty == false || visibleEntries.isEmpty == false,
               viewModel.isReadOnly == false {
                Section {
                } footer: {
                    Text("Touch and hold to restore or delete permanently.")
                }
            }
        case nil:
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
                systemImage: collection?.systemImage ?? "folder",
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
                systemImage: collection?.systemImage ?? "folder",
                description: Text(emptyDescription)
            )
        } else {
            Section {
                ForEach(viewModel.sortedEntries(entries)) { entry in
                    entryRow(for: entry, showsFolderPath: true, showsVerificationCode: showsVerificationCodes)
                }
            } footer: {
                if showsSummaryAsSubtitle == false {
                    Text(summary)
                        .accessibilityIdentifier("group-list.summary")
                }
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
        NavigationLink(value: DatabaseRoute.group(groupID)) {
            GroupRow(groupID: groupID, viewModel: viewModel, recycleBinDetail: recycleBinDetail(for: .group(groupID)))
        }
        .accessibilityIdentifier("group.navlink")
        .macHoverHighlight()
        .contextMenu {
            if canEditGroup(groupID) {
                Button("Edit Group") {
                    guard let editor = makeGroupEditor(groupID) else { return }
                    viewModel.workspace.present(.group(editor))
                }
                .accessibilityIdentifier("group-row.edit-context")
            }

            RestoreRowAction(item: .group(groupID), viewModel: viewModel) { pendingMove = $0 }

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
                .tint(Theme.State.danger)
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
            folderPath: showsFolderPath ? viewModel.folderPath(forEntryID: entry.id) : nil,
            recycleBinDetail: recycleBinDetail(for: .entry(entry.id))
        )
        HStack {
            if viewModel.workspace.entrySelection != nil {
                EntrySelectionRow(entryID: entry.id, viewModel: viewModel, identifier: "entry.navlink") {
                    row
                }
                .macHoverHighlight()
            } else {
                browsingEntryRow(for: entry, row: row, showsVerificationCode: showsVerificationCode)
            }
        }
    }

    private func browsingEntryRow(for entry: KPEntry, row: EntryRow, showsVerificationCode: Bool) -> some View {
        // A concrete row container lets List defer offscreen rows.
        HStack {
            if showsVerificationCode, let config = entry.totpConfig, let sessionKey = viewModel.sessionKey {
                VerificationCodeRow(
                    entry: entry,
                    customIconData: viewModel.customIconData(for: entry),
                    title: entry.title.isEmpty ? String(localized: "(untitled)") : entry.title,
                    detail: verificationCodeDetail(for: entry),
                    config: config,
                    sessionKey: sessionKey
                ) {
                    open(entry)
                }
            } else {
                // A button rather than a link: entry rows carry no chevron.
                Button {
                    open(entry)
                } label: {
                    row
                }
                .accessibilityIdentifier("entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
            EntryRowCopyActions(entry: entry, viewModel: viewModel)

            Divider()

            EntryRowDuplicateAction(entryID: entry.id, viewModel: viewModel) { editor in
                viewModel.workspace.present(.entry(editor))
            }

            EntryRowMoveAction(entryID: entry.id, viewModel: viewModel) { move in
                pendingMove = move
            }

            EntryRowChangeIconAction(entryID: entry.id, viewModel: viewModel) { change in
                pendingEntryIconChange = change
            }

            EntryRowSelectAction(entryID: entry.id, viewModel: viewModel)

            if viewModel.isReadOnly == false {
                Divider()

                Button(isRecycleBin ? "Delete Permanently" : "Delete", systemImage: "trash", role: .destructive) {
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
                .tint(Theme.State.danger)
                .accessibilityIdentifier("entry-row.delete-swipe")
            }
        }
    }

    /// Only the Recycle Bin screen lists items lying directly in the bin.
    private func recycleBinDetail(for item: DatabaseViewModel.RecycleBinItem) -> String? {
        guard collection == .recycleBin else { return nil }
        return viewModel.recycleBinOrigin(for: item)?.summary()
    }

    /// What tapping an entry row does in each shell: the regular-width
    /// workspace selects, the compact stack pushes.
    private func open(_ entry: KPEntry) {
        if let onSelectEntry {
            onSelectEntry(entry)
        } else {
            viewModel.workspace.navigationPath.append(.entry(entry.id))
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
        viewModel.isGroupInRecycleBin(groupID: groupID) ? String(localized: "Delete Permanently") : String(localized: "Delete")
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

/// Lock in a vault screen's bar. Compact bars are all icons; a text label
/// would be the odd wide one out.
struct DatabaseLockButton: View {
    let viewModel: DatabaseViewModel
    let isCompact: Bool

    var body: some View {
        Button {
            viewModel.lockRequest(manuallyTriggered: true)
        } label: {
            if isCompact {
                Image(systemName: "lock.fill")
            } else {
                Text("Lock")
            }
        }
        .accessibilityLabel("Lock")
        .accessibilityIdentifier("lock.button")
    }
}

extension ToolbarItemPlacement {
    /// An app built with the iOS 27 SDK folds trailing bar items into an
    /// overflow menu when the title needs their room — a long title that has
    /// scrolled inline is enough — which would put Lock behind it. The pinned
    /// placement keeps the items and truncates the title instead.
    static var databaseActions: ToolbarItemPlacement {
        #if compiler(>=6.4)
        #if os(iOS)
        if #available(iOS 27.0, *) {
            return .topBarPinnedTrailing
        }
        #endif
        #endif
        return .topBarTrailing
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
    /// A recycled group's origin and deletion date.
    var recycleBinDetail: String? = nil

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
                let entryCount = viewModel.entryCount(forGroupID: groupID)
                HStack(spacing: Theme.Spacing.iconText) {
                    GroupIconView(
                        iconID: group.iconID,
                        customIconData: viewModel.customIconData(for: group)
                    )
                    .frame(width: 28)

                    VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                        Text(group.name)
                            .font(.body)
                        if let recycleBinDetail, recycleBinDetail.isEmpty == false {
                            RecycleBinDetailText(text: recycleBinDetail)
                        }
                    }

                    Spacer(minLength: 4)

                    if isExcludedFromAutoFill {
                        Image(systemName: "key.slash")
                            .font(.footnote)
                            .foregroundStyle(Theme.labelSecondary)
                            .accessibilityLabel("Hidden from Search & AutoFill")
                            .accessibilityIdentifier("group-row.autofill-excluded")
                    }

                    Text(entryCount, format: .number)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.labelSecondary)
                        .accessibilityLabel(Text("\(entryCount) entries"))
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
    /// A recycled entry's origin and deletion date.
    var recycleBinDetail: String? = nil

    @ScaledMetric(relativeTo: .body) private var iconSize = Theme.Size.entryIcon

    var body: some View {
        if PlatformDesign.followsIOSDesign {
            designedRow
        } else {
            macRow
        }
    }

    private var title: String {
        entry.title.isEmpty ? String(localized: "(untitled)") : entry.title
    }

    private var designedRow: some View {
        HStack(spacing: Theme.Spacing.iconText) {
            FaviconEntryIconView(entry: entry, customIconData: customIconData, size: iconSize)

            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                Text(title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Color.primary)
                if !username.isEmpty {
                    Text(username)
                        .font(Theme.Font.subhead)
                        .foregroundStyle(Theme.labelSecondary)
                }
                if let folderPath, folderPath.isEmpty == false {
                    Text(folderPath)
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .accessibilityIdentifier("entry-row.folder")
                }
                if let recycleBinDetail, recycleBinDetail.isEmpty == false {
                    RecycleBinDetailText(text: recycleBinDetail)
                }
            }

            Spacer(minLength: 0)

            if entry.isExpired() {
                StatusBadge(text: String(localized: "Expired"), tone: .danger)
                    .accessibilityIdentifier("entry-row.expired")
            }

            if entry.hasPasskey {
                EntryRowBadge(systemImage: "person.badge.key.fill")
                    .accessibilityLabel("Has a passkey")
                    .accessibilityIdentifier("entry-row.passkey")
            }

            if entry.totpConfig != nil {
                EntryRowBadge(systemImage: "timer")
                    .accessibilityLabel("Has a verification code")
                    .accessibilityIdentifier("entry-row.totp")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var macRow: some View {
        HStack {
            FaviconView(url: entry.url, iconID: entry.iconID, size: 24, customIconData: customIconData)
                .frame(width: 28)

            VStack(alignment: .leading) {
                Text(title)
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
                Image(systemName: "clock")
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

/// "From Banking · Deleted yesterday" under a Recycle Bin row's name.
private struct RecycleBinDetailText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.footnote)
            .foregroundStyle(Theme.labelSecondary)
            .accessibilityIdentifier("recycle-bin.origin")
    }
}

/// A tinted circle on an entry row saying what the entry carries.
private struct EntryRowBadge: View {
    let systemImage: String

    @ScaledMetric(relativeTo: .caption) private var size = Theme.Size.badge

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(Theme.accentSoft, in: Circle())
    }
}
