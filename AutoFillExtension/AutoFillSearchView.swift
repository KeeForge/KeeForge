import SwiftUI

struct AutoFillSearchView: View {
    let entries: [KPEntry]
    let searchEntries: [KPEntry]
    let possibleEntries: [KPEntry]
    let onSelect: (KPEntry) -> Void
    let onSelectPossible: (KPEntry) -> Void
    /// Nil when the database cannot be written (read-only or KDBX 3.1) or
    /// the request names no website, which hides the add-website action.
    let urlAddition: AutoFillURLAddition?
    let onCancel: () -> Void
    let initialSearchText: String
    /// When the entries come from KeeForge's shared copy of the database
    /// rather than the file itself, when that copy was last brought up to date.
    let sharedCopyDate: Date?
    /// Non-nil only when the coordinator offers in-extension entry creation
    /// (iOS password requests against a writable database). Nil hides both
    /// entry points, so passkey/one-time-code pickers stay selection-only.
    let onCreateEntry: (() -> Void)?
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
    @ScaledMetric(relativeTo: .body) private var entryIconSize = Theme.Size.entryIcon

    init(
        entries: [KPEntry],
        searchEntries: [KPEntry]? = nil,
        possibleEntries: [KPEntry] = [],
        initialSearchText: String = "",
        sharedCopyDate: Date? = nil,
        databaseSwitcher: CredentialProviderDatabaseSwitcherContext? = nil,
        onCreateEntry: (() -> Void)? = nil,
        onSelect: @escaping (KPEntry) -> Void,
        onSelectPossible: @escaping (KPEntry) -> Void = { _ in },
        urlAddition: AutoFillURLAddition? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.entries = entries
        self.searchEntries = searchEntries ?? entries
        self.possibleEntries = possibleEntries
        self.initialSearchText = initialSearchText
        self.sharedCopyDate = sharedCopyDate
        self.databaseSwitcher = databaseSwitcher
        self.onCreateEntry = onCreateEntry
        self.onSelect = onSelect
        self.onSelectPossible = onSelectPossible
        self.urlAddition = urlAddition
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
            #if os(macOS)
            VStack(spacing: 0) {
                macHeader
                entryList
                AutoFillMacFooter {
                    Button("Cancel") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("autofill.cancel")
                }
            }
            #else
            entryList
                .searchable(text: $searchText, prompt: "Search entries")
                .navigationTitle("Choose Credential")
                .modifier(AutoFillPickerTitleStyle(service: initialSearchText))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                            .accessibilityIdentifier("autofill.cancel")
                    }
                    if let databaseSwitcher {
                        ToolbarItem(placement: .primaryAction) { databaseSwitcherMenu(databaseSwitcher) }
                    }
                    if let onCreateEntry {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: onCreateEntry) {
                                Label("Create New Credential", systemImage: "plus")
                            }
                            .accessibilityIdentifier("autofill.create-entry")
                        }
                    }
                }
            #endif
        }
        .alert("Add Website to Entry?", isPresented: Binding(
            get: { entryPendingURLAddition != nil },
            set: { if !$0 { entryPendingURLAddition = nil } }
        )) {
            Button("Add Website") {
                if let entry = entryPendingURLAddition { urlAddition?.onAdd(entry) }
                entryPendingURLAddition = nil
            }
            Button("Cancel", role: .cancel) { entryPendingURLAddition = nil }
        } message: {
            if let entry = entryPendingURLAddition, let urlAddition {
                Text(urlAdditionMessage(for: entry, addition: urlAddition))
            }
        }
    }

    /// Names the exact host next to the entry's saved URLs, and cautions
    /// when the host is unrelated to all of them.
    private func urlAdditionMessage(for entry: KPEntry, addition: AutoFillURLAddition) -> String {
        let title = entry.title.isEmpty ? String(localized: "(untitled)") : entry.title
        var parts = [String(localized: "This adds “\(addition.host)” to “\(title)” so AutoFill suggests the entry on that website next time. Check the address before adding it.")]
        let savedURLs = addition.savedURLs(of: entry)
        if savedURLs.isEmpty {
            parts.append(String(localized: "This entry has no saved websites yet."))
        } else {
            parts.append(([String(localized: "Saved websites:")] + savedURLs).joined(separator: "\n"))
            if !addition.sharesRegistrableDomain(with: entry) {
                parts.append(String(localized: "Caution: “\(addition.host)” isn’t related to any website saved in this entry. If it’s a lookalike site, adding it lets AutoFill offer this password there."))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    #if os(macOS)
    /// Stands in for the navigation bar and `.searchable` field macOS drops
    /// (see `AutoFillMacChrome.swift`).
    private var macHeader: some View {
        AutoFillMacHeader {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text("Choose Credential")
                        .font(.headline)
                    Spacer()
                    if let databaseSwitcher {
                        databaseSwitcherMenu(databaseSwitcher)
                            .fixedSize()
                    }
                }
                TextField("Search entries", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("autofill.search-field")
            }
        }
    }
    #endif

    private var entryList: some View {
        List {
            if filteredEntries.isEmpty && searchText.isEmpty && !possibleEntries.isEmpty {
                Section {
                    Text("No exact matches were found. These credentials are possible matches only.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("autofill.possible-matches.explanation")
                }
            }
            Section {
                ForEach(filteredEntries) { entry in
                    if let urlAddition, !urlAddition.isStored(on: entry) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button { onSelect(entry) } label: { entryRow(entry) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("autofill.entry.exact")
                            addURLButton(for: entry, host: urlAddition.host)
                                .accessibilityIdentifier("autofill.entry.add-url")
                        }
                    } else {
                        Button { onSelect(entry) } label: { entryRow(entry) }
                            .accessibilityIdentifier("autofill.entry.exact")
                    }
                }
            } header: {
                if !filteredEntries.isEmpty { Text("Matches") }
            }
            if !filteredPossibleEntries.isEmpty {
                Section("Possible matches") {
                    ForEach(filteredPossibleEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { onSelectPossible(entry) } label: { entryRow(entry) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("autofill.entry.possible.use")
                            if let urlAddition, !urlAddition.isStored(on: entry) {
                                addURLButton(for: entry, host: urlAddition.host)
                                    .accessibilityIdentifier("autofill.entry.possible.add-url")
                            }
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
        // As an overlay, not a List row: buttons in a row share one tap
        // target that fires every action, always landing on the last.
        .overlay {
            if filteredEntries.isEmpty && filteredPossibleEntries.isEmpty {
                noCredentialsFoundView
            }
        }
        .onChange(of: searchText) { _, _ in
            didEditSearch = true
        }
    }

    @ViewBuilder
    private var noCredentialsFoundView: some View {
        if PlatformDesign.followsIOSDesign {
            designedNoCredentialsFoundView
        } else {
            ContentUnavailableView {
                noCredentialsFoundLabel
            } description: {
                VStack(spacing: 8) {
                    Text("No credentials match this search.")
                    if let sharedCopyDate {
                        sharedCopyNotice(sharedCopyDate)
                    }
                }
            } actions: {
                if canShowAllEntries {
                    Button("Show All Credentials", action: showAllEntries)
                        .accessibilityIdentifier("autofill.show-all-entries.empty-state")
                }
                if let onCreateEntry {
                    Button("Create New Credential", action: onCreateEntry)
                        .accessibilityIdentifier("autofill.create-entry.empty-state")
                }
            }
        }
    }

    /// The database list's empty state: one prominent action, the other bordered,
    /// and the shared-copy note under them in small type.
    private var designedNoCredentialsFoundView: some View {
        ContentUnavailableView {
            noCredentialsFoundLabel
        } description: {
            Text("No credentials match this search.")
        } actions: {
            VStack(spacing: Theme.Spacing.tileGap) {
                if canShowAllEntries {
                    Button(action: showAllEntries) {
                        Label("Show All Credentials", systemImage: "list.bullet")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("autofill.show-all-entries.empty-state")
                }
                if let onCreateEntry {
                    if canShowAllEntries {
                        createCredentialButton(onCreateEntry)
                            .buttonStyle(.bordered)
                    } else {
                        createCredentialButton(onCreateEntry)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let sharedCopyDate {
                    Label {
                        sharedCopyNotice(sharedCopyDate)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, Theme.Spacing.tileGap)
                }
            }
        }
    }

    private func createCredentialButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Create New Credential", systemImage: "plus")
        }
        .controlSize(.large)
        .accessibilityIdentifier("autofill.create-entry.empty-state")
    }

    private var noCredentialsFoundLabel: some View {
        Label("No Credentials Found", systemImage: "magnifyingglass")
            .accessibilityIdentifier("autofill.no-credentials-found")
    }

    private func sharedCopyNotice(_ date: Date) -> some View {
        Text("Searched KeeForge’s copy of this database from \(date.formatted(date: .abbreviated, time: .shortened)). To find newer credentials, unlock this database in KeeForge. For cloud databases, use Sync Now in Database Details.")
            .accessibilityIdentifier("autofill.shared-copy-notice")
    }

    private var filteredPossibleEntries: [KPEntry] {
        guard !searchText.isEmpty else { return possibleEntries }
        let query = searchText.lowercased()
        return possibleEntries.filter { entry in
            entry.title.lowercased().contains(query) || entry.username.lowercased().contains(query) || entry.url.lowercased().contains(query) || entry.notes.lowercased().contains(query)
        }
    }

    /// Borderless, like the row's selection button beside it: two
    /// default-style buttons in one List row share a tap target.
    private func addURLButton(for entry: KPEntry, host: String) -> some View {
        Button {
            entryPendingURLAddition = entry
        } label: {
            Label("Add \(host) to this entry", systemImage: "link.badge.plus")
        }
        .buttonStyle(.borderless)
        .font(PlatformDesign.followsIOSDesign ? Theme.Font.subhead : .caption)
    }

    @ViewBuilder
    private func entryRow(_ entry: KPEntry) -> some View {
        if PlatformDesign.followsIOSDesign {
            designedEntryRow(entry)
        } else {
            legacyEntryRow(entry)
        }
    }

    /// No favicon: the extension never reaches the network.
    private func designedEntryRow(_ entry: KPEntry) -> some View {
        HStack(spacing: Theme.Spacing.iconText) {
            EntryIconView(entry: entry, size: entryIconSize)

            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Color.primary)
                if !entry.username.isEmpty {
                    Text(entry.username)
                        .font(Theme.Font.subhead)
                        .foregroundStyle(Theme.labelSecondary)
                }
            }

            Spacer(minLength: 0)

            if entry.isExpired() {
                StatusBadge(text: String(localized: "Expired"), tone: .danger)
                    .accessibilityIdentifier("autofill.entry.expired")
            }
        }
    }

    private func legacyEntryRow(_ entry: KPEntry) -> some View {
        HStack {
            StandardIconView(iconID: entry.iconID)
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
        .contentShape(Rectangle())
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

#if os(iOS)
/// The large title of the KeeForge iOS design, with the requesting site below
/// it from iOS 26.
private struct AutoFillPickerTitleStyle: ViewModifier {
    let service: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if service.isEmpty == false {
                content
                    .navigationBarTitleDisplayMode(.large)
                    .navigationSubtitle(Text(verbatim: service))
            } else {
                content
                    .navigationBarTitleDisplayMode(.large)
            }
        } else {
            content
                .navigationBarTitleDisplayMode(.large)
        }
    }
}
#endif

/// Empty state shown when no database participates in AutoFill (every
/// database disabled, or none registered): tells the user to turn on
/// AutoFill for a database in KeeForge's settings. Shared by both extension
/// shells; dismissing is the only action and cancels the request.
struct AutoFillNoEnabledDatabasesView: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            #if os(macOS)
            VStack(spacing: 0) {
                emptyState
                AutoFillMacFooter {
                    Button("Cancel", action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("autofill.no-enabled-databases.cancel")
                }
            }
            #else
            emptyState
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onDismiss()
                        }
                        .accessibilityIdentifier("autofill.no-enabled-databases.cancel")
                    }
                }
            #endif
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Databases for AutoFill", systemImage: "lock.slash")
                .accessibilityIdentifier("autofill.no-enabled-databases")
        } description: {
            Text("Turn on AutoFill for a database in KeeForge’s settings to use it here.")
        }
    }
}
