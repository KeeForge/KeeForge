import Foundation
import Observation

enum DatabaseRoute: Hashable, Sendable {
    case group(UUID)
    case entry(UUID)
    case tag(String)
    case collection(DatabaseCollection)
    /// The compact layout's `openEditor`, pushed like any other screen. A
    /// destination outside the path would replace the path when it pops.
    case editor
}

/// The database-wide lists the vault root's tiles open, in tile order.
enum DatabaseCollection: String, CaseIterable, Hashable, Sendable {
    case allEntries
    case verificationCodes
    case tags
    case recycleBin

    /// The shorter name on the root's tile.
    var tileTitle: String {
        switch self {
        case .allEntries:
            String(localized: "All")
        case .verificationCodes:
            String(localized: "Codes")
        case .tags, .recycleBin:
            title
        }
    }

    var title: String {
        switch self {
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
        case .allEntries:
            "key"
        case .verificationCodes:
            "timer"
        case .tags:
            "tag"
        case .recycleBin:
            "trash"
        }
    }
}

/// How many items each collection holds. All Entries leaves out the recycle
/// bin; the recycle bin counts what it lists, its entries and groups.
struct DatabaseCollectionCounts: Equatable, Sendable {
    var allEntries = 0
    var verificationCodes = 0
    var tags = 0
    var recycleBin = 0

    subscript(collection: DatabaseCollection) -> Int {
        switch collection {
        case .allEntries: allEntries
        case .verificationCodes: verificationCodes
        case .tags: tags
        case .recycleBin: recycleBin
        }
    }
}

@MainActor @Observable
final class DatabaseWorkspaceState {
    enum Command {
        case newEntry
        case newGroup
        case editEntry
        case deleteSelection
    }

    /// An editor open over the vault on iPhone and iPad.
    enum OpenEditor {
        case entry(EntryEditViewModel)
        case group(GroupEditViewModel)
    }

    @ObservationIgnored var onInteraction: (() -> Void)?

    /// The compact stack, or the regular sidebar's. The regular layout shows
    /// entries in its detail column instead (`adaptNavigation`).
    var navigationPath: [DatabaseRoute] = [] {
        didSet { onInteraction?() }
    }
    /// Owned here, not by the presenting view, so its unsaved changes survive
    /// a layout change, which rebuilds every view.
    private(set) var openEditor: OpenEditor? {
        didSet {
            guard openEditor == nil else { return }
            openEditorCoordinator?.deactivate()
            openEditorCoordinator = nil
        }
    }
    /// Owned with the editor for the same reason: a rebuilt editor view must
    /// keep the entry a failed save already staged and a save still in flight.
    @ObservationIgnored private var openEditorCoordinator: DatabaseEditorCoordinator?
    var selectedGroupID: UUID? {
        didSet {
            if oldValue != selectedGroupID {
                selectedEntryID = nil
                if selectedGroupID != nil {
                    selectedTag = nil
                    selectedCollection = nil
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
                    selectedCollection = nil
                }
            }
            onInteraction?()
        }
    }
    /// A database-wide list selected in the Mac sidebar in place of a group
    /// or a tag. iOS opens collections as `DatabaseRoute.collection` instead.
    var selectedCollection: DatabaseCollection? {
        didSet {
            if oldValue != selectedCollection {
                selectedEntryID = nil
                if selectedCollection != nil {
                    selectedGroupID = nil
                    selectedTag = nil
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
    private(set) var newEntryRequestID = 0
    private(set) var newGroupRequestID = 0
    private(set) var editEntryRequestID = 0
    private(set) var deleteSelectionRequestID = 0

    func request(_ command: Command) {
        switch command {
        case .newEntry: newEntryRequestID += 1
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

    /// Selection mode with nothing picked yet, from the vault's More menu.
    func beginEntrySelection() {
        entrySelection = []
    }

    /// Replaces the picked entries wholesale, entering selection mode if needed;
    /// the Mac entry table's extended selection maps onto it.
    func setEntrySelection(_ entryIDs: Set<UUID>) {
        entrySelection = entryIDs
    }

    func toggleEntrySelection(_ entryID: UUID) {
        guard var selection = entrySelection else { return }
        if selection.remove(entryID) == nil {
            selection.insert(entryID)
        }
        entrySelection = selection
    }

    func selectEntries(_ entryIDs: [UUID]) {
        guard let selection = entrySelection else { return }
        entrySelection = selection.union(entryIDs)
    }

    func deselectEntries(_ entryIDs: [UUID]) {
        guard let selection = entrySelection else { return }
        entrySelection = selection.subtracting(entryIDs)
    }

    func endEntrySelection() {
        entrySelection = nil
    }

    func clearSelection() {
        selectedGroupID = nil
        selectedTag = nil
        selectedCollection = nil
        selectedEntryID = nil
        entrySelection = nil
    }

    func resetNavigation() {
        navigationPath.removeAll()
        clearSelection()
        closeEditor()
    }

    func resetForLock() {
        resetNavigation()
        isSearchActive = false
    }

    // MARK: - Editors

    var entryEditor: EntryEditViewModel? {
        if case .entry(let editor) = openEditor { editor } else { nil }
    }

    /// An editor already open keeps its unsaved work: the regular sidebar's
    /// New and row menus stay reachable while it is up.
    func present(_ editor: OpenEditor) {
        guard openEditor == nil else { return }
        openEditor = editor
    }

    func editorCoordinator(database: DatabaseViewModel) -> DatabaseEditorCoordinator? {
        if let openEditorCoordinator { return openEditorCoordinator }
        guard let openEditor else { return nil }
        let coordinator = switch openEditor {
        case .entry(let form): DatabaseEditorCoordinator(entry: form, database: database)
        case .group(let form): DatabaseEditorCoordinator(group: form, database: database)
        }
        openEditorCoordinator = coordinator
        return coordinator
    }

    func closeEditor() {
        openEditor = nil
        if navigationPath.contains(.editor) {
            navigationPath.removeAll { $0 == .editor }
        }
    }

    /// Ends the compact editor in one change to the path: a created entry
    /// replaces it, and a delete pops the deleted entry's screen with it. Two
    /// separate navigation changes in a row get dropped on iOS 26.
    func finishCompactEntryEditor(_ completion: EntryEditCompletion) {
        let editor = entryEditor
        openEditor = nil
        var path = navigationPath
        guard path.last == .editor else {
            closeEditor()
            return
        }
        path.removeLast()
        switch completion {
        case .created(let entryID):
            path.append(.entry(entryID))
        case .deleted:
            if case .edit(let entryID) = editor?.mode, path.last == .entry(entryID) {
                path.removeLast()
            }
        case .saved, .cancelled:
            break
        }
        navigationPath = path
    }

    // MARK: - Layout changes

    /// Carries navigation across a compact ↔ regular switch (iPhone Duo
    /// opening or closing, an iPad window resizing). The regular layout shows
    /// the entry and the editor in its detail column, so its sidebar path
    /// holds neither.
    func adaptNavigation(toRegularLayout regular: Bool) {
        if regular {
            navigationPath.removeAll { $0 == .editor }
            if case .entry(let entryID) = navigationPath.last {
                selectedEntryID = entryID
            } else {
                selectedEntryID = nil
            }
            navigationPath.removeAll { if case .entry = $0 { true } else { false } }
        } else {
            if let entryID = selectedEntryID {
                navigationPath.append(.entry(entryID))
                selectedEntryID = nil
            }
            if openEditor != nil {
                navigationPath.append(.editor)
            }
        }
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
        } else if selectedGroupID == nil, selectedTag == nil, selectedCollection == nil {
            selectedGroupID = visibleRootGroupID
        }
        // The detail host clears a vanished entry after its editor dismisses.
    }
}
