import AppKit
import SwiftUI

/// The unlocked workspace's window toolbar, one per unlocked session. Item
/// identifiers double as the accessibility identifiers the UI tests query.
@MainActor
final class MacWorkspaceToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let identifier = NSToolbar.Identifier("MacDatabaseWorkspace")

    enum Item {
        static let toggleSidebar = NSToolbarItem.Identifier("sidebar.left")
        static let readOnly = NSToolbarItem.Identifier("database.read-only-indicator")
        static let add = NSToolbarItem.Identifier("entry-list.add-entry")
        static let databaseStatus = NSToolbarItem.Identifier("workspace.database-status")
        static let databaseSettings = NSToolbarItem.Identifier("database-details.button")
        static let syncNow = NSToolbarItem.Identifier("database.cloud-sync-now")
        static let lock = NSToolbarItem.Identifier("lock.button")
        static let edit = NSToolbarItem.Identifier("entry-detail.edit")
        static let search = NSToolbarItem.Identifier("workspace.search")
        static let sidebarSeparator = NSToolbarItem.Identifier("workspace.sidebar-separator")
        static let listSeparator = NSToolbarItem.Identifier("workspace.list-separator")
    }

    /// The boards' layout: the sidebar toggle over the sidebar, search and New
    /// Entry (the glasses in a read-only database) over the entry list, between
    /// the split's tracking separators, and Edit over the detail. The status
    /// card's line and buttons join the detail only while the sidebar is hidden.
    static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        Item.toggleSidebar, Item.sidebarSeparator, Item.search, Item.add, Item.readOnly, Item.listSeparator,
        .flexibleSpace, Item.edit, Item.databaseStatus, Item.databaseSettings, Item.syncNow, Item.lock,
    ]
    static let statusItemIdentifiers: [NSToolbarItem.Identifier] = [
        Item.databaseStatus, Item.databaseSettings, Item.syncNow, Item.lock,
    ]

    let session: DatabaseViewModel
    let toolbar = NSToolbar(identifier: MacWorkspaceToolbar.identifier)
    let searchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    let statusLineView = MacStatusLineView()
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
        var isReadOnly: Bool
        var status: MacDatabaseStatus
        var isSidebarCollapsed: Bool
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
            isReadOnly: session.isReadOnly,
            status: MacDatabaseStatus.make(session: session, presentation: presentation),
            isSidebarCollapsed: presentation.isSidebarCollapsed,
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
        enable(Item.add, state.canNewEntry && state.isSaving == false)
        enable(Item.edit, state.canEditEntry && state.isSaving == false)
        enable(Item.databaseSettings, state.status.canShowSettings)
        enable(Item.syncNow, state.status.canSyncNow)
        enable(Item.lock, state.status.canLock)
        for identifier in Self.statusItemIdentifiers { items[identifier]?.isHidden = state.isSidebarCollapsed == false }
        if state.status.offersSyncNow == false { items[Item.syncNow]?.isHidden = true }
        statusLineView.update(state.status.line, short: true)
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

    private var statusActions: MacDatabaseStatusActions {
        MacDatabaseStatusActions(session: session, presentation: presentation)
    }

    @objc private func lockDatabase(_ sender: Any?) { statusActions.lock() }
    @objc private func newEntry(_ sender: Any?) { DatabaseCommands(session: session).newEntry() }
    @objc private func showDatabaseSettings(_ sender: Any?) { statusActions.showSettings() }
    @objc private func syncCloudNow(_ sender: Any?) { statusActions.syncNow() }

    @objc private func editEntry(_ sender: Any?) {
        guard let entryID = session.workspace.selectedEntryID else { return }
        presentation.beginEntryEdit(entryID: entryID, in: session)
    }

    @objc private func explainReadOnly(_ sender: Any?) { statusActions.explainReadOnly(from: toolbarWindow) }

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

        let statusItem = NSToolbarItem(itemIdentifier: Item.databaseStatus)
        // The toolbar draws its item background to the view's edges.
        statusLineView.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        statusItem.view = statusLineView
        statusItem.label = String(localized: "Status")
        statusLineView.setAccessibilityIdentifier(Item.databaseStatus.rawValue)
        items[Item.databaseStatus] = statusItem
        addButton(Item.databaseSettings, symbol: "slider.horizontal.3", label: String(localized: "Database Settings"),
                  target: self, action: #selector(showDatabaseSettings(_:)))
        addButton(Item.syncNow, symbol: "arrow.triangle.2.circlepath", label: String(localized: "Sync Now"),
                  target: self, action: #selector(syncCloudNow(_:)))
        addButton(Item.lock, symbol: "lock.fill", label: String(localized: "Lock Database"),
                  target: self, action: #selector(lockDatabase(_:)))

        let readOnly = addButton(Item.readOnly, symbol: "eyeglasses", label: String(localized: "Read-only database"),
                                 target: self, action: #selector(explainReadOnly(_:)))
        readOnly.contentTintColor = NSColor(Theme.State.warning)

        addButton(Item.add, symbol: "plus", label: String(localized: "New Entry"),
                  target: self, action: #selector(newEntry(_:)))

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
