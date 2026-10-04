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

    func clearSelection() {
        selectedGroupID = nil
        selectedTag = nil
        selectedEntryID = nil
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
        tagExists: (String) -> Bool
    ) {
        guard let visibleRootGroupID else {
            clearSelection()
            return
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
