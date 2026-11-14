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
        static let sort = NSToolbarItem.Identifier("sort.menu")
        static let details = NSToolbarItem.Identifier("database-details.button")
        static let settings = NSToolbarItem.Identifier("settings.button")
        static let edit = NSToolbarItem.Identifier("entry-detail.edit")
        static let search = NSToolbarItem.Identifier("workspace.search")
    }

    /// Database-scoped items are navigational, so they lead, before the window
    /// title; Edit and search stay at the trailing edge, over the detail, where
    /// Edit reads as acting on the selected entry.
    static let navigationalItems: [NSToolbarItem.Identifier] = [
        Item.toggleSidebar, Item.lock, Item.cloudSync, Item.readOnly, Item.add, Item.sort, Item.details, Item.settings,
    ]
    static let itemIdentifiers = navigationalItems + [.flexibleSpace, Item.edit, Item.search]

    let session: DatabaseViewModel
    let toolbar = NSToolbar(identifier: MacWorkspaceToolbar.identifier)
    let searchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    private(set) var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let presentation: MacWorkspacePresentation
    private let observation = MacObservation()
    private var controls: [NSControl] = []
    private var newEntryMenuItems: [NSMenuItem] = []
    private var newGroupMenuItems: [NSMenuItem] = []
    private var sortOrderMenuItems: [NSMenuItem] = []
    private var sortDirectionMenuItems: [NSMenuItem] = []

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation) {
        self.session = session
        self.presentation = presentation
        super.init()
        makeItems()
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
        var canNewGroup: Bool
        var showsEdit: Bool
        var canEditEntry: Bool
        var sortOrder: DatabaseViewModel.SortOrder
        var sortAscending: Bool
        var canSort: Bool
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
            canNewGroup: commands.canNewGroup,
            showsEdit: showsEdit && session.isReadOnly == false,
            canEditEntry: commands.canEditEntry,
            sortOrder: session.sortOrder,
            sortAscending: session.sortAscending,
            canSort: MacEntryListSnapshot.listIsEmpty(session: session) == false,
            searchText: session.searchText,
            databaseName: session.databaseDisplayName
        )
    }

    private func apply(_ state: State) {
        for control in controls { control.isEnabled = state.isSaving == false }
        searchItem.searchField.isEnabled = state.isSaving == false
        enable(Item.lock, state.canLock && state.isSaving == false)
        enable(Item.add, (state.canNewEntry || state.canNewGroup) && state.isSaving == false)
        enable(Item.edit, state.canEditEntry && state.isSaving == false)
        enable(Item.sort, state.canSort && state.isSaving == false)
        items[Item.cloudSync]?.isHidden = state.showsCloudSync == false
        items[Item.readOnly]?.isHidden = state.isReadOnly == false
        items[Item.add]?.isHidden = state.isReadOnly
        items[Item.edit]?.isHidden = state.showsEdit == false
        for item in newEntryMenuItems { item.isEnabled = state.canNewEntry }
        for item in newGroupMenuItems { item.isEnabled = state.canNewGroup }
        for item in sortOrderMenuItems {
            item.state = item.representedObject as? String == state.sortOrder.rawValue ? .on : .off
        }
        for item in sortDirectionMenuItems {
            item.state = item.representedObject as? Bool == state.sortAscending ? .on : .off
        }
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
    @objc private func newGroup(_ sender: Any?) { DatabaseCommands(session: session).newGroup() }
    @objc private func showDatabaseDetails(_ sender: Any?) { presentation.isShowingDatabaseDetails = true }
    @objc private func syncCloudNow(_ sender: Any?) {
        let session = session
        Task { await session.syncCloudNow() }
    }

    @objc private func editEntry(_ sender: Any?) {
        guard let entryID = session.workspace.selectedEntryID else { return }
        presentation.beginEntryEdit(entryID: entryID, in: session)
    }

    @objc private func selectSortOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let order = DatabaseViewModel.SortOrder(rawValue: raw) else { return }
        session.sortOrder = order
    }

    @objc private func selectSortDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        session.sortAscending = ascending
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

    private func makeItems() {
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

        addMenu(Item.add, symbol: "plus", label: String(localized: "Add Entry or Group")) { menu in
            let entry = menuItem(String(localized: "New Entry"), action: #selector(newEntry(_:)))
            entry.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            let group = menuItem(String(localized: "New Group"), action: #selector(newGroup(_:)))
            group.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            newEntryMenuItems.append(entry)
            newGroupMenuItems.append(group)
            menu.addItem(entry)
            menu.addItem(group)
        }
        addMenu(Item.sort, symbol: "arrow.up.arrow.down", label: String(localized: "Sort")) { menu in
            menu.addItem(.sectionHeader(title: String(localized: "Sort By")))
            for order in DatabaseViewModel.SortOrder.allCases {
                let item = menuItem(order.title, action: #selector(selectSortOrder(_:)))
                item.representedObject = order.rawValue
                sortOrderMenuItems.append(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for (title, ascending) in [(String(localized: "Ascending"), true), (String(localized: "Descending"), false)] {
                let item = menuItem(title, action: #selector(selectSortDirection(_:)))
                item.representedObject = ascending
                sortDirectionMenuItems.append(item)
                menu.addItem(item)
            }
        }
        addButton(Item.details, symbol: "info.circle", label: String(localized: "Database Details"),
                  target: self, action: #selector(showDatabaseDetails(_:)))
        addButton(Item.settings, symbol: "gearshape", label: String(localized: "Settings"),
                  target: nil, action: #selector(AppDelegate.showSettings(_:)))

        let editLabel = String(localized: "Edit")
        let edit = NSButton(title: editLabel, target: self, action: #selector(editEntry(_:)))
        edit.bezelStyle = .toolbar
        edit.setAccessibilityIdentifier(Item.edit.rawValue)
        addItem(Item.edit, view: edit, label: editLabel, menuForm: menuItem(editLabel, action: #selector(editEntry(_:))))

        for identifier in Self.navigationalItems { items[identifier]?.isNavigational = true }

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

    private func addMenu(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, build: (NSMenu) -> Void) {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
        popUp.bezelStyle = .toolbar
        popUp.imagePosition = .imageOnly
        (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUp.toolTip = label
        popUp.setAccessibilityLabel(label)
        popUp.setAccessibilityIdentifier(identifier.rawValue)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let face = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        menu.addItem(face)
        build(menu)
        popUp.menu = menu

        let overflow = NSMenu()
        overflow.autoenablesItems = false
        build(overflow)
        addItem(identifier, view: popUp, label: label, menuForm: submenuItem(label, overflow))
        controls.append(popUp)
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

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
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
