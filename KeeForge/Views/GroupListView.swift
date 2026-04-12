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
                        SettingsView(viewModel: viewModel)
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

    var body: some View {
        Group {
            if let group {
                HStack {
                    Image(systemName: group.systemIconName)
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
