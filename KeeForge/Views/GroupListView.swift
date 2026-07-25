import SwiftUI

struct GroupListView: View {
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

    let groupID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onSelectEntry: ((KPEntry) -> Void)? = nil
    /// macOS drill-down: when set, group rows call this instead of pushing a
    /// `NavigationLink` (pushed sidebar stacks render zero-height on macOS).
    var onSelectGroup: ((UUID) -> Void)? = nil
    /// macOS drill-down: when set, a Back toolbar button pops one level.
    var onNavigateBack: (() -> Void)? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showSettings = false
    @State private var activeEditor: EntryEditViewModel?
    @State private var pendingDeletion: PendingDeletion?
    @State private var isShowingNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var groupCreationErrorMessage: String?
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
                                "Empty Group",
                                systemImage: "folder",
                                description: Text("This group has no entries.")
                            )
                        }
                    }
                    .navigationTitle(resolvedGroup.name)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        if let onNavigateBack {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    onNavigateBack()
                                } label: {
                                    Image(systemName: "chevron.backward")
                                }
                                .accessibilityLabel("Back")
                                .accessibilityIdentifier("group.back")
                            }
                        }

                        if showsCompactLockButton {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Lock") {
                                    viewModel.lockRequest(manuallyTriggered: true)
                                }
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
                                            Task {
                                                let result = await viewModel.acknowledgeEditingIfNeeded()
                                                guard result == .acknowledged else { return }
                                                activeEditor = EntryEditViewModel(createIn: resolvedGroup.id)
                                            }
                                        }

                                        Button("New Group", systemImage: "folder.badge.plus") {
                                            Task {
                                                let result = await viewModel.acknowledgeEditingIfNeeded()
                                                guard result == .acknowledged else { return }
                                                newGroupName = ""
                                                isShowingNewGroupSheet = true
                                            }
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
                        DatabaseSettingsView(viewModel: viewModel)
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
                    .alert(item: $pendingDeletion, content: deletionAlert)
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
                    EntryRow(entry: entry, customIconData: viewModel.customIconData(for: entry))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry.navlink")
            } else {
                NavigationLink(value: entry) {
                    EntryRow(entry: entry, customIconData: viewModel.customIconData(for: entry))
                }
                .accessibilityIdentifier("entry.navlink")
            }
        }
        .macHoverHighlight()
        .contextMenu {
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

    private func canChangeAutoFillExclusion(_ groupID: UUID) -> Bool {
        viewModel.isReadOnly == false
            && viewModel.currentRootGroup?.recycleBinUUID != groupID
            && viewModel.isGroupInRecycleBin(groupID: groupID) == false
    }

    private func autoFillExclusionButtonTitle(for groupID: UUID) -> String {
        if viewModel.isGroupExcludedFromAutoFill(groupID: groupID) {
            return viewModel.isGroupExclusionInherited(groupID: groupID)
                ? String(localized: "Show in AutoFill (Overrides Parent)")
                : String(localized: "Show in AutoFill")
        }
        return String(localized: "Hide from AutoFill")
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
        guard let summary = viewModel.groupDeletionSummary(forGroupID: groupID) else { return }
        pendingDeletion = .group(
            PendingGroupDeletion(
                groupID: groupID,
                groupName: summary.name,
                entryCount: summary.entryCount,
                nestedGroupCount: summary.nestedGroupCount,
                sendToRecycleBin: viewModel.isGroupInRecycleBin(groupID: groupID) == false
            )
        )
    }

    private func deletionAlert(for deletion: PendingDeletion) -> Alert {
        switch deletion {
        case .entry(let action):
            Alert(
                title: Text(action.sendToRecycleBin ? "Delete Entry?" : "Delete Permanently?"),
                message: Text(action.sendToRecycleBin
                    ? "The entry will be moved to the recycle bin."
                    : "This entry will be removed immediately and cannot be restored from KeeForge."),
                primaryButton: .destructive(Text(action.sendToRecycleBin ? "Delete" : "Delete Permanently")) {
                    do {
                        try viewModel.deleteEntry(action.entryID, sendToRecycleBin: action.sendToRecycleBin)
                        Task {
                            await viewModel.saveHandlingError()
                        }
                    } catch {
                        viewModel.presentSaveError(error)
                    }
                },
                secondaryButton: .cancel()
            )

        case .group(let action):
            Alert(
                title: Text(action.sendToRecycleBin ? "Delete Group?" : "Delete Permanently?"),
                message: Text(groupDeletionMessage(for: action)),
                primaryButton: .destructive(Text(action.sendToRecycleBin ? "Delete" : "Delete Permanently")) {
                    do {
                        try viewModel.deleteGroup(action.groupID, sendToRecycleBin: action.sendToRecycleBin)
                        Task {
                            await viewModel.saveHandlingError()
                        }
                    } catch {
                        viewModel.presentSaveError(error)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func groupDeletionMessage(for action: PendingGroupDeletion) -> String {
        let contents = "\(entryCountText(action.entryCount)) and \(nestedGroupCountText(action.nestedGroupCount))"
        if action.sendToRecycleBin {
            return String(localized: "\"\(action.groupName)\" contains \(contents). The group and its contents will be moved to the recycle bin.")
        }
        return String(localized: "\"\(action.groupName)\" contains \(contents). The group and its contents will be removed immediately and cannot be restored from KeeForge.")
    }

    private func entryCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 entry")
            : String(localized: "\(count) entries")
    }

    private func nestedGroupCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 nested group")
            : String(localized: "\(count) nested groups")
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

    private var isExcludedFromAutoFill: Bool {
        isRecycleBin == false && viewModel.isGroupExcludedFromAutoFill(groupID: groupID)
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
                            .accessibilityLabel("Hidden from AutoFill")
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
    var customIconData: Data? = nil

    var body: some View {
        HStack {
            FaviconView(url: entry.url, iconID: entry.iconID, size: 24, customIconData: customIconData)
                .frame(width: 28)

            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                    .font(.body)
                if !entry.username.isEmpty {
                    Text(entry.username)
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
            }

            if entry.totpConfig != nil {
                Image(systemName: "clock.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct DatabaseSettingsView: View {
    @Bindable var viewModel: DatabaseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var isQuickLaunch = false
    @State private var showKeyFilePicker = false
    @State private var showAppSettings = false

    private var reference: DatabaseReference {
        viewModel.databaseReference
    }

    private var currentReference: DatabaseReference {
        DatabaseListStore.databases.first(where: { $0.id == reference.id }) ?? reference
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: currentDisplayName)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Name")
                        TextField("Use filename", text: $nickname)
                            .textInputAutocapitalization(.words)
                            .onSubmit(saveNickname)
                    }

                    LabeledContent("Filename", value: currentReference.filename)

                    Toggle("Quick Launch", isOn: $isQuickLaunch)
                        .onChange(of: isQuickLaunch) { _, newValue in
                            let currentValue = currentReference.isQuickLaunch
                            guard newValue != currentValue else { return }
                            toggleQuickLaunch(newValue)
                            isQuickLaunch = currentReference.isQuickLaunch
                        }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Quick Launch opens this database automatically on app launch.")
                }

                Section {
                    Toggle(
                        "Read-only",
                        isOn: Binding(
                            get: { viewModel.isReadOnly },
                            set: { viewModel.setReadOnly($0) }
                        )
                    )
                    .disabled(viewModel.isFormatReadOnly)
                    .accessibilityIdentifier("database-settings.read-only-toggle")
                } header: {
                    Text("Editing")
                } footer: {
                    Text(
                        viewModel.isFormatReadOnly
                            ? "Legacy KDBX 3.1 databases can be opened, but KeeForge intentionally keeps them read-only."
                            : "Keep this database openable but block create, edit, and delete actions until you turn editing back on."
                    )
                }

                Section("Key File") {
                    LabeledContent("Associated File", value: currentReference.keyFileFilename ?? "None")

                    Button("Select Key File") {
                        showKeyFilePicker = true
                    }

                    if currentReference.keyFileFilename != nil {
                        Button("Clear Key File", role: .destructive) {
                            setKeyFile(url: nil)
                        }
                    }
                }

                Section("Metadata") {
                    LabeledContent("Added", value: dateText(currentReference.addedAt))

                    if let lastOpenedAt = currentReference.lastOpenedAt {
                        LabeledContent("Last Opened", value: dateText(lastOpenedAt))
                    }
                }

                if let metadata = currentReference.cloudSyncMetadata {
                    Section {
                        LabeledContent("Provider") {
                            HStack(spacing: 6) {
                                CloudProviderIcon(provider: metadata.providerKind)
                                Text(metadata.providerKind?.displayName ?? metadata.provider)
                            }
                            .lineLimit(1)
                        }

                        LabeledContent("Path") {
                            Text(metadata.displayPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.trailing)
                        }

                        if let remoteModifiedAt = metadata.remoteModifiedAt {
                            LabeledContent("Remote Modified", value: dateText(remoteModifiedAt))
                        }

                        if let lastSyncedAt = metadata.lastSyncedAt {
                            LabeledContent("Last Sync", value: dateText(lastSyncedAt))
                        }
                    } header: {
                        Text("Cloud Sync")
                    }
                }

                Section {
                    #if os(macOS)
                    SettingsLink {
                        Text("App Settings")
                    }
                    #else
                    Button("App Settings") {
                        showAppSettings = true
                    }
                    #endif
                }
            }
            .navigationTitle("Database Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                syncFormStateFromCurrentReference()
            }
            .onChange(of: currentReference.nickname) { _, _ in
                syncFormStateFromCurrentReference()
            }
            .onChange(of: nickname) { _, _ in
                saveNickname()
            }
            .onChange(of: currentReference.isQuickLaunch) { _, newValue in
                isQuickLaunch = newValue
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveNickname()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showKeyFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    setKeyFile(url: url)
                }
            }
            .sheet(isPresented: $showAppSettings) {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    private func syncFormStateFromCurrentReference() {
        nickname = currentReference.nickname ?? ""
        isQuickLaunch = currentReference.isQuickLaunch
    }

    private func saveNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNickname = trimmed.isEmpty ? nil : trimmed
        guard newNickname != currentReference.nickname else { return }
        viewModel.setNickname(newNickname)
    }

    private func toggleQuickLaunch(_ newValue: Bool) {
        // Clear Quick Launch from any other database first
        if newValue {
            for database in DatabaseListStore.databases where database.id != reference.id && database.isQuickLaunch {
                var updated = database
                updated.isQuickLaunch = false
                DatabaseListStore.update(updated)
            }
        }
        guard var updated = DatabaseListStore.databases.first(where: { $0.id == reference.id }) else { return }
        updated.isQuickLaunch = newValue
        DatabaseListStore.update(updated)
    }

    private func setKeyFile(url: URL?) {
        guard var updated = DatabaseListStore.databases.first(where: { $0.id == reference.id }) else { return }
        if let url {
            guard let bookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: url) else { return }
            updated.keyFileBookmarkData = bookmarkData
            updated.keyFileFilename = url.lastPathComponent
        } else {
            updated.keyFileBookmarkData = nil
            updated.keyFileFilename = nil
        }
        DatabaseListStore.update(updated)
    }

    private var currentDisplayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? currentReference.displayName : trimmed
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
