#if os(macOS)
import CryptoKit
import Foundation
import OneTimeCodes

/// What a Mac entry cell draws as its icon; the cell resolves it to an image.
enum MacEntryIcon: Equatable {
    case standard(Int)
    /// A custom icon's image data from `KPMeta.customIcons`; the standard icon
    /// is for data that does not decode.
    case custom(Data, standardIconID: Int)
}

/// The Mac entry list's rows for one session: search results, a tag, a
/// collection or a group, with what each cell draws, the header above the
/// rows, the footer hint and the empty state.
struct MacEntryListSnapshot: Equatable {
    enum Mode: Equatable {
        case search(String)
        case tag(String)
        case collection(DatabaseCollection)
        case group(UUID)
        case none

        var spansGroups: Bool {
            switch self {
            case .search, .tag, .collection: true
            case .group, .none: false
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let id: UUID
        let title: String
        /// Field references stay unresolved; the cell resolves only the rows it draws.
        let rawUsername: String
        /// The groups' path from the Groups root, joined by `folderPathSeparator`; only when the list spans groups.
        let folderPath: String?
        let icon: MacEntryIcon
        /// Set when website icons are on and the entry has no custom icon.
        let faviconDomain: String?
        let isExpired: Bool
        let hasPasskey: Bool
        let hasVerificationCode: Bool
        /// Read from the attachment names alone: KeeAgent's settings attachment marks an SSH key entry.
        let hasSSHKey: Bool
        let isMovable: Bool
    }

    enum EmptyState: Equatable {
        case searchPrompt
        case noResults(query: String)
        case noTagEntries
        case noVerificationCodes
        case noPasskeys
        case noDatabaseEntries
        case noGroupEntries
        case recycleBinEmpty
        case noGroupSelected

        var title: String {
            switch self {
            case .searchPrompt: String(localized: "Search Entries")
            case .noResults: String(localized: "No Results")
            case .noTagEntries, .noDatabaseEntries, .noGroupEntries: String(localized: "No Entries")
            case .noVerificationCodes: String(localized: "No Verification Codes")
            case .noPasskeys: String(localized: "No Passkeys")
            case .recycleBinEmpty: String(localized: "Recycle Bin Is Empty")
            case .noGroupSelected: String(localized: "Select a Group")
            }
        }

        var message: String {
            switch self {
            case .searchPrompt: String(localized: "Type to search by title, username, URL, notes, or tags.")
            case .noResults(let query): String(localized: "No entries matched \"\(query)\".")
            case .noTagEntries: String(localized: "No entries carry this tag anymore.")
            case .noVerificationCodes: String(localized: "Entries with a verification code appear here.")
            case .noPasskeys: String(localized: "Passkeys saved through AutoFill appear here.")
            case .noDatabaseEntries: String(localized: "This database has no entries.")
            case .noGroupEntries: String(localized: "This group has no entries.")
            case .recycleBinEmpty: String(localized: "Deleted entries and groups appear here.")
            case .noGroupSelected: String(localized: "Choose a group to view its entries.")
            }
        }

        var systemImage: String {
            switch self {
            case .searchPrompt: "magnifyingglass"
            case .noResults: "doc.text.magnifyingglass"
            case .noTagEntries: "tag.slash"
            case .noVerificationCodes: DatabaseCollection.verificationCodes.systemImage
            case .noPasskeys: DatabaseCollection.passkeys.systemImage
            case .noDatabaseEntries, .noGroupEntries: "tray"
            case .recycleBinEmpty: "trash"
            case .noGroupSelected: "folder"
            }
        }

        var accessibilityIdentifier: String? {
            if case .noResults = self { "search.no-results" } else { nil }
        }
    }

    /// The title and count line above the rows.
    struct Header: Equatable {
        let title: String
        /// A tag's title follows an accent "#".
        let isTag: Bool
        let subtitle: String
    }

    /// The caption under the rows.
    enum Footer: Equatable {
        case verificationCodes
        case search
        case multipleSelection

        var text: String {
            switch self {
            case .verificationCodes: String(localized: "Click a code to copy it · ⇧⌘T copies the selected entry's code")
            case .search: String(localized: "Search covers titles, usernames, URLs, notes and tags in every group.")
            case .multipleSelection: String(localized: "Command-click or Shift-click to select several entries.")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .verificationCodes: "verification-codes.hint"
            case .search: "search.hint"
            case .multipleSelection: "entry-selection.hint"
            }
        }
    }

    static let folderPathSeparator = " › "
    static let headerSeparator = " · "

    let mode: Mode
    let rows: [Row]
    let emptyState: EmptyState?
    let showsVerificationCodes: Bool
    /// The search's match count for the UI-test overlay; nil outside search.
    let resultCount: Int?
    /// Nil while no group is selected.
    let header: Header?
    let footer: Footer?
    /// An empty group outside the recycle bin offers New Entry when the database takes edits.
    let offersNewEntry: Bool

    var rowIdentifier: String {
        switch mode {
        case .search, .tag: "search.entry.navlink"
        case .collection, .group, .none: "entry.navlink"
        }
    }

    var containerIdentifier: String? {
        guard rows.isEmpty == false else { return nil }
        return switch mode {
        case .search: "search.results"
        case .tag: "tag-entries.list"
        case .collection, .group, .none: nil
        }
    }

    /// Search wins over the sidebar, then a tag or collection, then the
    /// selected group, falling back to the workspace root.
    @MainActor
    static func mode(session: DatabaseViewModel) -> Mode {
        let workspace = session.workspace
        if session.searchText.isEmpty == false { return .search(session.searchText) }
        if let tag = workspace.selectedTag { return .tag(tag) }
        if let collection = workspace.selectedCollection { return .collection(collection) }
        guard let groupID = workspace.selectedGroupID ?? session.workspaceRootGroupID,
              session.group(withID: groupID) != nil else { return .none }
        return .group(groupID)
    }

    /// The entries `mode` lists, in display order.
    @MainActor
    static func entries(for mode: Mode, session: DatabaseViewModel) -> [KPEntry] {
        switch mode {
        case .search: session.isSearchQueryEmpty ? [] : session.searchResults
        case .tag(let tag): session.entries(for: .tag(tag))
        case .collection(let collection): session.entries(for: .collection(collection))
        case .group(let groupID): session.entries(for: .group(groupID))
        case .none: []
        }
    }

    /// Whether the current list has no rows, for controls that dim with it (Sort).
    @MainActor
    static func listIsEmpty(session: DatabaseViewModel) -> Bool {
        entries(for: mode(session: session), session: session).isEmpty
    }

    @MainActor
    static func make(
        session: DatabaseViewModel,
        showsWebsiteIcons: Bool = SettingsService.showWebsiteIcons,
        isSidebarCollapsed: Bool = false,
        now: Date = .now
    ) -> MacEntryListSnapshot {
        let mode = Self.mode(session: session)
        let entries = Self.entries(for: mode, session: session)
        let emptyState: EmptyState?
        var resultCount: Int?
        switch mode {
        case .search(let query):
            resultCount = session.searchResults.count
            emptyState = session.isSearchQueryEmpty ? .searchPrompt : (entries.isEmpty ? .noResults(query: query) : nil)
        case .tag:
            emptyState = entries.isEmpty ? .noTagEntries : nil
        case .collection(let collection):
            let empty: EmptyState = switch collection {
            case .verificationCodes: .noVerificationCodes
            case .passkeys: .noPasskeys
            case .allEntries, .tags, .recycleBin: .noDatabaseEntries
            }
            emptyState = entries.isEmpty ? empty : nil
        case .group(let groupID):
            let isRecycleBin = groupID == session.currentRootGroup?.recycleBinUUID
            emptyState = entries.isEmpty ? (isRecycleBin ? .recycleBinEmpty : .noGroupEntries) : nil
        case .none:
            emptyState = .noGroupSelected
        }
        let folderPaths = mode.spansGroups ? Self.folderPaths(session: session) : [:]

        let customIcons = session.currentMeta?.customIcons ?? [:]
        let rows = entries.map { entry in
            let customIcon = entry.customIconUUID.flatMap { customIcons[$0] }
            return Row(
                id: entry.id,
                title: entry.title.isEmpty ? String(localized: "(untitled)") : entry.title,
                rawUsername: entry.username,
                folderPath: folderPaths[entry.id],
                icon: customIcon.map { .custom($0, standardIconID: entry.iconID) } ?? .standard(entry.iconID),
                faviconDomain: customIcon == nil && showsWebsiteIcons ? FaviconService.extractDomain(from: entry.url) : nil,
                isExpired: entry.isExpired(at: now),
                hasPasskey: entry.hasPasskey,
                hasVerificationCode: entry.totpConfig != nil,
                hasSSHKey: entry.attachments.contains { $0.name == KeeAgentSettings.attachmentName },
                isMovable: EntryRowActions(entryID: entry.id, session: session).canMove
            )
        }
        let showsVerificationCodes = mode == .collection(.verificationCodes) && session.sessionKey != nil
        let footer: Footer? = if session.workspace.entrySelection != nil {
            .multipleSelection
        } else if rows.isEmpty {
            nil
        } else if showsVerificationCodes {
            .verificationCodes
        } else if case .search = mode {
            .search
        } else {
            nil
        }
        let offersNewEntry: Bool = if emptyState == .noGroupEntries, case .group(let groupID) = mode {
            session.isGroupInRecycleBin(groupID: groupID) == false && DatabaseCommands(session: session).canNewEntry
        } else {
            false
        }
        return MacEntryListSnapshot(
            mode: mode,
            rows: rows,
            emptyState: emptyState,
            showsVerificationCodes: showsVerificationCodes,
            resultCount: resultCount,
            header: header(mode: mode, entries: entries, session: session, isSidebarCollapsed: isSidebarCollapsed),
            footer: footer,
            offersNewEntry: offersNewEntry
        )
    }

    /// The boards' wording: "Personal · 12 entries", "Tag · 14 entries in 5
    /// groups", "Results: 5 · All of Personal", "Personal · 3 of 12 selected"
    /// while several are picked, and in the bin "Deleted Entries" over
    /// "Recycle Bin · 5 entries". With the sidebar hidden a group's line starts
    /// with its parents' path instead ("Personal › Work · 12 entries").
    @MainActor
    static func header(
        mode: Mode,
        entries: [KPEntry],
        session: DatabaseViewModel,
        isSidebarCollapsed: Bool = false
    ) -> Header? {
        let databaseName = session.databaseDisplayName
        let count = entries.count
        let title: String
        var prefix = databaseName
        let countLine: String
        switch mode {
        case .search:
            title = String(localized: "Search")
            countLine = String(localized: "Results: \(count) · All of \(databaseName)")
        case .tag(let tag):
            title = tag
            prefix = String(localized: "Tag")
            let groupCount = Set(entries.compactMap { session.parentGroupID(forEntryID: $0.id) }).count
            countLine = count == 0
                ? String(localized: "\(count) entries")
                : String(localized: "\(count) entries in \(groupCount) groups")
        case .collection(let collection):
            title = collection.title
            countLine = String(localized: "\(count) entries")
        case .group(let groupID):
            countLine = String(localized: "\(count) entries")
            if groupID == session.currentRootGroup?.recycleBinUUID {
                title = String(localized: "Deleted Entries")
                prefix = String(localized: "Recycle Bin")
            } else {
                title = session.group(withID: groupID)?.name ?? ""
                if session.isGroupInRecycleBin(groupID: groupID) {
                    prefix = String(localized: "Recycle Bin")
                } else if isSidebarCollapsed, let path = parentPath(ofGroupID: groupID, session: session) {
                    prefix = path
                }
            }
        case .none:
            return nil
        }
        let isTag = if case .tag = mode { true } else { false }
        if let picked = session.workspace.entrySelection {
            let pickedCount = entries.reduce(0) { $0 + (picked.contains($1.id) ? 1 : 0) }
            let selected = String(localized: "\(pickedCount) of \(count) selected")
            return Header(title: title, isTag: isTag, subtitle: prefix + headerSeparator + selected)
        }
        if case .search = mode { return Header(title: title, isTag: false, subtitle: countLine) }
        return Header(title: title, isTag: isTag, subtitle: prefix + headerSeparator + countLine)
    }

    /// The names from the Groups root down to the group's parent ("Personal ›
    /// Work"); nil for the root itself or a group outside the tree.
    @MainActor
    static func parentPath(ofGroupID groupID: UUID, session: DatabaseViewModel) -> String? {
        guard let rootID = session.workspaceRootGroupID, let root = session.group(withID: rootID) else { return nil }
        func path(in group: KPGroup, names: [String]) -> [String]? {
            for child in group.groups {
                if child.id == groupID { return names }
                if let found = path(in: child, names: names + [child.name]) { return found }
            }
            return nil
        }
        return path(in: root, names: [root.name]).map { $0.joined(separator: folderPathSeparator) }
    }

    /// Each entry's path from the sidebar's Groups root, root name included
    /// ("Personal › Work") unless `includingRoot` is off, when an entry at the
    /// root has none. The shared `folderPath` joins with " / " for iOS, so the
    /// Mac formats its own.
    @MainActor
    static func folderPaths(session: DatabaseViewModel, includingRoot: Bool = true) -> [UUID: String] {
        guard let rootID = session.workspaceRootGroupID, let root = session.group(withID: rootID) else { return [:] }
        var paths: [UUID: String] = [:]
        func visit(_ group: KPGroup, path: [String]) {
            if path.isEmpty == false {
                for entry in group.entries { paths[entry.id] = path.joined(separator: folderPathSeparator) }
            }
            for child in group.groups { visit(child, path: path + [child.name]) }
        }
        visit(root, path: includingRoot ? [root.name] : [])
        return paths
    }
}

/// The two-way mapping between the entry table's selection and the
/// workspace's single selection and bulk `entrySelection`.
enum MacEntryListSelection {
    /// The bulk selection's visible rows while picking, else the selected entry's row.
    @MainActor
    static func tableSelection(rows: [MacEntryListSnapshot.Row], workspace: DatabaseWorkspaceState) -> IndexSet {
        if let entrySelection = workspace.entrySelection {
            return IndexSet(rows.indices.filter { entrySelection.contains(rows[$0].id) })
        }
        guard let selectedEntryID = workspace.selectedEntryID,
              let index = rows.firstIndex(where: { $0.id == selectedEntryID }) else { return IndexSet() }
        return IndexSet(integer: index)
    }

    /// The table's selected rows become the workspace's selection: two or
    /// more are picks, one is the selected entry.
    @MainActor
    static func apply(selectedIDs: [UUID], to workspace: DatabaseWorkspaceState) {
        let total = Set(selectedIDs)
        if total.count >= 2 {
            workspace.setEntrySelection(total)
        } else {
            workspace.endEntrySelection()
            workspace.selectedEntryID = total.first
        }
    }

    /// As in a native list, a pick does not outlive its row: picks the current
    /// list no longer shows (another group, tag or search, a merge) are
    /// dropped, and one left over becomes the selected entry. Returns whether
    /// anything changed.
    @MainActor
    @discardableResult
    static func dropHiddenPicks(session: DatabaseViewModel) -> Bool {
        let workspace = session.workspace
        guard let picked = workspace.entrySelection, picked.isEmpty == false else { return false }
        let mode = MacEntryListSnapshot.mode(session: session)
        let visible = Set(MacEntryListSnapshot.entries(for: mode, session: session).map(\.id))
        let kept = picked.intersection(visible)
        guard kept != picked else { return false }
        apply(selectedIDs: Array(kept), to: workspace)
        return true
    }

    /// Several rows may be picked only to move or recycle them, so a multiple
    /// proposal keeps the movable rows, and a read-only database keeps one row.
    static func proposedSelection(
        _ proposed: IndexSet,
        current: IndexSet,
        rows: [MacEntryListSnapshot.Row],
        isReadOnly: Bool
    ) -> IndexSet {
        guard proposed.count >= 2 else { return proposed }
        if isReadOnly {
            if current.count <= 1 { return current }
            return proposed.first.map { IndexSet(integer: $0) } ?? IndexSet()
        }
        let movable = IndexSet(proposed.filter { rows.indices.contains($0) && rows[$0].isMovable })
        return movable.isEmpty ? current : movable
    }
}

/// The verification codes the Mac list shows, from an injected clock and
/// generator. It keeps only the code already on screen per entry and time
/// step, never decoded parameters or secrets, and forgets everything when the
/// session's lock cycle or content changes.
@MainActor
final class MacVerificationCodeClock {
    struct Display: Equatable {
        let code: String
        let grouped: String
        let secondsRemaining: Int
        let progress: Double

        /// The last seconds of a code, when the row dims it and the ring turns orange.
        var isExpiring: Bool { secondsRemaining <= Self.expiringSeconds }

        static let expiringSeconds = 5
    }

    private struct Generation: Equatable {
        let session: ObjectIdentifier
        let lockCycleID: Int
        let contentRevision: Int
    }

    private struct CachedCode {
        let step: Int
        let code: String
    }

    private let now: () -> Date
    private let generate: (TOTPConfig, SymmetricKey, Date) -> String
    private var generation: Generation?
    private var codes: [UUID: CachedCode] = [:]

    init(
        now: @escaping () -> Date = { Date() },
        generate: @escaping (TOTPConfig, SymmetricKey, Date) -> String = {
            TOTPGenerator.generateCode(config: $0, sessionKey: $1, date: $2)
        }
    ) {
        self.now = now
        self.generate = generate
    }

    var cachedCodeCount: Int {
        codes.count
    }

    func display(for entryID: UUID, session: DatabaseViewModel) -> Display? {
        guard session.state == .unlocked, let sessionKey = session.sessionKey else {
            reset()
            return nil
        }
        let current = Generation(
            session: ObjectIdentifier(session),
            lockCycleID: session.lockCycleID,
            contentRevision: session.contentRevision
        )
        if generation != current {
            reset()
            generation = current
        }
        guard let config = session.entry(withID: entryID)?.totpConfig, config.period > 0 else { return nil }
        let date = now()
        let step = Int((date.timeIntervalSince1970 / Double(config.period)).rounded(.down))
        let code: String
        if let cached = codes[entryID], cached.step == step {
            code = cached.code
        } else {
            code = generate(config, sessionKey, date)
            codes[entryID] = CachedCode(step: step, code: code)
        }
        let secondsRemaining = TOTP.secondsRemaining(period: config.period, at: date)
        return Display(
            code: code,
            grouped: TOTPViewModel.grouped(code),
            secondsRemaining: secondsRemaining,
            progress: Double(secondsRemaining) / Double(config.period)
        )
    }

    func forget(_ entryID: UUID) {
        codes[entryID] = nil
    }

    func reset() {
        generation = nil
        codes.removeAll()
    }
}
#endif
