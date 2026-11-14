import AppKit
import SwiftUI

/// The database window's entry list: `MacEntryListSnapshot` in a view-based
/// table under its header (title, count line and Sort), with the empty state,
/// the footer hint and the UI-test result count. Sheets and confirmations its
/// menu raises stay with `MacWorkspacePresentationHost`.
@MainActor
final class MacEntryListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSMenuItemValidation {
    static let rowHeight: CGFloat = 40
    static let rowWithFolderHeight: CGFloat = 56

    let session: DatabaseViewModel
    let tableView = MacEntryTableView()
    let scrollView = NSScrollView()
    let emptyView = MacEntryListEmptyView()
    let header = MacEntryListHeaderView()
    let notices = MacWorkspaceNoticesView()
    let resultCountField = NSTextField(labelWithString: "")
    let footerField = NSTextField(wrappingLabelWithString: "")
    /// Whether a click extends the selection; reads the current event's modifiers.
    var isExtendingSelection: @MainActor () -> Bool = {
        NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty == false
    }
    var copyToClipboard: @MainActor (String) -> Void = { ClipboardService.copy($0) }
    /// Nil uses the session's device-owner gate.
    var authenticatePassword: (@MainActor () async throws -> Void)?

    private let presentation: MacWorkspacePresentation
    private let currentSession: @MainActor () -> DatabaseViewModel?
    private let showsResultCount: Bool
    private let loadFavicon: @MainActor (String) async -> PlatformImage?
    private let passwordCopyAction = EntrySecretAction()
    private let observation = MacObservation()
    private let noticeObservation = MacObservation()
    private let codeClock: MacVerificationCodeClock
    /// The one timer that redraws the visible codes while Verification Codes is on screen.
    private(set) var verificationCodeTimer: Timer?
    /// Every code cell made, reuse queue included, so stopping can blank them all.
    private let codeCells = NSHashTable<MacVerificationCodeCellView>.weakObjects()
    private var isOnScreen = false
    private var isUnlocked = false
    private(set) var snapshot: MacEntryListSnapshot?
    private var rows: [MacEntryListSnapshot.Row] = []
    private var contentRevision: Int?
    private var copied: MacCopyFeedback.Copied?
    private var isApplyingModel = false

    /// `currentSession` answers, after authentication, which session the window still shows.
    init(
        session: DatabaseViewModel,
        presentation: MacWorkspacePresentation,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        showsResultCount: Bool = MacEntryListViewController.isUITestingResultCountEnabled,
        codeClock: MacVerificationCodeClock = MacVerificationCodeClock(),
        loadFavicon: @escaping @MainActor (String) async -> PlatformImage? = { await FaviconService.favicon(for: $0) }
    ) {
        self.session = session
        self.presentation = presentation
        self.currentSession = currentSession
        self.showsResultCount = showsResultCount
        self.codeClock = codeClock
        self.loadFavicon = loadFavicon
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        verificationCodeTimer?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static var isUITestingResultCountEnabled: Bool {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-ui-testing")
            && processInfo.environment["UI_TEST_HIDE_SEARCH_RESULTS_COUNT"] != "1"
        #else
        return false
        #endif
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entries"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.onOpen = { [weak self] in self?.openSelectedEntry() ?? false }
        tableView.onCancel = { [weak self] in self?.cancelSelection() ?? false }
        // Rows drag only onto this window's sidebar; other apps are offered nothing.
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyView.isHidden = true
        resultCountField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        resultCountField.drawsBackground = true
        resultCountField.backgroundColor = .windowBackgroundColor
        resultCountField.setAccessibilityIdentifier("search.results.count")
        resultCountField.isHidden = true

        let content = NSView()
        for view in [scrollView, emptyView, resultCountField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [scrollView, emptyView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            resultCountField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            resultCountField.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        footerField.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 2)
        footerField.textColor = .secondaryLabelColor
        // The column is never narrower than 260 pt; a fixed wrap width keeps layout to one pass.
        footerField.preferredMaxLayoutWidth = 220
        let footer = NSView()
        footer.isHidden = true
        footerField.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerField)
        NSLayoutConstraint.activate([
            footerField.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            footerField.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -20),
            footerField.topAnchor.constraint(equalTo: footer.topAnchor, constant: 10),
            footerField.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -14),
        ])

        emptyView.onNewEntry = { [weak self] in
            guard let self, snapshot?.offersNewEntry == true else { return }
            presentation.beginNewEntry(in: session)
        }
        header.onSortOrder = { [weak self] in self?.selectSortOrder($0) }
        header.onSortDirection = { [weak self] in self?.selectSortDirection($0) }

        let stack = NSStackView(views: [content, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for view in [content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)

        // The notices and header sit under the toolbar, so the rows below need no titlebar inset.
        let container = NSView()
        for view in [notices, header, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            notices.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            notices.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            notices.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            notices.bottomAnchor.constraint(equalTo: header.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation.start(reading: { [weak self] in
            self?.readState()
        }, onChange: { [weak self] state in
            guard let state else { return }
            self?.apply(state)
        })
        notices.onAction = { [weak self] action in
            guard let self else { return }
            MacDatabaseStatusActions(session: session, presentation: presentation).perform(action, from: view.window)
        }
        noticeObservation.start(reading: { [weak self] () -> [MacDatabaseStatus.Notice]? in
            guard let self else { return nil }
            return MacDatabaseStatus.make(session: session, presentation: presentation).notices
        }, onChange: { [weak self] notices in
            guard let notices else { return }
            self?.notices.update(notices)
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isOnScreen = true
        updateVerificationCodeTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isOnScreen = false
        updateVerificationCodeTimer()
    }

    // MARK: - Model

    private struct State {
        var snapshot: MacEntryListSnapshot
        var selectedEntryID: UUID?
        var entrySelection: Set<UUID>?
        var isSaving: Bool
        var isUnlocked: Bool
        var contentRevision: Int
        var copied: MacCopyFeedback.Copied?
        var sortOrder: DatabaseViewModel.SortOrder
        var sortAscending: Bool
    }

    private func readState() -> State {
        State(
            snapshot: MacEntryListSnapshot.make(session: session, isSidebarCollapsed: presentation.isSidebarCollapsed),
            selectedEntryID: session.workspace.selectedEntryID,
            entrySelection: session.workspace.entrySelection,
            isSaving: session.isSaving,
            isUnlocked: session.state == .unlocked,
            contentRevision: session.contentRevision,
            copied: presentation.copyFeedback.copied,
            sortOrder: session.sortOrder,
            sortAscending: session.sortAscending
        )
    }

    private func apply(_ state: State) {
        isApplyingModel = true
        defer { isApplyingModel = false }
        let old = snapshot
        let new = state.snapshot
        let oldCopied = copied
        snapshot = new
        isUnlocked = state.isUnlocked
        copied = state.copied
        let isNewList = old.map {
            Self.isSameList($0.mode, new.mode) == false || $0.showsVerificationCodes != new.showsVerificationCodes
        } ?? true
        if isNewList {
            rows = new.rows
            tableView.reloadData()
            if rows.isEmpty == false, tableView.visibleRect.isEmpty == false { tableView.scrollRowToVisible(0) }
        } else if rows != new.rows {
            applyRowChanges(new.rows, refreshingAll: contentRevision != state.contentRevision)
        } else if contentRevision != state.contentRevision {
            refreshCells { _ in true }
        }
        contentRevision = state.contentRevision
        if oldCopied != state.copied {
            let changed = Set([oldCopied?.entryID, state.copied?.entryID].compactMap(\.self))
            refreshCells { changed.contains($0.id) }
            if let copied = state.copied { announce(copied.field.copiedLabel) }
        }
        if state.isUnlocked == false, state.copied != nil { presentation.copyFeedback.clear() }
        selectModelRows()
        tableView.isEnabled = state.isSaving == false
        updateChrome(state)
        updateVerificationCodeTimer()
    }

    /// Typing a query keeps the results' table; any other switch is a new list.
    private static func isSameList(_ lhs: MacEntryListSnapshot.Mode, _ rhs: MacEntryListSnapshot.Mode) -> Bool {
        if case .search = lhs, case .search = rhs { return true }
        return lhs == rhs
    }

    /// Removes, moves and inserts rows in place, so unchanged rows keep their
    /// views, the selection and the scroll position.
    private func applyRowChanges(_ newRows: [MacEntryListSnapshot.Row], refreshingAll: Bool) {
        let newIDs = Set(newRows.map(\.id))
        let oldByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tableView.beginUpdates()
        let removed = IndexSet(rows.indices.filter { newIDs.contains(rows[$0].id) == false })
        if removed.isEmpty == false {
            for index in removed.reversed() { rows.remove(at: index) }
            tableView.removeRows(at: removed, withAnimation: [])
        }
        for (index, row) in newRows.enumerated() {
            if index < rows.count, rows[index].id == row.id { continue }
            if let from = rows.firstIndex(where: { $0.id == row.id }) {
                rows.insert(rows.remove(at: from), at: index)
                tableView.moveRow(at: from, to: index)
            } else {
                rows.insert(row, at: index)
                tableView.insertRows(at: [index], withAnimation: [])
            }
        }
        rows = newRows
        tableView.endUpdates()

        let changed = Set(newRows.compactMap { row in
            oldByID[row.id].flatMap { $0 != row ? row.id : nil }
        })
        let resized = IndexSet(newRows.indices.filter { index in
            guard let old = oldByID[newRows[index].id] else { return false }
            return (old.folderPath == nil) != (newRows[index].folderPath == nil)
        })
        if resized.isEmpty == false { tableView.noteHeightOfRows(withIndexesChanged: resized) }
        refreshCells { refreshingAll || changed.contains($0.id) }
    }

    /// Reconfigures the cells that exist; rows not drawn yet configure when they appear.
    private func refreshCells(where shouldRefresh: (MacEntryListSnapshot.Row) -> Bool) {
        guard let snapshot else { return }
        let rows = rows
        tableView.enumerateAvailableRowViews { rowView, row in
            guard rows.indices.contains(row), shouldRefresh(rows[row]),
                  let cell = rowView.view(atColumn: 0) as? MacEntryCellView else { return }
            self.configure(cell, row: rows[row], rowIdentifier: snapshot.rowIdentifier)
        }
    }

    // MARK: - Verification codes

    private var shouldRunVerificationCodeTimer: Bool {
        isOnScreen && isUnlocked && snapshot?.showsVerificationCodes == true
    }

    /// Starts the code timer with an immediate redraw, or stops it and forgets the codes shown.
    private func updateVerificationCodeTimer() {
        guard shouldRunVerificationCodeTimer else {
            verificationCodeTimer?.invalidate()
            verificationCodeTimer = nil
            codeClock.reset()
            for cell in codeCells.allObjects { cell.update(nil) }
            return
        }
        guard verificationCodeTimer == nil else { return }
        let timer = Timer(fire: TOTPViewModel.nextWholeSecond(after: Date()), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickVerificationCodes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        verificationCodeTimer = timer
        tickVerificationCodes()
    }

    /// Redraws the codes of the rows in view; rows scrolled away update when they reappear.
    func tickVerificationCodes() {
        guard shouldRunVerificationCodeTimer else {
            updateVerificationCodeTimer()
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<(visible.location + visible.length) where rows.indices.contains(row) {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? MacVerificationCodeCellView else { continue }
            cell.update(codeClock.display(for: rows[row].id, session: session))
        }
    }

    func copyVerificationCode(entryID: UUID) {
        DatabaseCommands(session: session).copyVerificationCode(
            entryID: entryID,
            copy: presentation.copyFeedback.recording(.verificationCode, for: entryID, copy: copyToClipboard)
        )
    }

    /// The tick appears without focus moving, so VoiceOver hears it here.
    private func announce(_ message: String) {
        NSAccessibility.post(element: tableView, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func selectModelRows() {
        let target = MacEntryListSelection.tableSelection(rows: rows, workspace: session.workspace)
        guard tableView.selectedRowIndexes != target else { return }
        tableView.selectRowIndexes(target, byExtendingSelection: false)
        // Scrolling before the first layout would keep the top rows scrolled away.
        if let first = target.first, tableView.visibleRect.isEmpty == false { tableView.scrollRowToVisible(first) }
    }

    private func updateChrome(_ state: State) {
        let snapshot = state.snapshot
        let showsEmpty = snapshot.rows.isEmpty && snapshot.emptyState != nil
        scrollView.isHidden = showsEmpty
        emptyView.isHidden = showsEmpty == false
        emptyView.update(showsEmpty ? snapshot.emptyState : nil, offersNewEntry: showsEmpty && snapshot.offersNewEntry)
        tableView.setAccessibilityIdentifier(snapshot.containerIdentifier)
        if showsResultCount, let count = snapshot.resultCount {
            resultCountField.stringValue = String(localized: "results:\(count)")
            resultCountField.isHidden = false
        } else {
            resultCountField.isHidden = true
        }
        footerField.stringValue = snapshot.footer?.text ?? ""
        footerField.setAccessibilityIdentifier(snapshot.footer?.accessibilityIdentifier)
        footerField.superview?.isHidden = snapshot.footer == nil
        header.update(snapshot.header, sortOrder: state.sortOrder, sortAscending: state.sortAscending,
                      canSort: snapshot.rows.isEmpty == false && state.isSaving == false)
    }

    /// Sort applies to the window's whole list, as View ▸ Sort By does.
    private func selectSortOrder(_ order: DatabaseViewModel.SortOrder) {
        guard snapshot?.rows.isEmpty == false else { return }
        session.sortOrder = order
    }

    private func selectSortDirection(_ ascending: Bool) {
        guard snapshot?.rows.isEmpty == false else { return }
        session.sortAscending = ascending
    }

    // MARK: - Selection, open, cancel

    func entryRow(at row: Int) -> MacEntryListSnapshot.Row? {
        rows.indices.contains(row) ? rows[row] : nil
    }

    @objc private func openClickedRow(_ sender: Any?) {
        openEntry(atRow: tableView.clickedRow)
    }

    /// Double-click opens the clicked row in the workspace's one editor, but not while several are picked.
    func openEntry(atRow row: Int) {
        guard rows.indices.contains(row), session.workspace.entrySelection == nil else { return }
        session.workspace.selectedEntryID = rows[row].id
        session.requestEntryEdit()
    }

    /// Return and Enter open the selected entry in the workspace's one editor, as ⌘E does.
    private func openSelectedEntry() -> Bool {
        guard session.workspace.commandEntryID != nil, session.isSaving == false else { return false }
        session.requestEntryEdit()
        return true
    }

    private func cancelSelection() -> Bool {
        guard session.workspace.entrySelection != nil else { return false }
        session.workspace.endEntrySelection()
        return true
    }

    private func moveEntrySelection() {
        guard let selection = session.workspace.entrySelection, selection.isEmpty == false,
              session.isReadOnly == false, session.isSaving == false else { return }
        presentation.pendingMove = .entries(selection)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    /// The row's entry UUID under `MacEntryDrop`'s private type; a row that cannot move starts no drag.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row),
              let data = MacEntryDrop(session: session, presentation: presentation)
                  .pasteboardData(forEntryID: rows[row].id) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: MacSidebarViewController.entryDragType)
        return item
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Self.rowHeight }
        if snapshot?.showsVerificationCodes == true { return Self.rowHeight }
        return rows[row].folderPath == nil ? Self.rowHeight : Self.rowWithFolderHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let snapshot else { return nil }
        let cell: MacEntryCellView
        if snapshot.showsVerificationCodes {
            let codeCell = tableView.makeView(withIdentifier: MacVerificationCodeCellView.codeReuseIdentifier,
                                              owner: self) as? MacVerificationCodeCellView
                ?? MacVerificationCodeCellView(loadFavicon: loadFavicon)
            codeCells.add(codeCell)
            codeCell.onCopy = { [weak self] in self?.copyVerificationCode(entryID: $0) }
            cell = codeCell
        } else {
            cell = tableView.makeView(withIdentifier: MacEntryCellView.reuseIdentifier, owner: self) as? MacEntryCellView
                ?? MacEntryCellView(loadFavicon: loadFavicon)
        }
        configure(cell, row: rows[row], rowIdentifier: snapshot.rowIdentifier)
        return cell
    }

    private func configure(_ cell: MacEntryCellView, row: MacEntryListSnapshot.Row, rowIdentifier: String) {
        let username = session.resolvingFieldReferences(row.rawUsername)
        if let codeCell = cell as? MacVerificationCodeCellView {
            codeCell.configure(row, username: username, rowIdentifier: rowIdentifier,
                               display: codeClock.display(for: row.id, session: session))
        } else {
            cell.configure(row, username: username, rowIdentifier: rowIdentifier)
        }
        cell.showCopied(presentation.copyFeedback.field(copiedFor: row.id))
    }

    /// A row scrolled away or removed takes its code with it.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? MacVerificationCodeCellView else { return }
        if let entryID = cell.entryID { codeClock.forget(entryID) }
        cell.update(nil)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].title : nil
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        MacEntryListSelection.proposedSelection(proposed, current: tableView.selectedRowIndexes, rows: rows,
                                                isReadOnly: session.isReadOnly)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard isApplyingModel == false else { return }
        let selected = tableView.selectedRowIndexes.filter { rows.indices.contains($0) }.map { rows[$0].id }
        MacEntryListSelection.apply(
            selectedIDs: selected,
            visibleIDs: Set(rows.map(\.id)),
            isExtending: isExtendingSelection(),
            to: session.workspace
        )
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        for item in contextMenuItems(forRow: row) { menu.addItem(item) }
    }

    /// A click inside a multiple selection offers what applies to all of it; elsewhere the row's own items.
    func contextMenuItems(forRow row: Int) -> [NSMenuItem] {
        guard rows.indices.contains(row) else { return [] }
        if session.workspace.entrySelection != nil, tableView.selectedRowIndexes.count >= 2,
           tableView.selectedRowIndexes.contains(row) {
            return bulkMenuItems()
        }
        return contextMenuItems(forEntryID: rows[row].id)
    }

    /// Move to Group…, then Delete after a separator, with ⌘⌫ shown for the menu bar's Delete.
    private func bulkMenuItems() -> [NSMenuItem] {
        guard session.isReadOnly == false else { return [] }
        let move = NSMenuItem(title: String(localized: "Move to Group…"), action: #selector(moveSelection(_:)),
                              keyEquivalent: "")
        move.target = self
        move.identifier = NSUserInterfaceItemIdentifier(EntryRowActions.moveIdentifier)
        let delete = NSMenuItem(title: String(localized: "Delete"), action: #selector(deleteSelectedRows(_:)),
                                keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = .command
        delete.target = self
        delete.identifier = NSUserInterfaceItemIdentifier(EntryRowActions.deleteIdentifier)
        return [move, .separator(), delete]
    }

    /// Copies, then the edits, then Delete, each group after a separator. The
    /// shortcuts are the menu bar's, shown for reference: the main menu answers
    /// a key before this menu could, and these selectors are not the main menu's.
    func contextMenuItems(forEntryID entryID: UUID) -> [NSMenuItem] {
        let actions = EntryRowActions(entryID: entryID, session: session)
        var groups: [[NSMenuItem]] = [[], [], []]
        func add(_ group: Int, _ title: String, _ identifier: String, _ action: Selector,
                 key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = entryID
            groups[group].append(item)
        }
        // The bin's rows offer only Restore and Delete Permanently, as RowMenus draws them.
        let isRecycled = session.isEntryInRecycleBin(entryID: entryID)
        if actions.canCopyUsername, isRecycled == false {
            add(0, String(localized: "Copy Username"), EntryRowActions.copyUsernameIdentifier, #selector(copyRowUsername(_:)),
                key: "b", modifiers: [.command, .shift])
        }
        if actions.canCopyPassword, isRecycled == false {
            add(0, String(localized: "Copy Password"), EntryRowActions.copyPasswordIdentifier, #selector(copyRowPassword(_:)),
                key: "c", modifiers: [.command, .shift])
        }
        if actions.canDuplicate {
            add(1, String(localized: "Duplicate"), EntryRowActions.duplicateIdentifier, #selector(duplicateEntry(_:)),
                key: "d")
        }
        if actions.canRestore {
            add(1, String(localized: "Restore"), EntryRowActions.restoreIdentifier, #selector(restoreEntry(_:)))
        }
        if actions.canMove {
            add(1, String(localized: "Move to Group…"), EntryRowActions.moveIdentifier, #selector(moveEntry(_:)))
        }
        if actions.canDelete {
            add(2, actions.deleteTitle, actions.deleteAccessibilityIdentifier, #selector(deleteEntry(_:)), key: "\u{8}")
        }
        var menuItems: [NSMenuItem] = []
        for group in groups where group.isEmpty == false {
            if menuItems.isEmpty == false { menuItems.append(.separator()) }
            menuItems += group
        }
        return menuItems
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard session.state == .unlocked, session.isSaving == false else { return false }
        if menuItem.action == #selector(moveSelection(_:)) {
            return session.isReadOnly == false && session.workspace.entrySelection?.isEmpty == false
        }
        if menuItem.action == #selector(deleteSelectedRows(_:)) {
            if case .entries = session.deletableSelection { return true }
            return false
        }
        guard let entryID = menuItem.representedObject as? UUID, session.entry(withID: entryID) != nil else {
            return false
        }
        let actions = EntryRowActions(entryID: entryID, session: session)
        switch menuItem.action {
        case #selector(copyRowUsername(_:)): return actions.canCopyUsername
        case #selector(copyRowPassword(_:)): return actions.canCopyPassword && passwordCopyAction.isAuthenticating == false
        case #selector(duplicateEntry(_:)): return actions.canDuplicate
        case #selector(restoreEntry(_:)): return actions.canRestore
        case #selector(moveEntry(_:)): return actions.canMove
        case #selector(deleteEntry(_:)): return actions.canDelete
        default: return false
        }
    }

    private func validatedEntryID(_ sender: NSMenuItem) -> UUID? {
        guard validateMenuItem(sender) else { return nil }
        return sender.representedObject as? UUID
    }

    // Not `copyUsername:` / `copyPassword:`: the main menu's nil-targeted commands would reach these first.
    @objc private func copyRowUsername(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        copyUsername(entryID: entryID)
    }

    @objc private func copyRowPassword(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        copyPassword(entryID: entryID)
    }

    /// Copies at once, unless the username's field references reach a protected
    /// value: then it takes the password's prompt and rechecks.
    @discardableResult
    func copyUsername(entryID: UUID) -> Task<Void, Never>? {
        DatabaseCommands(session: session, passwordCopyAction: passwordCopyAction).copyUsername(
            entryID: entryID,
            currentSession: currentSession,
            authenticate: authenticatePassword,
            copy: presentation.copyFeedback.recording(.username, for: entryID, copy: copyToClipboard)
        )
    }

    /// The menu-bar ⇧⌘C path for one row: device-owner prompt, then the window's session recheck.
    @discardableResult
    func copyPassword(entryID: UUID) -> Task<Void, Never>? {
        DatabaseCommands(session: session, passwordCopyAction: passwordCopyAction).copyPassword(
            entryID: entryID,
            currentSession: currentSession,
            authenticate: authenticatePassword,
            copy: presentation.copyFeedback.recording(.password, for: entryID, copy: copyToClipboard)
        )
    }

    @objc private func duplicateEntry(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender),
              let editor = EntryRowActions(entryID: entryID, session: session).makeDuplicateEditor() else { return }
        let selectsInPlace = switch snapshot?.mode {
        case .search, .tag: true
        default: false
        }
        presentation.beginEntryDuplicate(editor, selectingInPlace: selectsInPlace)
    }

    @objc private func restoreEntry(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        EntryRowActions(entryID: entryID, session: session).restore { [presentation] in
            presentation.pendingMove = $0
        }
    }

    @objc private func moveEntry(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        presentation.pendingMove = EntryRowActions(entryID: entryID, session: session).pendingMove
    }

    @objc private func deleteEntry(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        presentation.pendingDeletion = EntryRowActions(entryID: entryID, session: session).pendingDeletion
    }

    @objc private func moveSelection(_ sender: NSMenuItem) {
        guard validateMenuItem(sender) else { return }
        moveEntrySelection()
    }

    /// Not `deleteSelection:`, the menu bar's Delete, which raises the same confirmation.
    @objc private func deleteSelectedRows(_ sender: NSMenuItem) {
        guard validateMenuItem(sender) else { return }
        presentation.beginSelectionDeletion(in: session)
    }
}

// MARK: - Table

/// Return and Enter open the selected entry and Escape ends a multiple
/// selection; every other key, bare Delete, Space and ⌘C included, keeps
/// NSTableView's own handling.
final class MacEntryTableView: NSTableView {
    var onOpen: (@MainActor () -> Bool)?
    var onCancel: (@MainActor () -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if isReturn, modifiers.isEmpty, onOpen?() == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        super.cancelOperation(sender)
    }
}

// MARK: - Cells

class MacEntryCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("entries.row")
    static let iconSize: CGFloat = 24

    let usernameField = NSTextField(labelWithString: "")
    let folderField = NSTextField(labelWithString: "")
    let expiredGlyph = MacEntryBadgeView(.expired, label: String(localized: "Expired"),
                                         identifier: "entry-row.expired")
    let passkeyGlyph = MacEntryBadgeView(.symbol("person.fill"), label: String(localized: "Has a passkey"),
                                         identifier: "entry-row.passkey")
    let verificationCodeGlyph = MacEntryBadgeView(.symbol("timer"), label: String(localized: "Has a verification code"),
                                                  identifier: "entry-row.totp")
    let sshGlyph = MacEntryBadgeView(.ssh, label: String(localized: "Has an SSH key"), identifier: "entry-row.ssh")
    /// The tick a copy from this window leaves for `MacCopyFeedback.duration`.
    let copiedGlyph = NSImageView()
    private(set) var copiedField: MacCopyFeedback.Field?
    let folderRow: NSStackView
    /// Title, username and folder, top to bottom.
    let textStack: NSStackView
    /// The trailing glyphs.
    let accessoryStack: NSStackView
    private let faviconLoader: FaviconLoadModel
    private var faviconTask: Task<Void, Never>?
    private var requestedFaviconDomain: String?
    private var icon: MacEntryIcon?

    init(loadFavicon: @escaping @MainActor (String) async -> PlatformImage?) {
        faviconLoader = FaviconLoadModel(loadImage: loadFavicon)
        folderRow = NSStackView(views: [folderField])
        let title = NSTextField(labelWithString: "")
        textStack = NSStackView(views: [title, usernameField, folderRow])
        accessoryStack = NSStackView(views: [expiredGlyph, passkeyGlyph, verificationCodeGlyph, sshGlyph, copiedGlyph])
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier

        copiedGlyph.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copiedGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        copiedGlyph.setAccessibilityElement(true)
        copiedGlyph.setAccessibilityRole(.image)
        copiedGlyph.setAccessibilityIdentifier("entry-row.copied")
        copiedGlyph.isHidden = true

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        for field in [usernameField, folderField] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
        }
        folderField.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        folderField.setAccessibilityIdentifier("entry-row.folder")
        folderRow.orientation = .horizontal
        folderRow.spacing = 4
        for field in [title, usernameField, folderField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = textStack
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.detachesHiddenViews = true

        let glyphs = accessoryStack
        glyphs.orientation = .horizontal
        glyphs.spacing = 4
        glyphs.detachesHiddenViews = true
        glyphs.setContentHuggingPriority(.required, for: .horizontal)
        glyphs.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [image, text, glyphs] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = image
        textField = title
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: Self.iconSize),
            image.heightAnchor.constraint(equalToConstant: Self.iconSize),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphs.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            glyphs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            glyphs.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconTask?.cancel()
        faviconTask = nil
        requestedFaviconDomain = nil
    }

    func configure(_ row: MacEntryListSnapshot.Row, username: String, rowIdentifier: String) {
        icon = row.icon
        textField?.stringValue = row.title
        usernameField.stringValue = username
        usernameField.isHidden = username.isEmpty
        folderField.stringValue = row.folderPath ?? ""
        folderRow.isHidden = (row.folderPath ?? "").isEmpty
        expiredGlyph.isHidden = row.isExpired == false
        passkeyGlyph.isHidden = row.hasPasskey == false
        verificationCodeGlyph.isHidden = row.hasVerificationCode == false
        sshGlyph.isHidden = row.hasSSHKey == false
        toolTip = row.title
        // XCUITest drops a table cell's own identifier, so the title carries it.
        textField?.setAccessibilityIdentifier(rowIdentifier)
        setAccessibilityLabel(row.title)
        loadFavicon(row.faviconDomain)
        refreshAppearance()
    }

    private func loadFavicon(_ domain: String?) {
        guard domain != requestedFaviconDomain else { return }
        faviconTask?.cancel()
        requestedFaviconDomain = domain
        guard let domain else {
            faviconTask = nil
            return
        }
        faviconTask = Task { [weak self, faviconLoader] in
            await faviconLoader.load(domain: domain)
            guard Task.isCancelled == false else { return }
            self?.refreshAppearance()
        }
    }

    func refreshAppearance() {
        let emphasized = backgroundStyle == .emphasized
        imageView?.image = image(emphasized: emphasized)
        for badge in [expiredGlyph, passkeyGlyph, verificationCodeGlyph, sshGlyph] { badge.isEmphasized = emphasized }
        copiedGlyph.contentTintColor = emphasized ? .white : .systemGreen
    }

    func showCopied(_ field: MacCopyFeedback.Field?) {
        copiedField = field
        copiedGlyph.isHidden = field == nil
        copiedGlyph.setAccessibilityLabel(field?.copiedLabel)
    }

    private func image(emphasized: Bool) -> NSImage? {
        switch icon {
        case .custom(let data, let standardIconID):
            return MacIconImages.custom(data, size: Self.iconSize) ?? standardImage(standardIconID, emphasized: emphasized)
        case .standard(let iconID):
            if let domain = requestedFaviconDomain, faviconLoader.domain == domain, let favicon = faviconLoader.image {
                return favicon
            }
            return standardImage(iconID, emphasized: emphasized)
        case nil:
            return nil
        }
    }

    private func standardImage(_ iconID: Int, emphasized: Bool) -> NSImage? {
        MacIconImages.standard(iconID, fallbackSymbol: "key.fill", fallbackPalette: .gold, pointSize: 18,
                               emphasized: emphasized)
    }
}

// MARK: - Badges

/// A row's trailing badge: the red "EXPIRED" pill, a symbol in a tinted round
/// badge, or the plain monospaced "SSH".
final class MacEntryBadgeView: NSView {
    enum Style: Equatable {
        case expired
        case symbol(String)
        case ssh
    }

    static let diameter: CGFloat = 18

    let style: Style
    private let imageView = NSImageView()
    private let textField = NSTextField(labelWithString: "")
    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            refreshColors()
        }
    }

    init(_ style: Style, label: String, identifier: String) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        let content: NSView
        switch style {
        case .expired:
            textField.stringValue = label.localizedUppercase
            textField.font = .systemFont(ofSize: 10, weight: .bold)
            textField.setAccessibilityElement(false)
            content = textField
        case .ssh:
            textField.stringValue = String(localized: "SSH")
            textField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            textField.setAccessibilityElement(false)
            content = textField
        case .symbol(let name):
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            imageView.setAccessibilityElement(false)
            content = imageView
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .expired:
            let text = textField.intrinsicContentSize
            return NSSize(width: ceil(text.width) + 12, height: ceil(text.height) + 2)
        case .ssh:
            let text = textField.intrinsicContentSize
            return NSSize(width: ceil(text.width), height: ceil(text.height))
        case .symbol:
            return NSSize(width: Self.diameter, height: Self.diameter)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    /// Layer colours resolve here, so they follow appearance changes.
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = fillColor.cgColor
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private var tintColor: NSColor {
        if isEmphasized { return .white }
        return switch style {
        case .expired: .systemRed
        case .symbol: .controlAccentColor
        case .ssh: .secondaryLabelColor
        }
    }

    private var fillColor: NSColor {
        switch style {
        case .ssh: .clear
        case .expired: tintColor.withAlphaComponent(isEmphasized ? 0.22 : 0.12)
        case .symbol: tintColor.withAlphaComponent(isEmphasized ? 0.22 : 0.14)
        }
    }

    private func refreshColors() {
        textField.textColor = tintColor
        imageView.contentTintColor = tintColor
        needsDisplay = true
    }
}

// MARK: - Verification-code cells

/// A Verification Codes row: the usual title and username, with the live code
/// trailing as a button that copies it, and a countdown ring.
final class MacVerificationCodeCellView: MacEntryCellView {
    static let codeReuseIdentifier = NSUserInterfaceItemIdentifier("entries.code-row")
    static let ringSize: CGFloat = 14

    let codeButton = NSButton()
    let countdown = MacCountdownRingView()
    var onCopy: (@MainActor (UUID) -> Void)?
    private(set) var entryID: UUID?
    private(set) var display: MacVerificationCodeClock.Display?

    override init(loadFavicon: @escaping @MainActor (String) async -> PlatformImage?) {
        super.init(loadFavicon: loadFavicon)
        identifier = Self.codeReuseIdentifier
        let label = String(localized: "Copy Verification Code")
        codeButton.isBordered = false
        codeButton.toolTip = label
        codeButton.setAccessibilityRole(.button)
        codeButton.setAccessibilityLabel(label)
        codeButton.setAccessibilityIdentifier("verification-code-row.copy")
        codeButton.target = self
        codeButton.action = #selector(copyCode(_:))
        countdown.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countdown.widthAnchor.constraint(equalToConstant: Self.ringSize),
            countdown.heightAnchor.constraint(equalToConstant: Self.ringSize),
        ])
        accessoryStack.spacing = 8
        accessoryStack.addArrangedSubview(codeButton)
        accessoryStack.addArrangedSubview(countdown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        entryID = nil
        update(nil)
    }

    func configure(_ row: MacEntryListSnapshot.Row, username: String, rowIdentifier: String,
                   display: MacVerificationCodeClock.Display?) {
        configure(row, username: username, rowIdentifier: rowIdentifier)
        entryID = row.id
        folderRow.isHidden = true
        for glyph in [expiredGlyph, passkeyGlyph, verificationCodeGlyph] { glyph.isHidden = true }
        update(display)
    }

    func update(_ display: MacVerificationCodeClock.Display?) {
        self.display = display
        codeButton.isHidden = display == nil
        countdown.isHidden = display == nil
        countdown.update(seconds: display?.secondsRemaining ?? 0, progress: display?.progress ?? 0,
                         isExpiring: display?.isExpiring ?? false)
        setAccessibilityValue(display.map { $0.code.map(String.init).joined(separator: " ") })
        refreshCode()
    }

    override func refreshAppearance() {
        super.refreshAppearance()
        countdown.isEmphasized = backgroundStyle == .emphasized
        refreshCode()
    }

    /// The board's 13 pt monospaced code: accent, dimmed in its last seconds, white when selected.
    private func refreshCode() {
        let color: NSColor = if backgroundStyle == .emphasized {
            .white
        } else if display?.isExpiring == true {
            .secondaryLabelColor
        } else {
            .controlAccentColor
        }
        codeButton.attributedTitle = NSAttributedString(string: display?.grouped ?? "", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: color,
            .kern: 0.3,
        ])
    }

    @objc private func copyCode(_ sender: Any?) {
        guard let entryID else { return }
        onCopy?(entryID)
    }
}

/// A ring that empties with the code's period, orange in its last seconds.
final class MacCountdownRingView: NSView {
    private(set) var seconds = 0
    private(set) var progress: Double = 0
    private(set) var isExpiring = false
    var isEmphasized = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(seconds: Int, progress: Double, isExpiring: Bool) {
        guard seconds != self.seconds || progress != self.progress || isExpiring != self.isExpiring else { return }
        self.seconds = seconds
        self.progress = progress
        self.isExpiring = isExpiring
        setAccessibilityLabel(String(localized: "\(seconds) seconds remaining"))
        needsDisplay = true
    }

    var arcColor: NSColor {
        if isEmphasized { return .white }
        return isExpiring ? .systemOrange : .controlAccentColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        track.lineWidth = lineWidth
        (isEmphasized ? NSColor.white.withAlphaComponent(0.25) : .quaternaryLabelColor).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(max(0, min(1, progress))), clockwise: true)
        arc.lineWidth = lineWidth
        arcColor.setStroke()
        arc.stroke()
    }
}

// MARK: - Empty state

/// The native counterpart of `ContentUnavailableView`: a symbol, a title, a
/// message, and New Entry under an empty group's message.
final class MacEntryListEmptyView: NSView {
    let imageView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let messageField = NSTextField(wrappingLabelWithString: "")
    let newEntryButton = NSButton(title: "", target: nil, action: nil)
    var onNewEntry: (@MainActor () -> Void)?
    private(set) var state: MacEntryListSnapshot.EmptyState?

    init() {
        super.init(frame: .zero)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.setAccessibilityElement(false)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .bold)
        titleField.alignment = .center
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        // The column is never narrower than 260 pt; a fixed wrap width keeps layout to one pass.
        messageField.preferredMaxLayoutWidth = 220
        newEntryButton.bezelStyle = .push
        newEntryButton.controlSize = .small
        newEntryButton.attributedTitle = Self.newEntryTitle
        newEntryButton.setAccessibilityLabel(String(localized: "New Entry"))
        newEntryButton.setAccessibilityIdentifier("entry-list.empty.new-entry")
        newEntryButton.target = self
        newEntryButton.action = #selector(newEntry(_:))
        newEntryButton.isHidden = true
        let stack = NSStackView(views: [imageView, titleField, messageField, newEntryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(12, after: imageView)
        stack.setCustomSpacing(14, after: messageField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "New Entry" with the menu bar's ⌘N after it, dimmed as a hint.
    private static var newEntryTitle: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSMutableAttributedString(string: String(localized: "New Entry"), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        title.append(NSAttributedString(string: "  ⌘N", attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]))
        return title
    }

    @objc private func newEntry(_ sender: Any?) {
        onNewEntry?()
    }

    func update(_ state: MacEntryListSnapshot.EmptyState?, offersNewEntry: Bool = false) {
        newEntryButton.isHidden = offersNewEntry == false
        guard state != self.state else { return }
        self.state = state
        imageView.image = state.flatMap { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: nil) }
        titleField.stringValue = state?.title ?? ""
        messageField.stringValue = state?.message ?? ""
        setAccessibilityLabel(state?.title)
        setAccessibilityIdentifier(state?.accessibilityIdentifier)
    }
}

// MARK: - Header

/// The board's 48 pt list header: the list's title, its count line, and the
/// Sort pull-down (`sort.menu`), dimmed while the list is empty.
final class MacEntryListHeaderView: NSView {
    static let height: CGFloat = 48

    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")
    let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var sortOrderItems: [NSMenuItem] = []
    private(set) var sortDirectionItems: [NSMenuItem] = []
    private(set) var header: MacEntryListSnapshot.Header?
    var onSortOrder: (@MainActor (DatabaseViewModel.SortOrder) -> Void)?
    var onSortDirection: (@MainActor (Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier("entry-list.header.title")
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.setAccessibilityIdentifier("entry-list.header.subtitle")
        for field in [titleField, subtitleField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let label = String(localized: "Sort")
        sortButton.bezelStyle = .toolbar
        sortButton.imagePosition = .imageOnly
        (sortButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        sortButton.toolTip = label
        sortButton.setAccessibilityLabel(label)
        sortButton.setAccessibilityIdentifier("sort.menu")
        sortButton.setContentHuggingPriority(.required, for: .horizontal)
        sortButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let face = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: label)
        menu.addItem(face)
        menu.addItem(.sectionHeader(title: String(localized: "Sort By")))
        for order in DatabaseViewModel.SortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(chooseOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            sortOrderItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, ascending) in [(String(localized: "Ascending"), true), (String(localized: "Descending"), false)] {
            let item = NSMenuItem(title: title, action: #selector(chooseDirection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ascending
            sortDirectionItems.append(item)
            menu.addItem(item)
        }
        sortButton.menu = menu

        let text = NSStackView(views: [titleField, subtitleField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        for view in [text, sortButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            sortButton.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 10),
            sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ header: MacEntryListSnapshot.Header?, sortOrder: DatabaseViewModel.SortOrder, sortAscending: Bool,
                canSort: Bool) {
        isHidden = header == nil
        if header != self.header {
            self.header = header
            titleField.attributedStringValue = Self.title(for: header)
            titleField.setAccessibilityLabel(header?.title)
            subtitleField.stringValue = header?.subtitle ?? ""
        }
        sortButton.isEnabled = canSort
        for item in sortOrderItems {
            item.state = item.representedObject as? String == sortOrder.rawValue ? .on : .off
        }
        for item in sortDirectionItems {
            item.state = item.representedObject as? Bool == sortAscending ? .on : .off
        }
    }

    /// A tag's name follows an accent "#", as its sidebar row does.
    private static func title(for header: MacEntryListSnapshot.Header?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: header?.title ?? "", attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        if header?.isTag == true {
            title.insert(NSAttributedString(string: "#\u{2009}", attributes: [
                .font: font, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: paragraph,
            ]), at: 0)
        }
        return title
    }

    @objc private func chooseOrder(_ sender: NSMenuItem) {
        guard let order = (sender.representedObject as? String).flatMap(DatabaseViewModel.SortOrder.init(rawValue:)) else {
            return
        }
        onSortOrder?(order)
    }

    @objc private func chooseDirection(_ sender: NSMenuItem) {
        guard let ascending = sender.representedObject as? Bool else { return }
        onSortDirection?(ascending)
    }
}
