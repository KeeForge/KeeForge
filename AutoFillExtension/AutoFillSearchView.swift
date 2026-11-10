import SiteMatching
import SwiftUI

struct AutoFillSearchResults {
    let entries: [KPEntry]
    let possibleEntries: [KPEntry]
    let canShowAllEntries: Bool

    init(entries: [KPEntry], searchEntries: [KPEntry], possibleEntries: [KPEntry], query: String, hasExpandedSearch: Bool) {
        if hasExpandedSearch || !query.isEmpty {
            let query = query.lowercased()
            self.entries = query.isEmpty ? searchEntries : searchEntries.filter { entry in
                entry.title.lowercased().contains(query) ||
                entry.username.lowercased().contains(query) ||
                CredentialMatcher.webURLs(of: entry).contains { $0.lowercased().contains(query) } ||
                entry.notes.lowercased().contains(query)
            }
            self.possibleEntries = []
            canShowAllEntries = !query.isEmpty && self.entries.count < searchEntries.count
        } else {
            self.entries = entries
            self.possibleEntries = possibleEntries
            canShowAllEntries = entries.count + possibleEntries.count < searchEntries.count
        }
    }
}

struct AutoFillSearchView: View {
    let entries: [KPEntry]
    let searchEntries: [KPEntry]
    let possibleEntries: [KPEntry]
    /// The database's `Meta/CustomIcons`, for entries that use one.
    let customIcons: [UUID: Data]
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
        customIcons: [UUID: Data] = [:],
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
        self.customIcons = customIcons
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

    private var searchResults: AutoFillSearchResults {
        AutoFillSearchResults(
            entries: entries,
            searchEntries: searchEntries,
            possibleEntries: possibleEntries,
            query: searchText,
            hasExpandedSearch: didEditSearch || showsAllEntries
        )
    }

    private var filteredEntries: [KPEntry] { searchResults.entries }
    private var filteredPossibleEntries: [KPEntry] { searchResults.possibleEntries }
    private var canShowAllEntries: Bool {
        searchResults.canShowAllEntries
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
            if filteredEntries.isEmpty && !filteredPossibleEntries.isEmpty {
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
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No credentials match this search.")
                    }
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

    /// The site the request came from, while its search is still the one
    /// KeeForge filled in; a search the user typed has no site to name.
    private var requestedSite: String? {
        guard didEditSearch == false, searchText == initialSearchText else { return nil }
        let site = initialSearchText.isEmpty ? urlAddition?.host : initialSearchText
        return site?.isEmpty == false ? site : nil
    }

    /// Names the site when there is one, offers creating a login for it and
    /// listing everything as one card, and keeps the shared-copy note short.
    private var designedNoCredentialsFoundView: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.cardGap) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)

                if let requestedSite {
                    Text("Nothing for this site yet")
                        .font(Theme.Font.entryTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("autofill.no-credentials-found")
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .accessibilityHidden(true)
                        Text(requestedSite)
                    }
                    .font(Theme.Font.subhead)
                    .padding(.horizontal, Theme.Spacing.iconText)
                    .padding(.vertical, 6)
                    .background(Theme.fill, in: Capsule())
                } else {
                    Text("No Credentials Found")
                        .font(Theme.Font.entryTitle)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("autofill.no-credentials-found")
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No credentials match this search.")
                            .font(Theme.Font.subhead)
                            .foregroundStyle(Theme.labelSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if onCreateEntry != nil || canShowAllEntries {
                    VStack(spacing: 0) {
                        if let onCreateEntry {
                            emptyStateAction(
                                requestedSite == nil ? String(localized: "Create New Credential") : String(localized: "Create Login for This Site"),
                                systemImage: "plus",
                                tint: Theme.accent,
                                identifier: "autofill.create-entry.empty-state",
                                action: onCreateEntry
                            )
                        }
                        if onCreateEntry != nil, canShowAllEntries {
                            Divider().padding(.leading, 60)
                        }
                        if canShowAllEntries {
                            emptyStateAction(
                                String(localized: "Show All Credentials"),
                                systemImage: "list.bullet",
                                tint: Theme.labelSecondary,
                                identifier: "autofill.show-all-entries.empty-state",
                                action: showAllEntries
                            )
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.top, Theme.Spacing.tileGap)
                }

                if let sharedCopyDate {
                    Label {
                        Text("Searched the copy from \(sharedCopyDate.formatted(date: .abbreviated, time: .shortened)). Unlock this database in KeeForge to refresh it.")
                            .accessibilityIdentifier("autofill.shared-copy-notice")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.iconText)
                }
            }
            .padding(Theme.Spacing.side)
            .padding(.top, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// A row of the empty state's action card: a tinted square, the title, a chevron.
    private func emptyStateAction(
        _ title: String,
        systemImage: String,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.iconText) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.tileGlyph)
                    .frame(width: 32, height: 32)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.side)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var noCredentialsFoundLabel: some View {
        Label("No Credentials Found", systemImage: "magnifyingglass")
            .accessibilityIdentifier("autofill.no-credentials-found")
    }

    private func sharedCopyNotice(_ date: Date) -> some View {
        Text("Searched KeeForge’s copy of this database from \(date.formatted(date: .abbreviated, time: .shortened)). To find newer credentials, unlock this database in KeeForge. For cloud databases, use Sync Now in Database Details.")
            .accessibilityIdentifier("autofill.shared-copy-notice")
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

    private func designedEntryRow(_ entry: KPEntry) -> some View {
        HStack(spacing: Theme.Spacing.iconText) {
            AutoFillEntryIcon(
                entry: entry,
                customIconData: entry.customIconUUID.flatMap { customIcons[$0] },
                size: entryIconSize
            )

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
                let hosts = Set(CredentialMatcher.webURLs(of: entry).compactMap { SiteHost($0)?.name }).sorted()
                if !hosts.isEmpty {
                    Text(hosts.joined(separator: ", "))
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

/// An entry's icon as the app draws it: its custom icon, else on iOS the
/// website icon the app already cached in the App Group. The extension never
/// fetches one; it has no network on macOS and must not add egress on iOS.
private struct AutoFillEntryIcon: View {
    let entry: KPEntry
    let customIconData: Data?
    let size: CGFloat

    @State private var favicon: PlatformImage?

    var body: some View {
        EntryIconView(entry: entry, customIconData: customIconData, favicon: favicon, size: size)
            .task(id: entry.id) {
                #if os(iOS)
                guard customIconData == nil,
                      SettingsService.showWebsiteIcons,
                      let domain = FaviconService.extractDomain(from: entry.url) else { return }
                favicon = FaviconService.cachedImage(for: domain)
                #endif
            }
    }
}
