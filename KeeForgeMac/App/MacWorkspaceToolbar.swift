import AppKit
import SwiftUI

/// The unlocked workspace's window toolbar, one per unlocked session. Item
/// identifiers double as the accessibility identifiers the UI tests query.
@MainActor
final class MacWorkspaceToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let identifier = NSToolbar.Identifier("MacDatabaseWorkspace")

    enum Item {
        static let toggleSidebar = NSToolbarItem.Identifier("sidebar.left")
        static let lock = NSToolbarItem.Identifier("lock.button")
        static let cloudSync = NSToolbarItem.Identifier("database.cloud-sync-status")
        static let readOnly = NSToolbarItem.Identifier("database.read-only-indicator")
        static let add = NSToolbarItem.Identifier("entry-list.add-entry")
        static let details = NSToolbarItem.Identifier("database-details.button")
        static let settings = NSToolbarItem.Identifier("settings.button")
        static let edit = NSToolbarItem.Identifier("entry-detail.edit")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let sidebarSeparator = NSToolbarItem.Identifier("workspace.sidebar-separator")
        static let listSeparator = NSToolbarItem.Identifier("workspace.list-separator")
    }

    /// The boards' layout: the sidebar toggle over the sidebar, search and New
    /// Entry over the entry list (between the split's tracking separators),
    /// and the database's items and Edit over the detail.
    static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        Item.toggleSidebar, Item.sidebarSeparator, Item.search, Item.add, Item.listSeparator,
        Item.lock, Item.cloudSync, Item.readOnly, Item.details, Item.settings, .flexibleSpace, Item.edit,
    ]

    let session: DatabaseViewModel
    let toolbar = NSToolbar(identifier: MacWorkspaceToolbar.identifier)
    let searchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    private(set) var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let presentation: MacWorkspacePresentation
    private let observation = MacObservation()
    private var controls: [NSControl] = []

    /// `splitView` is the workspace split whose dividers the separators track.
    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation, splitView: NSSplitView) {
        self.session = session
        self.presentation = presentation
        super.init()
        makeItems(splitView: splitView)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] state in
            guard let state else { return }
            self?.apply(state)
        })
    }

    func focusSearch() {
        if toolbar.isVisible == false { toolbar.isVisible = true }
        searchItem.beginSearchInteraction()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemIdentifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemIdentifiers }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        items[itemIdentifier]
    }

    // MARK: - Search

    func controlTextDidChange(_ notification: Notification) {
        pushSearchText()
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        pushSearchText()
    }

    private func pushSearchText() {
        let text = searchItem.searchField.stringValue
        if session.searchText != text { session.searchText = text }
    }

    // MARK: - State

    private struct State {
        var isSaving: Bool
        var canLock: Bool
        var isReadOnly: Bool
        var showsCloudSync: Bool
        var canNewEntry: Bool
        var showsEdit: Bool
        var canEditEntry: Bool
        var searchText: String
        var databaseName: String
    }

    private func readState() -> State {
        let commands = DatabaseCommands(session: session)
        let showsEdit = session.workspace.selectedEntryID.map { session.entry(withID: $0) != nil } ?? false
        return State(
            isSaving: session.isSaving,
            canLock: commands.canLock,
            isReadOnly: session.isReadOnly,
            showsCloudSync: CloudSyncControls.isVisible(for: session),
            canNewEntry: commands.canNewEntry,
            showsEdit: showsEdit && session.isReadOnly == false,
            canEditEntry: commands.canEditEntry,
            searchText: session.searchText,
            databaseName: session.databaseDisplayName
        )
    }

    private func apply(_ state: State) {
        for control in controls { control.isEnabled = state.isSaving == false }
        searchItem.searchField.isEnabled = state.isSaving == false
        enable(Item.lock, state.canLock && state.isSaving == false)
        enable(Item.add, state.canNewEntry && state.isSaving == false)
        enable(Item.edit, state.canEditEntry && state.isSaving == false)
        items[Item.cloudSync]?.isHidden = state.showsCloudSync == false
        items[Item.readOnly]?.isHidden = state.isReadOnly == false
        items[Item.add]?.isHidden = state.isReadOnly
        items[Item.edit]?.isHidden = state.showsEdit == false
        let placeholder = Self.searchPlaceholder(databaseName: state.databaseName)
        if searchItem.searchField.placeholderString != placeholder {
            searchItem.searchField.placeholderString = placeholder
        }
        if searchItem.searchField.stringValue != state.searchText {
            searchItem.searchField.stringValue = state.searchText
        }
    }

    static func searchPlaceholder(databaseName: String) -> String {
        String(localized: "Search \(databaseName)")
    }

    private func enable(_ identifier: NSToolbarItem.Identifier, _ isEnabled: Bool) {
        (items[identifier]?.view as? NSControl)?.isEnabled = isEnabled
        items[identifier]?.menuFormRepresentation?.isEnabled = isEnabled
    }

    // MARK: - Actions

    @objc private func lockDatabase(_ sender: Any?) { DatabaseCommands(session: session).lock() }
    @objc private func newEntry(_ sender: Any?) { DatabaseCommands(session: session).newEntry() }
    @objc private func showDatabaseDetails(_ sender: Any?) { presentation.isShowingDatabaseDetails = true }
    @objc private func syncCloudNow(_ sender: Any?) {
        let session = session
        Task { await session.syncCloudNow() }
    }

    @objc private func editEntry(_ sender: Any?) {
        guard let entryID = session.workspace.selectedEntryID else { return }
        presentation.beginEntryEdit(entryID: entryID, in: session)
    }

    @objc private func explainReadOnly(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Read-Only Database")
        alert.informativeText = session.readOnlyExplanation
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = toolbarWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private var toolbarWindow: NSWindow? {
        items.values.lazy.compactMap { $0.view?.window }.first ?? NSApp.keyWindow
    }

    // MARK: - Items

    private func makeItems(splitView: NSSplitView) {
        items[Item.sidebarSeparator] = NSTrackingSeparatorToolbarItem(
            identifier: Item.sidebarSeparator, splitView: splitView, dividerIndex: 0)
        items[Item.listSeparator] = NSTrackingSeparatorToolbarItem(
            identifier: Item.listSeparator, splitView: splitView, dividerIndex: 1)
        addButton(Item.toggleSidebar, symbol: "sidebar.left", label: String(localized: "Show Sidebar"),
                  target: nil, action: #selector(NSSplitViewController.toggleSidebar(_:)))
        addButton(Item.lock, symbol: "lock.fill", label: String(localized: "Lock Database"),
                  target: self, action: #selector(lockDatabase(_:)))

        let cloud = NSToolbarItem(itemIdentifier: Item.cloudSync)
        cloud.view = NSHostingView(rootView: CloudSyncToolbarControls(session: session))
        cloud.label = String(localized: "Cloud Sync")
        cloud.menuFormRepresentation = menuItem(String(localized: "Sync Now"), action: #selector(syncCloudNow(_:)))
        items[Item.cloudSync] = cloud

        let readOnly = addButton(Item.readOnly, symbol: "eyeglasses", label: String(localized: "Read-only database"),
                                 target: self, action: #selector(explainReadOnly(_:)))
        readOnly.contentTintColor = NSColor(Theme.State.warning)

        addButton(Item.add, symbol: "plus", label: String(localized: "New Entry"),
                  target: self, action: #selector(newEntry(_:)))
        addButton(Item.details, symbol: "info.circle", label: String(localized: "Database Details"),
                  target: self, action: #selector(showDatabaseDetails(_:)))
        addButton(Item.settings, symbol: "gearshape", label: String(localized: "Settings"),
                  target: nil, action: #selector(AppDelegate.showSettings(_:)))

        let editLabel = String(localized: "Edit")
        let edit = NSButton(title: editLabel, target: self, action: #selector(editEntry(_:)))
        edit.bezelStyle = .toolbar
        edit.setAccessibilityIdentifier(Item.edit.rawValue)
        addItem(Item.edit, view: edit, label: editLabel, menuForm: menuItem(editLabel, action: #selector(editEntry(_:))))

        searchItem.label = String(localized: "Search")
        searchItem.searchField.placeholderString = Self.searchPlaceholder(databaseName: session.databaseDisplayName)
        searchItem.searchField.delegate = self
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searchFieldDidChange(_:))
        items[Item.search] = searchItem
    }

    @discardableResult
    private func addButton(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        target: AnyObject?,
        action: Selector
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .toolbar
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier.rawValue)
        let menuForm = NSMenuItem(title: label, action: action, keyEquivalent: "")
        menuForm.target = target
        addItem(identifier, view: button, label: label, menuForm: menuForm)
        controls.append(button)
        return button
    }

    private func addItem(_ identifier: NSToolbarItem.Identifier, view: NSView, label: String, menuForm: NSMenuItem) {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        item.label = label
        item.toolTip = label
        item.menuFormRepresentation = menuForm
        items[identifier] = item
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

/// Observes saving itself: the hosting view's root is built once.
private struct CloudSyncToolbarControls: View {
    let session: DatabaseViewModel

    var body: some View {
        CloudSyncControls(viewModel: session)
            .disabled(session.isSaving)
            .modifier(MacHostingAppearance())
    }
}
