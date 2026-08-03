import SwiftUI

struct AutoFillSearchView: View {
    let entries: [KPEntry]
    let searchEntries: [KPEntry]
    let possibleEntries: [KPEntry]
    let onSelect: (KPEntry) -> Void
    let onSelectPossible: (KPEntry) -> Void
    let onAddURLToPossible: (KPEntry) -> Void
    let onCancel: () -> Void
    let initialSearchText: String
    /// Non-nil only when the coordinator offers the in-search database
    /// switcher (two or more AutoFill-enabled databases). Selecting a
    /// database other than the currently open one invokes
    /// `databaseSwitcher.onSwitch` with it and the current search text;
    /// selecting the currently open (checkmarked) database does nothing.
    let databaseSwitcher: CredentialProviderDatabaseSwitcherContext?

    @State private var searchText: String
    @State private var didEditSearch = false
    @State private var showsAllEntries = false
    @State private var entryPendingURLAddition: KPEntry?

    init(
        entries: [KPEntry],
        searchEntries: [KPEntry]? = nil,
        possibleEntries: [KPEntry] = [],
        initialSearchText: String = "",
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext? = nil,
        onSelect: @escaping (KPEntry) -> Void,
        onSelectPossible: @escaping (KPEntry) -> Void = { _ in },
        onAddURLToPossible: @escaping (KPEntry) -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        self.entries = entries
        self.searchEntries = searchEntries ?? entries
        self.possibleEntries = possibleEntries
        self.initialSearchText = initialSearchText
        self.databaseSwitcher = databaseSwitcher
        self.onSelect = onSelect
        self.onSelectPossible = onSelectPossible
        self.onAddURLToPossible = onAddURLToPossible
        self.onCancel = onCancel
        self._searchText = State(initialValue: initialSearchText)
    }

    private var filteredEntries: [KPEntry] {
        guard !searchText.isEmpty else {
            return didEditSearch || showsAllEntries ? searchEntries : entries
        }
        let query = searchText.lowercased()
        return searchEntries.filter { entry in
            entry.title.lowercased().contains(query) ||
            entry.username.lowercased().contains(query) ||
            entry.url.lowercased().contains(query) ||
            entry.notes.lowercased().contains(query)
        }
    }

    /// Whether the picker is narrowed to matches — or to a domain search the
    /// coordinator pre-filled — while further credentials sit behind it. A
    /// request whose matching found nothing lands on that pre-filled search
    /// with an empty list, so without this the full database is reachable
    /// only by clearing a search field the user never typed into.
    private var canShowAllEntries: Bool {
        guard !showsAllEntries, !didEditSearch, !searchEntries.isEmpty else { return false }
        return filteredEntries.count + possibleEntries.count < searchEntries.count
    }

    private func showAllEntries() {
        searchText = ""
        showsAllEntries = true
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredEntries.isEmpty && searchText.isEmpty && !possibleEntries.isEmpty {
                    Section {
                        Text("No exact matches were found. These credentials are possible matches only.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("autofill.possible-matches.explanation")
                    }
                }
                if filteredEntries.isEmpty && filteredPossibleEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No Credentials Found", systemImage: "magnifyingglass")
                            .accessibilityIdentifier("autofill.no-credentials-found")
                    } description: {
                        Text("No credentials match this search.")
                    } actions: {
                        if canShowAllEntries {
                            Button("Show All Credentials", action: showAllEntries)
                                .accessibilityIdentifier("autofill.show-all-entries.empty-state")
                        }
                    }
                }
                Section {
                    ForEach(filteredEntries) { entry in
                        Button { onSelect(entry) } label: { entryRow(entry) }
                            .accessibilityIdentifier("autofill.entry.exact")
                    }
                } header: {
                    if !filteredEntries.isEmpty { Text("Matches") }
                }
                if !possibleEntries.isEmpty {
                    Section("Possible matches") {
                        ForEach(filteredPossibleEntries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { onSelectPossible(entry) } label: { entryRow(entry) }
                                    .accessibilityIdentifier("autofill.entry.possible.use")
                                Button("Add original URL to this entry") { entryPendingURLAddition = entry }
                                    .font(.caption)
                                    .accessibilityIdentifier("autofill.entry.possible.add-url")
                            }
                        }
                    }
                }
                // Only when something is already listed; the empty state
                // carries its own copy of this action.
                if canShowAllEntries, !filteredEntries.isEmpty || !filteredPossibleEntries.isEmpty {
                    Section {
                        Button(action: showAllEntries) {
                            Label("Show All Credentials", systemImage: "list.bullet")
                        }
                        .accessibilityIdentifier("autofill.show-all-entries")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search entries")
            .onChange(of: searchText) { _, _ in
                didEditSearch = true
            }
            .navigationTitle("Choose Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                if let databaseSwitcher {
                    ToolbarItem(placement: .primaryAction) { databaseSwitcherMenu(databaseSwitcher) }
                }
            }
        }
        .alert("Add Original URL?", isPresented: Binding(
            get: { entryPendingURLAddition != nil },
            set: { if !$0 { entryPendingURLAddition = nil } }
        )) {
            Button("Add URL") {
                if let entry = entryPendingURLAddition { onAddURLToPossible(entry) }
                entryPendingURLAddition = nil
            }
            Button("Cancel", role: .cancel) { entryPendingURLAddition = nil }
        } message: {
            Text("This adds the original request URL to the selected credential. The database will be changed only if you confirm.")
        }
    }

    private var filteredPossibleEntries: [KPEntry] {
        guard !searchText.isEmpty else { return possibleEntries }
        let query = searchText.lowercased()
        return possibleEntries.filter { entry in
            entry.title.lowercased().contains(query) || entry.username.lowercased().contains(query) || entry.url.lowercased().contains(query) || entry.notes.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: KPEntry) -> some View {
        HStack {
                        Image(systemName: entry.systemIconName)
                            .foregroundStyle(.tint)
                            .font(.system(size: 16))
                            .frame(width: 28)

                        VStack(alignment: .leading) {
                            Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if !entry.username.isEmpty {
                                Text(entry.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if entry.isExpired() {
                            Label("Expired", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("autofill.entry.expired")
                        }
        }
    }

    /// Lightweight per-database picker: lists AutoFill-enabled databases only,
    /// marks the currently open one with a checkmark, and hands taps on any
    /// other database to the coordinator (with the live search text so the
    /// re-presented search can keep it). Tapping the current database is a
    /// no-op at the view level so the shells never dismiss the search view
    /// for a switch the coordinator would ignore.
    private func databaseSwitcherMenu(_ databaseSwitcher: CredentialProviderDatabaseSwitcherContext) -> some View {
        Menu {
            ForEach(databaseSwitcher.databases) { database in
                Button {
                    guard database.id != databaseSwitcher.currentDatabaseID else { return }
                    databaseSwitcher.onSwitch(database, searchText)
                } label: {
                    if database.id == databaseSwitcher.currentDatabaseID {
                        Label(database.displayName, systemImage: "checkmark")
                    } else {
                        Text(database.displayName)
                    }
                }
                .accessibilityIdentifier("autofill.database-switcher.\(database.id.uuidString)")
            }
        } label: {
            Label("Switch Database", systemImage: "cylinder.split.1x2")
        }
        .accessibilityIdentifier("autofill.database-switcher")
    }
}

/// Empty state shown when no database participates in AutoFill (every
/// database disabled, or none registered): tells the user to turn on
/// AutoFill for a database in KeeForge's settings. Shared by both extension
/// shells; dismissing is the only action and cancels the request.
struct AutoFillNoEnabledDatabasesView: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No Databases for AutoFill", systemImage: "lock.slash")
                    .accessibilityIdentifier("autofill.no-enabled-databases")
            } description: {
                Text("Turn on AutoFill for a database in KeeForge’s settings to use it here.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .accessibilityIdentifier("autofill.no-enabled-databases.cancel")
                }
            }
        }
    }
}
