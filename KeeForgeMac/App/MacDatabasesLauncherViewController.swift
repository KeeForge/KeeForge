import AppKit

/// The Databases window's content: a brand panel with the three add actions
/// beside the list of databases and its add and remove buttons. Sheets and
/// confirmations it asks for are presented by the SwiftUI host around it.
@MainActor
final class MacDatabasesLauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate {
    static let brandPanelWidth: CGFloat = 260
    static let rowHeight: CGFloat = 56
    static let rowWithDetailHeight: CGFloat = 70
    static let tableIdentifier = "databases.list"

    let launcher: MacDatabasesLauncherViewModel
    let tableView = MacLauncherTableView()
    let newDatabaseButton = MacLauncherActionButton(title: String(localized: "New Database…"), symbol: "plus",
        shortcut: "⌥⌘N", identifier: "databases.create-new", action: #selector(AppDelegate.newDatabase(_:)))
    let openFileButton = MacLauncherActionButton(title: String(localized: "Open Database File…"), symbol: "folder",
        shortcut: "⌘O", identifier: "databases.add-existing", action: #selector(AppDelegate.openDatabase(_:)))
    let connectButton = MacLauncherActionButton(title: String(localized: "Connect to Server…"),
        symbol: "server.rack", shortcut: nil, identifier: "databases.connect-server",
        action: #selector(AppDelegate.connectToServer(_:)))
    let addButton = NSButton()
    let removeButton = NSButton()
    let listLabel = NSTextField(labelWithString: String(localized: "Databases"))
    let versionField = NSTextField(labelWithString: "")
    let emptyStateView = MacLauncherEmptyStateView()
    private let scrollView = NSScrollView()
    private let observation = MacObservation()
    private(set) var rows: [MacDatabasesLauncherViewModel.Row] = []
    private var isApplyingModel = false

    init(launcher: MacDatabasesLauncherViewModel) {
        self.launcher = launcher
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let brandPanel = makeBrandPanel()
        let listPanel = makeListPanel()
        let root = NSView()
        for panel in [brandPanel, listPanel] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(panel)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            brandPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            brandPanel.topAnchor.constraint(equalTo: root.topAnchor),
            brandPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            brandPanel.widthAnchor.constraint(equalToConstant: Self.brandPanelWidth),
            divider.leadingAnchor.constraint(equalTo: brandPanel.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            listPanel.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            listPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listPanel.topAnchor.constraint(equalTo: root.topAnchor),
            listPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] state in
            guard let state else { return }
            self?.apply(state)
        })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The one column follows the table's width; without it the column keeps its 100 pt default.
        tableView.sizeLastColumnToFit()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Return opens the selection only while the list has focus.
        if view.window?.firstResponder === view.window { view.window?.makeFirstResponder(tableView) }
    }

    // MARK: - Layout

    private func makeBrandPanel() -> NSView {
        let panel = NSVisualEffectView()
        panel.material = .sidebar
        panel.blendingMode = .behindWindow
        panel.state = .followsWindowActiveState

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
        ])
        let name = NSTextField(labelWithString: "KeeForge")
        name.font = .systemFont(ofSize: 26, weight: .bold)
        versionField.stringValue = Self.versionText(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        versionField.font = .systemFont(ofSize: 12)
        versionField.textColor = .secondaryLabelColor
        let brand = NSStackView(views: [icon, name, versionField])
        brand.orientation = .vertical
        brand.alignment = .centerX
        brand.spacing = 6
        brand.setCustomSpacing(12, after: icon)

        let actions = NSStackView(views: [newDatabaseButton, openFileButton, connectButton])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 2
        for button in [newDatabaseButton, openFileButton, connectButton] {
            button.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        }

        for view in [brand, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: panel.topAnchor, constant: 98),
            brand.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            actions.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            actions.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            actions.topAnchor.constraint(greaterThanOrEqualTo: brand.bottomAnchor, constant: 16),
        ])
        return panel
    }

    private func makeListPanel() -> NSView {
        listLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        listLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("database"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier(Self.tableIdentifier)
        tableView.setAccessibilityLabel(String(localized: "Databases"))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedDatabase(_:))
        tableView.onOpen = { [weak self] in self?.launcher.openSelection() }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        configureSquareButton(addButton, symbol: "plus", label: String(localized: "Add Database"),
            identifier: "database.add.button", action: #selector(showAddMenu(_:)))
        configureSquareButton(removeButton, symbol: "minus", label: String(localized: "Remove Database from List"),
            identifier: "databases.remove", action: #selector(removeSelectedDatabase(_:)))
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = -1
        let bottomBar = NSView()
        let barDivider = NSBox()
        barDivider.boxType = .separator
        for view in [buttons, barDivider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(view)
        }

        let panel = NSView()
        for view in [listLabel, scrollView, emptyStateView, bottomBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        NSLayoutConstraint.activate([
            listLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            listLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            scrollView.topAnchor.constraint(equalTo: listLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 40),
            bottomBar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 44),
            barDivider.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            barDivider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            barDivider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            buttons.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            buttons.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
        return panel
    }

    private func configureSquareButton(_ button: NSButton, symbol: String, label: String, identifier: String,
                                       action: Selector) {
        button.bezelStyle = .smallSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.title = ""
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    static func versionText(_ version: String?) -> String {
        String(localized: "Version \(version ?? "–")")
    }

    // MARK: - Model

    private struct State: Equatable {
        var rows: [MacDatabasesLauncherViewModel.Row]
        var selectedID: UUID?
        var emptyState: MacDatabasesLauncherViewModel.EmptyState?
        var canRemove: Bool
        var connectCaption: String
        var canConnect: Bool
    }

    private func readState() -> State {
        State(rows: launcher.rows, selectedID: launcher.selectedDatabaseID, emptyState: launcher.emptyState,
              canRemove: launcher.canRemoveSelection, connectCaption: launcher.connectCaption,
              canConnect: launcher.canConnect)
    }

    private func apply(_ state: State) {
        isApplyingModel = true
        defer { isApplyingModel = false }
        if state.rows != rows {
            rows = state.rows
            tableView.reloadData()
        }
        let row = state.selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        if let row {
            if tableView.selectedRow != row { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
        emptyStateView.show(state.emptyState)
        scrollView.isHidden = state.emptyState != nil
        removeButton.isEnabled = state.canRemove
        connectButton.caption = state.connectCaption
        connectButton.isEnabled = state.canConnect
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && rows[row].detail != nil ? Self.rowWithDetailHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = MacLauncherRowCellView.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MacLauncherRowCellView
            ?? MacLauncherRowCellView()
        cell.identifier = identifier
        cell.configure(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel else { return }
        let row = tableView.selectedRow
        launcher.selectedDatabaseID = rows.indices.contains(row) ? rows[row].id : nil
    }

    @objc func openClickedDatabase(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), let reference = reference(for: rows[row].id) else { return }
        launcher.open(reference)
    }

    private func reference(for id: UUID) -> DatabaseReference? {
        launcher.databases.first { $0.id == id }
    }

    // MARK: - Row menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row), let reference = reference(for: rows[row].id) else { return }
        for item in menuItems(for: reference) { menu.addItem(item) }
    }

    func menuItems(for reference: DatabaseReference) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for action in launcher.rowActions(for: reference) {
            if action == .rename || action == .remove { items.append(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(performRowMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(action.accessibilityIdentifier)
            item.representedObject = MacLauncherRowMenuAction(action: action, databaseID: reference.id)
            switch action {
            case .quickLaunch(let isOn), .readOnly(let isOn): item.state = isOn ? .on : .off
            default: break
            }
            items.append(item)
        }
        return items
    }

    @objc func performRowMenuItem(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MacLauncherRowMenuAction,
              let reference = reference(for: choice.databaseID) else { return }
        launcher.perform(choice.action, on: reference)
    }

    // MARK: - Add and remove

    /// The same three commands as the brand panel and the File menu.
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        for button in [newDatabaseButton, openFileButton, connectButton] {
            let item = NSMenuItem(title: button.commandTitle, action: button.action, keyEquivalent: "")
            item.isEnabled = button.isEnabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc func showAddMenu(_ sender: NSButton) {
        addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func removeSelectedDatabase(_ sender: Any?) {
        launcher.removeSelection()
    }
}

/// What a row-menu item carries back to its action.
final class MacLauncherRowMenuAction: NSObject {
    let action: MacDatabasesLauncherViewModel.RowAction
    let databaseID: UUID

    init(action: MacDatabasesLauncherViewModel.RowAction, databaseID: UUID) {
        self.action = action
        self.databaseID = databaseID
    }
}

/// Return opens the selected database.
@MainActor
final class MacLauncherTableView: NSTableView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return and keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpen?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Brand panel actions

/// One of the brand panel's three actions: a glyph tile, its title with a
/// caption or shortcut, sent to the same nil-targeted command as its menu item.
@MainActor
final class MacLauncherActionButton: NSButton {
    let titleField = NSTextField(labelWithString: "")
    private let captionField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    let tile = NSView()
    /// The command's name; the button draws it itself, so its own title stays empty.
    let commandTitle: String

    var caption: String {
        get { captionField.stringValue }
        set {
            captionField.stringValue = newValue
            captionField.isHidden = newValue.isEmpty
        }
    }

    override var isHighlighted: Bool {
        didSet { layer?.backgroundColor = isHighlighted ? NSColor.quaternaryLabelColor.cgColor : nil }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    init(title: String, symbol: String, shortcut: String?, identifier: String, action: Selector) {
        commandTitle = title
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        imagePosition = .noImage
        self.action = action
        target = nil
        wantsLayer = true
        layer?.cornerRadius = 9
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 7
        tile.layer?.borderWidth = 0.5
        refreshTileColors()
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        glyph.contentTintColor = .controlAccentColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        captionField.font = .systemFont(ofSize: 11)
        captionField.textColor = .secondaryLabelColor
        captionField.isHidden = true
        shortcutField.stringValue = shortcut ?? ""
        shortcutField.font = .systemFont(ofSize: 12)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.isHidden = shortcut == nil
        let labels = NSStackView(views: [titleField, captionField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        let spacer = NSView()
        let row = NSStackView(views: [tile, labels, spacer, shortcutField])
        row.spacing = 12
        // The title gets the room the shortcut does not need, so "File…" keeps its ellipsis.
        row.setCustomSpacing(6, after: labels)
        row.setCustomSpacing(0, after: spacer)
        titleField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.detachesHiddenViews = true
        for view in [titleField, captionField, shortcutField, glyph, tile] { view.setAccessibilityElement(false) }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            tile.widthAnchor.constraint(equalToConstant: 28),
            tile.heightAnchor.constraint(equalToConstant: 28),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTileColors()
    }

    /// Layer colours are fixed when set, so they are resolved again for each appearance.
    private func refreshTileColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tile.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            tile.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// The labels inside are decoration: every click belongs to the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    var shortcut: String { shortcutField.stringValue }
}

// MARK: - Empty state

@MainActor
final class MacLauncherEmptyStateView: NSStackView {
    static let symbolName = "folder.badge.plus"
    let titleField = NSTextField(labelWithString: "")
    let messageField = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        let image = NSImageView(image: NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        image.contentTintColor = .tertiaryLabelColor
        image.setAccessibilityElement(false)
        titleField.font = .systemFont(ofSize: 15, weight: .bold)
        titleField.setAccessibilityIdentifier("databases.empty.title")
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        messageField.preferredMaxLayoutWidth = 260
        messageField.setAccessibilityIdentifier("databases.empty.message")
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        for view in [image, titleField, messageField] { addArrangedSubview(view) }
        setCustomSpacing(10, after: image)
        messageField.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ state: MacDatabasesLauncherViewModel.EmptyState?) {
        isHidden = state == nil
        titleField.stringValue = state?.title ?? ""
        messageField.stringValue = state?.message ?? ""
    }
}

// MARK: - Rows

/// A database row: storage tile, name, "file · storage" and an optional
/// problem or last-opened line, then Quick Launch, Read-Only, Open or locked,
/// and Touch ID. The row identifier sits on the title text for XCUITest.
@MainActor
final class MacLauncherRowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("database.row.cell")
    static let titleIdentifier = "database.row"

    let tile = NSView()
    let glyph = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let detailIcon = NSImageView()
    let quickLaunchBadge = MacLauncherPill(text: String(localized: "Quick Launch"),
        identifier: "database-row.quick-launch-badge")
    let readOnlyBadge = MacLauncherPill(text: String(localized: "Read-only"), identifier: "database-row.read-only-badge")
    let openState = NSTextField(labelWithString: String(localized: "database-state.open", defaultValue: "Open"))
    let openDot = NSView()
    private(set) var openStack = NSStackView()
    let touchIDImage = NSImageView()
    let lockImage = NSImageView()
    private var detailIsProblem = false

    init() {
        super.init(frame: .zero)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier(Self.titleIdentifier)
        textField = titleField
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.setAccessibilityIdentifier("database-row.subtitle")
        detailField.font = .systemFont(ofSize: 11)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setAccessibilityIdentifier("database-row.detail")
        detailIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        detailIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        detailIcon.setAccessibilityElement(false)
        let detailRow = NSStackView(views: [detailIcon, detailField])
        detailRow.spacing = 4
        detailRow.detachesHiddenViews = true
        let labels = NSStackView(views: [titleField, subtitleField, detailRow])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.detachesHiddenViews = true
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for field in [titleField, subtitleField, detailField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        openDot.wantsLayer = true
        openDot.layer?.cornerRadius = 3.5
        openDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        openState.font = .systemFont(ofSize: 12, weight: .semibold)
        openState.setAccessibilityIdentifier("database-row.open")
        openStack = NSStackView(views: [openDot, openState])
        openStack.spacing = 5
        touchIDImage.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: String(localized: "Touch ID available"))
        touchIDImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        touchIDImage.setAccessibilityIdentifier("database-row.touch-id")
        lockImage.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: String(localized: "Locked"))
        lockImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        lockImage.setAccessibilityIdentifier("database-row.locked")
        let trailing = NSStackView(views: [quickLaunchBadge, readOnlyBadge, openStack, touchIDImage, lockImage])
        trailing.spacing = 10
        trailing.detachesHiddenViews = true
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        for view in [tile, labels, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            openDot.widthAnchor.constraint(equalToConstant: 7),
            openDot.heightAnchor.constraint(equalToConstant: 7),
            labels.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    private var isEmphasized: Bool { backgroundStyle == .emphasized }

    func configure(_ row: MacDatabasesLauncherViewModel.Row) {
        titleField.stringValue = row.title
        subtitleField.stringValue = row.subtitle
        glyph.image = NSImage(systemSymbolName: row.storage == .server ? "server.rack" : "laptopcomputer",
            accessibilityDescription: nil)
        detailField.stringValue = row.detail?.text ?? ""
        detailField.isHidden = row.detail == nil
        if case .problem = row.detail { detailIsProblem = true } else { detailIsProblem = false }
        detailIcon.isHidden = !detailIsProblem
        quickLaunchBadge.isHidden = !row.isQuickLaunch
        readOnlyBadge.isHidden = !row.isReadOnly
        openStack.isHidden = !row.isUnlocked
        lockImage.isHidden = row.isUnlocked
        touchIDImage.isHidden = !row.offersTouchID
        let state = row.isUnlocked ? openState.stringValue : String(localized: "Locked")
        setAccessibilityLabel([row.title, row.subtitle, row.detail?.text, state].compactMap(\.self)
            .joined(separator: ", "))
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let emphasized = isEmphasized
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tile.layer?.backgroundColor = (emphasized ? NSColor.white.withAlphaComponent(0.22) : NSColor.quaternaryLabelColor).cgColor
        }
        glyph.contentTintColor = emphasized ? .white : .secondaryLabelColor
        titleField.textColor = emphasized ? .white : .labelColor
        subtitleField.textColor = emphasized ? .white.withAlphaComponent(0.82) : .secondaryLabelColor
        let problem = NSColor.systemOrange
        detailField.textColor = emphasized ? .white.withAlphaComponent(0.82) : detailIsProblem ? problem : .secondaryLabelColor
        detailIcon.contentTintColor = emphasized ? .white : problem
        openState.textColor = emphasized ? .white : .systemGreen
        touchIDImage.contentTintColor = emphasized ? .white : .secondaryLabelColor
        lockImage.contentTintColor = emphasized ? .white : .secondaryLabelColor
        quickLaunchBadge.isEmphasized = emphasized
        readOnlyBadge.isEmphasized = emphasized
    }
}

/// The accent capsule for Quick Launch and Read-Only.
@MainActor
final class MacLauncherPill: NSView {
    let textField = NSTextField(labelWithString: "")

    var isEmphasized = false {
        didSet { refreshColors() }
    }

    init(text: String, identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        textField.stringValue = text.localizedUppercase
        textField.font = .systemFont(ofSize: 10, weight: .bold)
        textField.setAccessibilityElement(false)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        setAccessibilityIdentifier(identifier)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refreshColors() {
        textField.textColor = isEmphasized ? .white : .controlAccentColor
        layer?.backgroundColor = (isEmphasized ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.controlAccentColor.withAlphaComponent(0.14)).cgColor
    }
}
