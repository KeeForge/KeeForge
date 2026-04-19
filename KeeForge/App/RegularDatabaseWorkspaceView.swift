import AuthenticationServices
import SwiftUI
import UIKit

struct RegularDatabaseWorkspaceView: View {
    @Bindable var viewModel: DatabaseViewModel
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isDropboxReconnectInFlight = false
    @State private var showSettings = false
    @State private var activeEditor: EntryEditViewModel?
    @State private var pendingEntryDeletion: PendingEntryDeletion?

    struct PendingEntryDeletion: Identifiable {
        let entryID: UUID
        let sendToRecycleBin: Bool

        var id: String {
            "\(entryID.uuidString)-\(sendToRecycleBin)"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            RegularDatabaseContentColumn(
                viewModel: viewModel,
                pendingEntryDeletion: $pendingEntryDeletion
            )
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 360)

            Divider()

            RegularDatabaseDetailColumn(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if viewModel.isReadOnly {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Read-only database")
                        .accessibilityIdentifier("database.read-only-indicator")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                TextField("Search entries", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityLabel("Search entries")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isReadOnly == false {
                    Button {
                        beginEntryCreation()
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
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if let bannerText = viewModel.cloudSyncBannerText {
                    BannerLabel(
                        text: bannerText,
                        systemImage: "icloud",
                        foregroundStyle: .orange,
                        backgroundColor: Color.orange.opacity(0.12)
                    )
                }

                if viewModel.saveError?.isWriteScopeRequired == true {
                    CloudReauthBanner(
                        isReconnectInFlight: isDropboxReconnectInFlight,
                        onReconnect: beginDropboxReconnect
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
        .onChange(of: viewModel.saveError) { _, newValue in
            if let newValue {
                presentedSaveError = newValue
            }
        }
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
                set: { isPresented in
                    if isPresented == false {
                        viewModel.cancelLockRequest()
                    }
                }
            )
        ) {
            Button("Lock and Discard", role: .destructive) {
                let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
            }
            Button("Keep Editing", role: .cancel) {
                viewModel.cancelLockRequest()
            }
        } message: {
            Text("Your unsaved entry changes will be lost.")
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
        .sheet(
            isPresented: Binding(
                get: { activeEditor != nil },
                set: { isPresented in
                    if isPresented == false {
                        activeEditor = nil
                    }
                }
            )
        ) {
            if let activeEditor {
                NavigationStack {
                    EntryEditView(
                        formViewModel: activeEditor,
                        databaseViewModel: viewModel
                    ) { completion in
                        self.activeEditor = nil
                        if completion == .deleted {
                            viewModel.selectEntry(nil)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            DatabaseSettingsView(viewModel: viewModel)
        }
    }

    private func beginEntryCreation() {
        Task {
            let result = await viewModel.acknowledgeEditingIfNeeded()
            guard result == .acknowledged else { return }
            guard let targetGroupID = viewModel.selectedGroupID ?? viewModel.visibleRootGroupID else { return }
            activeEditor = EntryEditViewModel(createIn: targetGroupID)
        }
    }

    @MainActor
    private func beginDropboxReconnect() {
        guard isDropboxReconnectInFlight == false else { return }
        guard let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isDropboxReconnectInFlight = true
        Task { @MainActor in
            defer { isDropboxReconnectInFlight = false }

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
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
    }
}

private struct RegularGroupSidebar: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        List {
            if let rootGroup = viewModel.visibleRootGroup {
                Section("Groups") {
                    RegularGroupSidebarRows(
                        groups: [rootGroup],
                        level: 0,
                        viewModel: viewModel
                    )
                }
            } else {
                ContentUnavailableView(
                    "Vault Not Loaded",
                    systemImage: "lock.doc",
                    description: Text("Unlock a database to browse groups.")
                )
            }
        }
        .navigationTitle(viewModel.databaseDisplayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RegularGroupSidebarRows: View {
    let groups: [KPGroup]
    let level: Int
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        ForEach(viewModel.sortedGroups(groups)) { group in
            Button {
                viewModel.selectGroup(group.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: groupIconName(for: group))
                        .foregroundStyle(.tint)
                        .frame(width: 20)

                    Text(group.name)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text("\(viewModel.entryCount(forGroupID: group.id))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(level) * 14)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(group.id == viewModel.selectedGroupID ? Color.accentColor.opacity(0.16) : Color.clear)
            )

            if group.groups.isEmpty == false {
                RegularGroupSidebarRows(
                    groups: group.groups,
                    level: level + 1,
                    viewModel: viewModel
                )
            }
        }
    }

    private func groupIconName(for group: KPGroup) -> String {
        if viewModel.currentRootGroup?.recycleBinUUID == group.id {
            return "trash"
        }
        return group.systemIconName
    }
}

private struct RegularDatabaseContentColumn: View {
    @Bindable var viewModel: DatabaseViewModel
    @Binding var pendingEntryDeletion: RegularDatabaseWorkspaceView.PendingEntryDeletion?

    private var selectedGroup: KPGroup? {
        if let selectedGroupID = viewModel.selectedGroupID {
            return viewModel.group(withID: selectedGroupID)
        }
        if let visibleRootGroupID = viewModel.visibleRootGroupID {
            return viewModel.group(withID: visibleRootGroupID)
        }
        return nil
    }

    private var visibleGroups: [KPGroup] {
        selectedGroup?.groups ?? []
    }

    private var visibleEntries: [KPEntry] {
        selectedGroup?.entries ?? []
    }

    private var isRecycleBin: Bool {
        guard let selectedGroupID = selectedGroup?.id else { return false }
        return viewModel.currentRootGroup?.recycleBinUUID == selectedGroupID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RegularDatabaseContentHeader(
                title: contentTitle,
                subtitle: contentSubtitle
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            List {
                if viewModel.searchText.isEmpty {
                    if selectedGroup != nil {
                        if visibleGroups.isEmpty == false {
                            Section("Groups") {
                                ForEach(viewModel.sortedGroups(visibleGroups).map(\.id), id: \.self) { subgroupID in
                                    Button {
                                        viewModel.selectGroup(subgroupID)
                                    } label: {
                                        GroupRow(groupID: subgroupID, viewModel: viewModel)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("group.navlink")
                                }
                            }
                        }

                        if visibleEntries.isEmpty == false {
                            Section("Entries") {
                                ForEach(viewModel.sortedEntries(visibleEntries)) { entry in
                                    Button {
                                        viewModel.selectEntry(entry.id)
                                    } label: {
                                        EntryRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("entry.navlink")
                                    .contextMenu {
                                        if viewModel.isReadOnly == false {
                                            Button("Delete Permanently", role: .destructive) {
                                                pendingEntryDeletion = .init(
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
                                                pendingEntryDeletion = .init(
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
                    } else {
                        ContentUnavailableView(
                            "Group Unavailable",
                            systemImage: "folder.badge.questionmark",
                            description: Text("This group no longer exists in the current draft.")
                        )
                    }
                } else {
                    if viewModel.searchResults.isEmpty {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("No entries matched \"\(viewModel.searchText)\".")
                        )
                        .accessibilityIdentifier("search.no-results")
                    } else {
                        Section("Search Results") {
                            ForEach(viewModel.searchResults) { entry in
                                Button {
                                    viewModel.selectEntry(entry.id)
                                } label: {
                                    EntryRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search.entry.navlink")
                                .contextMenu {
                                    if viewModel.isReadOnly == false {
                                        Button("Delete Permanently", role: .destructive) {
                                            pendingEntryDeletion = .init(
                                                entryID: entry.id,
                                                sendToRecycleBin: false
                                            )
                                        }
                                        .accessibilityIdentifier("entry-row.delete-permanent")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if viewModel.isReadOnly == false {
                                        Button("Delete", role: .destructive) {
                                            pendingEntryDeletion = .init(
                                                entryID: entry.id,
                                                sendToRecycleBin: true
                                            )
                                        }
                                        .accessibilityIdentifier("entry-row.delete-swipe")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var contentTitle: String {
        if viewModel.searchText.isEmpty == false {
            return "Search"
        }
        return selectedGroup?.name ?? "Entries"
    }

    private var contentSubtitle: String? {
        guard viewModel.searchText.isEmpty else { return "Results" }
        if visibleEntries.isEmpty == false {
            return "Entries"
        }
        if visibleGroups.isEmpty == false {
            return "Groups"
        }
        return nil
    }
}

private struct RegularDatabaseContentHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RegularDatabaseDetailColumn: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        NavigationStack {
            if let selectedEntryID = viewModel.selectedEntryID {
                EntryDetailView(
                    entryID: selectedEntryID,
                    viewModel: viewModel,
                    onClose: {
                        viewModel.selectEntry(nil)
                    }
                )
            } else if viewModel.searchText.isEmpty {
                ContentUnavailableView(
                    "Select an Entry",
                    systemImage: "key.horizontal",
                    description: Text("Choose an entry to view or edit its details.")
                )
            } else {
                ContentUnavailableView(
                    "Search Results",
                    systemImage: "magnifyingglass",
                    description: Text("Select a matching entry to view its details.")
                )
            }
        }
    }
}
