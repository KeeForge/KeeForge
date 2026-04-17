import SwiftUI

struct GroupListView: View {
    struct PendingEntryDeletion: Identifiable {
        let entryID: UUID
        let sendToRecycleBin: Bool

        var id: String {
            "\(entryID.uuidString)-\(sendToRecycleBin)"
        }
    }

    let groupID: UUID
    @Bindable var viewModel: DatabaseViewModel
    @State private var showSettings = false
    @State private var activeEditor: EntryEditViewModel?
    @State private var pendingEntryDeletion: PendingEntryDeletion?

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

    var body: some View {
        Group {
            if viewModel.searchText.isEmpty {
                if let resolvedGroup {
                    List {
                        if !visibleGroups.isEmpty {
                            Section("Groups") {
                                ForEach(viewModel.sortedGroups(visibleGroups).map(\.id), id: \.self) { subgroupID in
                                    NavigationLink(value: subgroupID) {
                                        GroupRow(groupID: subgroupID, viewModel: viewModel)
                                    }
                                    .accessibilityIdentifier("group.navlink")
                                }
                            }
                        }

                        if !visibleEntries.isEmpty {
                            Section("Entries") {
                                ForEach(viewModel.sortedEntries(visibleEntries)) { entry in
                                    NavigationLink(value: entry) {
                                        EntryRow(entry: entry)
                                    }
                                    .accessibilityIdentifier("entry.navlink")
                                    .contextMenu {
                                        if viewModel.isReadOnly == false {
                                            Button("Delete Permanently", role: .destructive) {
                                                pendingEntryDeletion = PendingEntryDeletion(
                                                    entryID: entry.id,
                                                    sendToRecycleBin: false
                                                )
                                            }
                                            .accessibilityIdentifier("entry-row.delete-permanent")
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if viewModel.isReadOnly == false {
                                            Button(isRecycleBin ? "Delete Permanently" : "Delete", role: .destructive) {
                                                pendingEntryDeletion = PendingEntryDeletion(
                                                    entryID: entry.id,
                                                    sendToRecycleBin: !isRecycleBin
                                                )
                                            }
                                            .accessibilityIdentifier("entry-row.delete-swipe")
                                        }
                                    }
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
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 12) {
                                if viewModel.isReadOnly {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Read-only database")
                                        .accessibilityIdentifier("database.read-only-indicator")
                                }

                                if viewModel.isReadOnly == false {
                                    Button {
                                        Task {
                                            let result = await viewModel.acknowledgeEditingIfNeeded()
                                            guard result == .acknowledged else { return }
                                            activeEditor = EntryEditViewModel(createIn: resolvedGroup.id)
                                        }
                                    } label: {
                                        Image(systemName: "plus")
                                    }
                                    .accessibilityIdentifier("entry-list.add-entry")
                                }

                                Button {
                                    viewModel.lockRequest(manuallyTriggered: true)
                                } label: {
                                    Image(systemName: "lock")
                                }
                                .accessibilityIdentifier("lock.button")

                                Menu {
                                    Picker("Sort By", selection: $viewModel.sortOrder) {
                                        ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                                            Text(order.rawValue).tag(order)
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
                    .alert(item: $pendingEntryDeletion) { action in
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
                    }
                } else {
                    ContentUnavailableView(
                        "Group Unavailable",
                        systemImage: "folder.badge.questionmark",
                        description: Text("This group no longer exists in the current draft.")
                    )
                }
            } else {
                SearchView(viewModel: viewModel)
            }
        }
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search entries"
        )
        .navigationDestination(item: $activeEditor) { formViewModel in
            EntryEditView(
                formViewModel: formViewModel,
                databaseViewModel: viewModel
            ) { _ in
                activeEditor = nil
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

    var body: some View {
        Group {
            if let group {
                HStack {
                    Image(systemName: isRecycleBin ? "trash" : group.systemIconName)
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading) {
                        Text(group.name)
                            .font(.body)
                        Text("\(group.allEntries.count) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct EntryRow: View {
    let entry: KPEntry

    var body: some View {
        HStack {
            FaviconView(url: entry.url, iconID: entry.iconID, size: 24)
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

            if SettingsService.passkeyEnabled && entry.hasPasskey {
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

                    LabeledContent("Custom Name") {
                        TextField("Use filename", text: $nickname)
                            .multilineTextAlignment(.trailing)
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
                                CloudProviderIcon(provider: metadata.providerKind, size: 16)
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
                    Button("App Settings") {
                        showAppSettings = true
                    }
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
        guard var updated = DatabaseListStore.databases.first(where: { $0.id == reference.id }) else { return }
        updated.nickname = newNickname
        DatabaseListStore.update(updated)
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
        return trimmed.isEmpty ? reference.displayName : trimmed
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
