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
        static let title = NSToolbarItem.Identifier("workspace.database-title")
        static let sidebarSeparator = NSToolbarItem.Identifier("workspace.sidebar-separator")
        static let listSeparator = NSToolbarItem.Identifier("workspace.list-separator")
    }

    /// The boards' layout: the sidebar toggle over the sidebar, search and New
    /// Entry (the glasses in a read-only database) over the entry list, between
    /// the split's tracking separators, the database's name centred over the
    /// detail, and Edit. The status card's line and buttons join the detail
    /// only while the sidebar is hidden.
    static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        Item.toggleSidebar, Item.sidebarSeparator, Item.search, Item.add, Item.readOnly, Item.listSeparator,
        .flexibleSpace, Item.title, .flexibleSpace,
        Item.edit, Item.databaseStatus, Item.databaseSettings, Item.syncNow, Item.lock,
    ]
    static let statusItemIdentifiers: [NSToolbarItem.Identifier] = [
        Item.databaseStatus, Item.databaseSettings, Item.syncNow, Item.lock,
    ]

    let session: DatabaseViewModel
    let toolbar = NSToolbar(identifier: MacWorkspaceToolbar.identifier)
    let searchItem = NSSearchToolbarItem(itemIdentifier: Item.search)
    let statusLineView = MacStatusLineView()
    let titleView = MacToolbarTitleView()
    private(set) var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let presentation: MacWorkspacePresentation
    private let observation = MacObservation()
    private var controls: [NSControl] = []
    private weak var listPane: NSView?
    private var listFrameObserver: NSObjectProtocol?
    private var detailFrameObserver: NSObjectProtocol?
    private var isSidebarCollapsed = false

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

    isolated deinit {
        for observer in [listFrameObserver, detailFrameObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
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
        isSidebarCollapsed = state.isSidebarCollapsed
        updateSearchFieldWidth()
        if state.status.offersSyncNow == false { items[Item.syncNow]?.isHidden = true }
        statusLineView.update(state.status.line, short: true)
        items[Item.readOnly]?.isHidden = state.isReadOnly == false
        items[Item.add]?.isHidden = state.isReadOnly
        items[Item.edit]?.isHidden = state.showsEdit == false
        titleView.titleField.stringValue = state.databaseName
        titleView.needsLayout = true
        let placeholder = Self.searchPlaceholder(databaseName: state.databaseName)
        if searchItem.searchField.placeholderString != placeholder {
            searchItem.searchField.placeholderString = placeholder
        }
        if searchItem.searchField.stringValue != state.searchText {
            searchItem.searchField.stringValue = state.searchText
        }
    }

    /// The search field takes what the list column leaves beside New Entry (and,
    /// with the sidebar hidden, the window controls and the sidebar toggle), so
    /// focusing it never pushes the list separator and it stays a field.
    static func searchFieldWidth(listWidth: CGFloat, isSidebarCollapsed: Bool) -> CGFloat {
        let neighbours: CGFloat = isSidebarCollapsed ? 36 + 36 + 86 : 36
        return min(max(listWidth - neighbours - 32, 90), 260)
    }

    private func updateSearchFieldWidth() {
        let width = Self.searchFieldWidth(listWidth: listPane?.frame.width ?? 320, isSidebarCollapsed: isSidebarCollapsed)
        if searchItem.preferredWidthForSearchField != width { searchItem.preferredWidthForSearchField = width }
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
        // Plain text beside the buttons' shared background (SidebarHidden board).
        statusItem.isBordered = false
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
        let detailPane = splitView.arrangedSubviews.count > 2 ? splitView.arrangedSubviews[2] : nil
        titleView.centerReference = detailPane
        detailPane?.postsFrameChangedNotifications = true
        if let detailPane {
            detailFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: detailPane, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.titleView.needsLayout = true }
            }
        }
        let titleItem = NSToolbarItem(itemIdentifier: Item.title)
        titleItem.view = titleView
        // Plain text, between flexible spaces.
        titleItem.isBordered = false
        titleItem.label = String(localized: "Database")
        items[Item.title] = titleItem

        listPane = splitView.arrangedSubviews.count > 1 ? splitView.arrangedSubviews[1] : nil
        listPane?.postsFrameChangedNotifications = true
        if let listPane {
            listFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: listPane, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSearchFieldWidth() }
            }
        }
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

/// The database's name in the toolbar, between flexible spaces. Edit and the
/// status items pull that centre off the detail column's, so the name is drawn
/// at the column's centre instead (Main and SidebarHidden boards), past the
/// small view's bounds, which do not clip.
final class MacToolbarTitleView: NSView {
    let titleField = NSTextField(labelWithString: "")
    weak var centerReference: NSView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        clipsToBounds = false
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center
        titleField.setAccessibilityIdentifier(MacWorkspaceToolbar.Item.title.rawValue)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Moving with the toolbar's items moves the column's centre in this view.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = titleField.intrinsicContentSize
        // In the toolbar the measured width clipped the last glyph; centred slack keeps it.
        let width = ceil(size.width) + 16
        var midX = bounds.midX
        if let reference = centerReference, reference.window != nil, reference.window === window {
            midX = convert(NSPoint(x: reference.bounds.midX, y: 0), from: reference).x
        }
        titleField.frame = NSRect(x: midX - width / 2, y: (bounds.height - size.height) / 2,
                                  width: width, height: size.height)
    }
}
