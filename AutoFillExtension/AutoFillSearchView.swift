import SwiftUI

struct AutoFillSearchView: View {
    let entries: [KPEntry]
    let onSelect: (KPEntry) -> Void
    let onCancel: () -> Void
    let initialSearchText: String
    /// Non-nil only when the coordinator offers the in-search database
    /// switcher (two or more AutoFill-enabled databases). Selecting a
    /// database other than the currently open one invokes
    /// `databaseSwitcher.onSwitch` with it and the current search text;
    /// selecting the currently open (checkmarked) database does nothing.
    let databaseSwitcher: CredentialProviderDatabaseSwitcherContext?

    @State private var searchText: String

    init(
        entries: [KPEntry],
        initialSearchText: String = "",
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext? = nil,
        onSelect: @escaping (KPEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entries = entries
        self.initialSearchText = initialSearchText
        self.databaseSwitcher = databaseSwitcher
        self.onSelect = onSelect
        self.onCancel = onCancel
        self._searchText = State(initialValue: initialSearchText)
    }

    private var filteredEntries: [KPEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            entry.title.lowercased().contains(query) ||
            entry.username.lowercased().contains(query) ||
            entry.url.lowercased().contains(query) ||
            entry.notes.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    HStack {
                        Image(systemName: entry.systemIconName)
                            .foregroundStyle(.tint)
                            .font(.system(size: 16))
                            .frame(width: 28)

                        VStack(alignment: .leading) {
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
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
            }
            .searchable(text: $searchText, prompt: "Search entries")
            .navigationTitle("Choose Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                if let databaseSwitcher {
                    ToolbarItem(placement: .primaryAction) {
                        databaseSwitcherMenu(databaseSwitcher)
                    }
                }
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
