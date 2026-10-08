import Foundation
import Observation

enum DatabaseRoute: Hashable, Sendable {
    case group(UUID)
    case entry(UUID)
    case tag(String)
}

@MainActor @Observable
final class DatabaseWorkspaceState {
    /// What the database's root list shows, chosen from its view menu.
    enum ViewMode: String, Sendable {
        case groups
        case allEntries
        case verificationCodes
        case tags
        case recycleBin

        /// The views of the live database, in menu order. The recycle bin is
        /// listed apart from them.
        static let browsingModes: [ViewMode] = [.allEntries, .groups, .verificationCodes, .tags]

        var title: String {
            switch self {
            case .groups:
                String(localized: "Groups")
            case .allEntries:
                String(localized: "All Entries")
            case .verificationCodes:
                String(localized: "Verification Codes")
            case .tags:
                String(localized: "Tags")
            case .recycleBin:
                String(localized: "Recycle Bin")
            }
        }

        var systemImage: String {
            switch self {
            case .groups:
                "folder"
            case .allEntries:
                "list.bullet.rectangle"
            case .verificationCodes:
                "clock"
            case .tags:
                "tag"
            case .recycleBin:
                "trash"
            }
        }
    }

    enum Command {
        case newEntry
        case searchFocus
        case newGroup
        case editEntry
        case deleteSelection
    }

    @ObservationIgnored var onInteraction: (() -> Void)?

    var navigationPath: [DatabaseRoute] = [] {
        didSet { onInteraction?() }
    }
    var selectedGroupID: UUID? {
        didSet {
            if oldValue != selectedGroupID {
                selectedEntryID = nil
                if selectedGroupID != nil {
                    selectedTag = nil
                }
            }
            onInteraction?()
        }
    }
    var selectedTag: String? {
        didSet {
            if oldValue != selectedTag {
                selectedEntryID = nil
                if selectedTag != nil {
                    selectedGroupID = nil
                }
            }
            onInteraction?()
        }
    }
    var selectedEntryID: UUID? {
        didSet { onInteraction?() }
    }
    /// The entries picked while the lists are in selection mode, or `nil`
    /// outside it. One selection per session, so it survives walking from
    /// group to group and into the search results.
    private(set) var entrySelection: Set<UUID>? {
        didSet { onInteraction?() }
    }
    var isSearchActive = false {
        didSet { onInteraction?() }
    }
    var viewMode = DatabaseWorkspaceState.initialViewMode() {
        didSet { onInteraction?() }
    }
    private(set) var newEntryRequestID = 0
    private(set) var searchFocusRequestID = 0
    private(set) var newGroupRequestID = 0
    private(set) var editEntryRequestID = 0
    private(set) var deleteSelectionRequestID = 0

    func request(_ command: Command) {
        switch command {
        case .newEntry: newEntryRequestID += 1
        case .searchFocus: searchFocusRequestID += 1
        case .newGroup: newGroupRequestID += 1
        case .editEntry: editEntryRequestID += 1
        case .deleteSelection: deleteSelectionRequestID += 1
        }
    }

    /// The entry the single-entry commands act on (Edit, Delete, the copy
    /// shortcuts, Return). None while entries are being picked: the detail
    /// selection is then left over from before and need not be checked.
    var commandEntryID: UUID? {
        entrySelection == nil ? selectedEntryID : nil
    }

    func beginEntrySelection(with entryID: UUID) {
        entrySelection = [entryID]
    }

    func toggleEntrySelection(_ entryID: UUID) {
        guard var selection = entrySelection else { return }
        if selection.remove(entryID) == nil {
            selection.insert(entryID)
        }
        entrySelection = selection
    }

    func endEntrySelection() {
        entrySelection = nil
    }

    func clearSelection() {
        selectedGroupID = nil
        selectedTag = nil
        selectedEntryID = nil
        entrySelection = nil
    }

    func resetNavigation() {
        navigationPath.removeAll()
        clearSelection()
    }

    func resetForLock() {
        resetNavigation()
        isSearchActive = false
        viewMode = Self.initialViewMode()
    }

    func reconcileSelection(
        visibleRootGroupID: UUID?,
        groupExists: (UUID) -> Bool,
        tagExists: (String) -> Bool,
        entryIsSelectable: (UUID) -> Bool
    ) {
        guard let visibleRootGroupID else {
            clearSelection()
            return
        }
        // An emptied selection keeps the mode: the user is still choosing.
        if let entrySelection, entrySelection.allSatisfy(entryIsSelectable) == false {
            self.entrySelection = entrySelection.filter(entryIsSelectable)
        }
        if let selectedTag, tagExists(selectedTag) == false {
            self.selectedTag = nil
        }
        if let selectedGroupID, groupExists(selectedGroupID) == false {
            self.selectedGroupID = visibleRootGroupID
        } else if selectedGroupID == nil, selectedTag == nil {
            selectedGroupID = visibleRootGroupID
        }
        // The detail host clears a vanished entry after its editor dismisses.
    }

    /// A database opens on All Entries. UI tests can start on another view
    /// through `UI_TEST_VIEW_MODE`: their helpers browse from the group list.
    static func initialViewMode(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ViewMode {
        guard arguments.contains("-ui-testing"),
              let rawValue = environment["UI_TEST_VIEW_MODE"],
              let mode = ViewMode(rawValue: rawValue) else {
            return .allEntries
        }
        return mode
    }
}
