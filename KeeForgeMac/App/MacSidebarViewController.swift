import AppKit
import SwiftUI

/// One outline row, reused for its `MacSidebarItemID` across snapshots so
/// NSOutlineView keeps expansion and selection while the tree changes.
@MainActor
final class MacSidebarOutlineItem: NSObject {
    struct Content: Equatable {
        var title: String
        var icon: MacSidebarIcon?
        var count: Int?
        var accessibilityIdentifier: String?
    }

    let id: MacSidebarItemID
    fileprivate(set) var content = Content(title: "")
    fileprivate(set) var children: [MacSidebarOutlineItem] = []
    fileprivate(set) weak var parent: MacSidebarOutlineItem?

    init(id: MacSidebarItemID) {
        self.id = id
    }

    var isHeader: Bool {
        if case .section = id { true } else { false }
    }

    func isDescendant(of ancestor: MacSidebarOutlineItem) -> Bool {
        var current = parent
        while let item = current {
            if item === ancestor { return true }
            current = item.parent
        }
        return false
    }
}

/// The database window's sidebar: `MacSidebarSnapshot` in a source-list
/// outline, with the status card pinned beneath it. Sheets and confirmations
/// its menu raises stay with `MacWorkspacePresentationHost`.
@MainActor
final class MacSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSMenuItemValidation {
    static let outlineIdentifier = "sidebar.outline"

    let session: DatabaseViewModel
    let outlineView = NSOutlineView()
    let statusCard = MacSidebarStatusCardView()
    private let presentation: MacWorkspacePresentation
    private let observation = MacObservation()
    private var snapshot: MacSidebarSnapshot?
    private var rootItems: [MacSidebarOutlineItem] = []
    private var items: [MacSidebarItemID: MacSidebarOutlineItem] = [:]
    private var isApplyingModel = false
    private var isUserCollapsing = false

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation) {
        self.session = session
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.setAccessibilityIdentifier(Self.outlineIdentifier)
        outlineView.dataSource = self
        outlineView.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let stack = NSStackView(views: [scrollView, statusCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for view in [scrollView, statusCard] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusCard.setContentHuggingPriority(.required, for: .vertical)
        view = stack
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

    override func viewDidAppear() {
        super.viewDidAppear()
        if outlineView.selectedRow >= 0 { outlineView.scrollRowToVisible(outlineView.selectedRow) }
    }

    func item(for id: MacSidebarItemID) -> MacSidebarOutlineItem? {
        items[id]
    }

    // MARK: - Model

    private struct State {
        var snapshot: MacSidebarSnapshot
        var collapsedGroupIDs: Set<UUID>
        var isSaving: Bool
        var status: MacDatabaseStatus?
        var selection: MacSidebarSelection?
    }

    private func readState() -> State {
        State(
            snapshot: MacSidebarSnapshot.make(session: session),
            collapsedGroupIDs: presentation.collapsedGroupIDs,
            isSaving: session.isSaving,
            status: MacDatabaseStatus.make(session: session),
            selection: MacSidebarSelection(workspace: session.workspace)
        )
    }

    private func apply(_ state: State) {
        isApplyingModel = true
        defer { isApplyingModel = false }
        if state.snapshot != snapshot {
            applyTree(state.snapshot)
            snapshot = state.snapshot
        }
        applyExpansion(to: rootItems, collapsed: state.collapsedGroupIDs)
        selectModelRow()
        outlineView.isEnabled = state.isSaving == false
        statusCard.update(state.status)
    }

    // MARK: - Tree updates

    private struct Node {
        let id: MacSidebarItemID
        let content: MacSidebarOutlineItem.Content
        let children: [Node]
    }

    static func headerTitle(for kind: MacSidebarSnapshot.SectionKind) -> String? {
        switch kind {
        case .library: String(localized: "Library")
        case .groups: String(localized: "Groups")
        case .tags: String(localized: "Tags")
        case .recycleBin: nil
        }
    }

    private static func nodes(for snapshot: MacSidebarSnapshot) -> [Node] {
        func convert(_ node: MacSidebarSnapshot.Node) -> Node {
            Node(
                id: node.id,
                content: .init(title: node.title, icon: node.icon, count: node.count,
                               accessibilityIdentifier: node.accessibilityIdentifier),
                children: node.children.map(convert)
            )
        }
        return snapshot.sections.flatMap { section -> [Node] in
            let nodes = section.nodes.map(convert)
            guard let title = headerTitle(for: section.kind) else { return nodes }
            return [Node(id: section.id, content: .init(title: title), children: nodes)]
        }
    }

    private struct Changes {
        var reloaded: [MacSidebarOutlineItem] = []
        var reloadedWithChildren: [MacSidebarOutlineItem] = []
        var inserted: Set<ObjectIdentifier> = []
    }

    private func applyTree(_ snapshot: MacSidebarSnapshot) {
        let nodes = Self.nodes(for: snapshot)
        var changes = Changes()
        if self.snapshot == nil {
            rootItems = nodes.map { materialize($0, parent: nil, changes: &changes) }
            outlineView.reloadData()
        } else {
            var newParents: [MacSidebarItemID: MacSidebarItemID?] = [:]
            func index(_ nodes: [Node], parent: MacSidebarItemID?) {
                for node in nodes {
                    newParents[node.id] = .some(parent)
                    index(node.children, parent: node.id)
                }
            }
            index(nodes, parent: nil)

            // Everything that leaves its parent goes first, so a group moved
            // elsewhere is never in two places while the rest is arranged.
            outlineView.beginUpdates()
            removeMisplaced(under: nil, isLive: true, newParents: newParents, changes: &changes)
            arrange(under: nil, nodes: nodes, isLive: true, changes: &changes)
            outlineView.endUpdates()
            for item in changes.reloadedWithChildren { outlineView.reloadItem(item, reloadChildren: true) }
            for item in changes.reloaded { outlineView.reloadItem(item, reloadChildren: false) }
        }
        var live: [MacSidebarItemID: MacSidebarOutlineItem] = [:]
        func collect(_ items: [MacSidebarOutlineItem]) {
            for item in items {
                live[item.id] = item
                collect(item.children)
            }
        }
        collect(rootItems)
        items = live
    }

    private func children(of parent: MacSidebarOutlineItem?) -> [MacSidebarOutlineItem] {
        parent?.children ?? rootItems
    }

    private func setChildren(_ children: [MacSidebarOutlineItem], of parent: MacSidebarOutlineItem?) {
        if let parent { parent.children = children } else { rootItems = children }
    }

    /// `isLive` is false below a collapsed row: the outline has no rows there
    /// to update, so the model changes alone and the parent reloads after.
    private func removeMisplaced(
        under parent: MacSidebarOutlineItem?,
        isLive: Bool,
        newParents: [MacSidebarItemID: MacSidebarItemID?],
        changes: inout Changes
    ) {
        var current = children(of: parent)
        let removed = IndexSet(current.indices.filter { index in
            guard let newParent = newParents[current[index].id] else { return true }
            return newParent != parent?.id
        })
        if removed.isEmpty == false {
            for index in removed.reversed() { current.remove(at: index) }
            setChildren(current, of: parent)
            if isLive { outlineView.removeItems(at: removed, inParent: parent, withAnimation: []) }
            if let parent, isLive == false || current.isEmpty { changes.reloadedWithChildren.append(parent) }
        }
        for child in current {
            removeMisplaced(under: child, isLive: isLive && outlineView.isItemExpanded(child),
                            newParents: newParents, changes: &changes)
        }
    }

    private func arrange(under parent: MacSidebarOutlineItem?, nodes: [Node], isLive: Bool, changes: inout Changes) {
        var current = children(of: parent)
        let wasEmpty = current.isEmpty
        var didChange = false
        for (index, node) in nodes.enumerated() {
            if index < current.count, current[index].id == node.id { continue }
            didChange = true
            if let from = current.firstIndex(where: { $0.id == node.id }) {
                current.insert(current.remove(at: from), at: index)
                setChildren(current, of: parent)
                if isLive { outlineView.moveItem(at: from, inParent: parent, to: index, inParent: parent) }
            } else {
                current.insert(materialize(node, parent: parent, changes: &changes), at: index)
                setChildren(current, of: parent)
                if isLive { outlineView.insertItems(at: [index], inParent: parent, withAnimation: []) }
            }
        }
        if let parent, didChange, isLive == false || wasEmpty != current.isEmpty {
            changes.reloadedWithChildren.append(parent)
        }
        for (item, node) in zip(current, nodes) where changes.inserted.contains(ObjectIdentifier(item)) == false {
            if item.content != node.content {
                item.content = node.content
                changes.reloaded.append(item)
            }
            arrange(under: item, nodes: node.children, isLive: isLive && outlineView.isItemExpanded(item),
                    changes: &changes)
        }
    }

    private func materialize(_ node: Node, parent: MacSidebarOutlineItem?, changes: inout Changes) -> MacSidebarOutlineItem {
        let item = items[node.id] ?? MacSidebarOutlineItem(id: node.id)
        item.parent = parent
        item.content = node.content
        changes.inserted.insert(ObjectIdentifier(item))
        item.children = node.children.map { materialize($0, parent: item, changes: &changes) }
        return item
    }

    // MARK: - Expansion and selection

    private func shouldExpand(_ item: MacSidebarOutlineItem, collapsed: Set<UUID>) -> Bool {
        if case .group(let groupID) = item.id { collapsed.contains(groupID) == false } else { true }
    }

    private func applyExpansion(to items: [MacSidebarOutlineItem], collapsed: Set<UUID>) {
        for item in items where item.children.isEmpty == false {
            if shouldExpand(item, collapsed: collapsed) {
                if outlineView.isItemExpanded(item) == false { outlineView.expandItem(item) }
                applyExpansion(to: item.children, collapsed: collapsed)
            } else if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            }
        }
    }

    private var modelItem: MacSidebarOutlineItem? {
        MacSidebarSelection(workspace: session.workspace).flatMap { items[$0.itemID] }
    }

    /// Selects the workspace's row, unfolding its ancestors so a reveal shows it.
    private func selectModelRow() {
        guard let item = modelItem else { return }
        var ancestors: [MacSidebarOutlineItem] = []
        var current = item.parent
        while let ancestor = current {
            ancestors.insert(ancestor, at: 0)
            current = ancestor.parent
        }
        var collapsed = presentation.collapsedGroupIDs
        for ancestor in ancestors {
            if case .group(let groupID) = ancestor.id { collapsed.remove(groupID) }
            if outlineView.isItemExpanded(ancestor) == false { outlineView.expandItem(ancestor) }
        }
        if collapsed != presentation.collapsedGroupIDs { presentation.collapsedGroupIDs = collapsed }
        let row = outlineView.row(forItem: item)
        guard row >= 0, outlineView.selectedRowIndexes != IndexSet(integer: row) else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Scrolling before the first layout would keep the top rows scrolled away.
        if outlineView.visibleRect.isEmpty == false { outlineView.scrollRowToVisible(row) }
    }

    private func restoreModelSelection() {
        isApplyingModel = true
        defer { isApplyingModel = false }
        selectModelRow()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? MacSidebarOutlineItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? MacSidebarOutlineItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MacSidebarOutlineItem)?.children.isEmpty == false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? MacSidebarOutlineItem)?.isHeader == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? MacSidebarOutlineItem)?.id.selection != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? MacSidebarOutlineItem)?.isHeader == false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? MacSidebarOutlineItem)?.isHeader == false
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let item = item as? MacSidebarOutlineItem, item.isHeader == false else { return nil }
        return item.content.title
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? MacSidebarOutlineItem else { return nil }
        if item.isHeader {
            let cell = outlineView.makeView(withIdentifier: MacSidebarHeaderCellView.reuseIdentifier, owner: self)
                as? MacSidebarHeaderCellView ?? MacSidebarHeaderCellView()
            cell.textField?.stringValue = item.content.title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: MacSidebarCellView.reuseIdentifier, owner: self)
            as? MacSidebarCellView ?? MacSidebarCellView()
        cell.configure(item.content)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard isApplyingModel == false, isUserCollapsing == false else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let selection = (outlineView.item(atRow: row) as? MacSidebarOutlineItem)?.id.selection else {
            restoreModelSelection()
            return
        }
        if MacSidebarSelection(workspace: session.workspace) != selection {
            selection.apply(to: session.workspace)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard isApplyingModel == false,
              let item = notification.userInfo?["NSObject"] as? MacSidebarOutlineItem,
              case .group(let groupID) = item.id else { return }
        presentation.collapsedGroupIDs.remove(groupID)
        isApplyingModel = true
        defer { isApplyingModel = false }
        applyExpansion(to: item.children, collapsed: presentation.collapsedGroupIDs)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard isApplyingModel == false else { return }
        isUserCollapsing = true
    }

    /// A selection folded away moves to the folded group, as Finder and Mail do.
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard isApplyingModel == false else { return }
        isUserCollapsing = false
        guard let item = notification.userInfo?["NSObject"] as? MacSidebarOutlineItem,
              case .group(let groupID) = item.id else { return }
        presentation.collapsedGroupIDs.insert(groupID)
        if let selected = modelItem, selected.isDescendant(of: item) {
            MacSidebarSelection.group(groupID).apply(to: session.workspace)
        }
        restoreModelSelection()
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? MacSidebarOutlineItem,
              case .group(let groupID) = item.id else { return }
        for menuItem in contextMenuItems(forGroupID: groupID) { menu.addItem(menuItem) }
    }

    func contextMenuItems(forGroupID groupID: UUID) -> [NSMenuItem] {
        let actions = MacSidebarGroupActions(groupID: groupID, session: session)
        var menuItems: [NSMenuItem] = []
        func add(_ title: String, _ identifier: String, _ action: Selector, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = groupID
            item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menuItems.append(item)
        }
        if actions.canAddSubgroup {
            add(String(localized: "New Subgroup"), MacSidebarGroupActions.newSubgroupIdentifier, #selector(newSubgroup(_:)))
        }
        if actions.canEdit {
            add(String(localized: "Edit Group"), MacSidebarGroupActions.editIdentifier, #selector(editGroup(_:)))
        }
        if actions.canRestore {
            add(String(localized: "Restore"), MacSidebarGroupActions.restoreIdentifier, #selector(restoreGroup(_:)),
                symbol: "arrow.uturn.backward")
        }
        if actions.canMove {
            add(String(localized: "Move to Group"), MacSidebarGroupActions.moveIdentifier, #selector(moveGroup(_:)))
        }
        if actions.canDelete {
            add(actions.deleteTitle, actions.deleteAccessibilityIdentifier, #selector(deleteGroup(_:)))
        }
        return menuItems
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let groupID = menuItem.representedObject as? UUID else { return false }
        let actions = MacSidebarGroupActions(groupID: groupID, session: session)
        switch menuItem.action {
        case #selector(newSubgroup(_:)): return actions.canAddSubgroup
        case #selector(editGroup(_:)): return actions.canEdit
        case #selector(restoreGroup(_:)): return actions.canRestore
        case #selector(moveGroup(_:)): return actions.canMove
        case #selector(deleteGroup(_:)): return actions.canDelete
        default: return false
        }
    }

    private func validatedGroupID(_ sender: NSMenuItem) -> UUID? {
        guard validateMenuItem(sender) else { return nil }
        return sender.representedObject as? UUID
    }

    @objc private func newSubgroup(_ sender: NSMenuItem) {
        guard let groupID = validatedGroupID(sender) else { return }
        presentation.beginNewGroup(parentID: groupID)
    }

    @objc private func editGroup(_ sender: NSMenuItem) {
        guard let groupID = validatedGroupID(sender) else { return }
        presentation.beginGroupEdit(groupID: groupID, in: session)
    }

    @objc private func restoreGroup(_ sender: NSMenuItem) {
        guard let groupID = validatedGroupID(sender) else { return }
        PendingMove.restoreOrChooseDestination(.group(groupID), viewModel: session) { [presentation] in
            presentation.pendingMove = $0
        }
    }

    @objc private func moveGroup(_ sender: NSMenuItem) {
        guard let groupID = validatedGroupID(sender) else { return }
        presentation.pendingMove = .group(groupID)
    }

    @objc private func deleteGroup(_ sender: NSMenuItem) {
        guard let groupID = validatedGroupID(sender),
              let pending = PendingGroupDeletion(groupID: groupID, viewModel: session) else { return }
        presentation.pendingDeletion = .group(pending)
    }
}

private extension MacSidebarSelection {
    var itemID: MacSidebarItemID {
        switch self {
        case .collection(let collection): .collection(collection)
        case .group(let groupID): .group(groupID)
        case .tag(let tag): .tag(tag)
        }
    }
}

// MARK: - Cells

final class MacSidebarHeaderCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("sidebar.header")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class MacSidebarCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("sidebar.row")
    static let iconSize: CGFloat = 18

    let countField = NSTextField(labelWithString: "")
    private var icon: MacSidebarIcon?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.textColor = .secondaryLabelColor
        countField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countField.alignment = .right
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        countField.setContentHuggingPriority(.required, for: .horizontal)
        for view in [image, title, countField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = image
        textField = title
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: Self.iconSize),
            image.heightAnchor.constraint(equalToConstant: Self.iconSize),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            countField.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshIcon() }
    }

    func configure(_ content: MacSidebarOutlineItem.Content) {
        icon = content.icon
        textField?.stringValue = content.title
        countField.stringValue = content.count?.formatted() ?? ""
        countField.isHidden = content.count == nil
        toolTip = content.title
        // XCUITest drops a table cell's own identifier, so the title carries it.
        textField?.setAccessibilityIdentifier(content.accessibilityIdentifier)
        setAccessibilityLabel(content.title)
        setAccessibilityValue(content.count?.formatted())
        refreshIcon()
    }

    private func refreshIcon() {
        imageView?.image = icon.flatMap {
            Self.image(for: $0, emphasized: backgroundStyle == .emphasized)
        }
    }

    /// The recycle bin and missing custom images fall back as `GroupIconView` does.
    static func image(for icon: MacSidebarIcon, emphasized: Bool) -> NSImage? {
        switch icon {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .standard(let iconID):
            return standardImage(iconID, emphasized: emphasized)
        case .custom(let data, let standardIconID):
            return MacIconImages.custom(data, size: iconSize) ?? standardImage(standardIconID, emphasized: emphasized)
        }
    }

    private static func standardImage(_ iconID: Int, emphasized: Bool) -> NSImage? {
        MacIconImages.standard(iconID, fallbackSymbol: "folder.fill", fallbackPalette: .blue, pointSize: 14,
                               emphasized: emphasized)
    }
}

// MARK: - Status card

/// The sidebar's status lines (`MacDatabaseStatus`), hidden when there are none.
final class MacSidebarStatusCardView: NSView {
    static let identifier = "sidebar.status-card"

    private(set) var status: MacDatabaseStatus?
    private let box = NSBox()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.identifier)

        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 8
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.contentView = stack
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One row per status line: its symbol and its text.
    var lineViews: [(symbol: NSImageView, text: NSTextField)] {
        stack.arrangedSubviews.compactMap { row in
            guard let row = row as? NSStackView, row.arrangedSubviews.count == 2,
                  let symbol = row.arrangedSubviews[0] as? NSImageView,
                  let text = row.arrangedSubviews[1] as? NSTextField else { return nil }
            return (symbol, text)
        }
    }

    func update(_ status: MacDatabaseStatus?) {
        guard status != self.status else { return }
        self.status = status
        isHidden = status == nil
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for line in status?.lines ?? [] {
            let symbol = NSImageView(image: NSImage(systemSymbolName: line.systemImage, accessibilityDescription: nil)
                ?? NSImage())
            symbol.contentTintColor = switch line.tone {
            case .warning: NSColor(Theme.State.warning)
            case .neutral: .secondaryLabelColor
            }
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            let text = NSTextField(wrappingLabelWithString: line.text)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            let row = NSStackView(views: [symbol, text])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            stack.addArrangedSubview(row)
        }
        setAccessibilityLabel(status?.lines.map(\.text).joined(separator: "\n"))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (_, text) in lineViews where text.preferredMaxLayoutWidth != text.frame.width {
            text.preferredMaxLayoutWidth = text.frame.width
        }
    }
}
