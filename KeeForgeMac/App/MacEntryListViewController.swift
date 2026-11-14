import AppKit
import SwiftUI

/// The database window's entry list: `MacEntryListSnapshot` in a view-based
/// table, with the empty state, the selection bar and the UI-test result
/// count. Sheets and confirmations its menu raises stay with
/// `MacWorkspacePresentationHost`.
@MainActor
final class MacEntryListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSMenuItemValidation {
    static let rowHeight: CGFloat = 40
    static let rowWithFolderHeight: CGFloat = 56
    static let verificationCodeRowHeight: CGFloat = 64

    let session: DatabaseViewModel
    let tableView = MacEntryTableView()
    let scrollView = NSScrollView()
    let emptyView = MacEntryListEmptyView()
    let selectionBar = MacEntrySelectionBarView()
    let resultCountField = NSTextField(labelWithString: "")
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
    private let codeClock: MacVerificationCodeClock
    /// The one timer that redraws the visible codes while Verification Codes is on screen.
    private(set) var verificationCodeTimer: Timer?
    private var isOnScreen = false
    private var isUnlocked = false
    private(set) var snapshot: MacEntryListSnapshot?
    private var rows: [MacEntryListSnapshot.Row] = []
    private var contentRevision: Int?
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

        selectionBar.isHidden = true
        selectionBar.onCancel = { [weak self] in _ = self?.cancelSelection() }
        selectionBar.onMove = { [weak self] in self?.moveEntrySelection() }

        let stack = NSStackView(views: [content, selectionBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for view in [content, selectionBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        selectionBar.setContentHuggingPriority(.required, for: .vertical)
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
        var isReadOnly: Bool
        var isUnlocked: Bool
        var contentRevision: Int
    }

    private func readState() -> State {
        State(
            snapshot: MacEntryListSnapshot.make(session: session),
            selectedEntryID: session.workspace.selectedEntryID,
            entrySelection: session.workspace.entrySelection,
            isSaving: session.isSaving,
            isReadOnly: session.isReadOnly,
            isUnlocked: session.state == .unlocked,
            contentRevision: session.contentRevision
        )
    }

    private func apply(_ state: State) {
        isApplyingModel = true
        defer { isApplyingModel = false }
        let old = snapshot
        let new = state.snapshot
        snapshot = new
        isUnlocked = state.isUnlocked
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
            return
        }
        guard verificationCodeTimer == nil else { return }
        let nextSecond = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 1).rounded(.down))
        let timer = Timer(fire: nextSecond, interval: 1, repeats: true) { [weak self] _ in
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
        DatabaseCommands(session: session).copyVerificationCode(entryID: entryID, copy: copyToClipboard)
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
        emptyView.update(showsEmpty ? snapshot.emptyState : nil)
        tableView.setAccessibilityIdentifier(snapshot.containerIdentifier)
        if showsResultCount, let count = snapshot.resultCount {
            resultCountField.stringValue = String(localized: "results:\(count)")
            resultCountField.isHidden = false
        } else {
            resultCountField.isHidden = true
        }
        selectionBar.update(selection: state.entrySelection, isReadOnly: state.isReadOnly, isSaving: state.isSaving)
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

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return Self.rowHeight }
        if snapshot?.showsVerificationCodes == true { return Self.verificationCodeRowHeight }
        return rows[row].folderPath == nil ? Self.rowHeight : Self.rowWithFolderHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let snapshot else { return nil }
        let cell: MacEntryCellView
        if snapshot.showsVerificationCodes {
            let codeCell = tableView.makeView(withIdentifier: MacVerificationCodeCellView.codeReuseIdentifier,
                                              owner: self) as? MacVerificationCodeCellView
                ?? MacVerificationCodeCellView(loadFavicon: loadFavicon)
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
            let detail = [username, row.folderPath ?? ""].filter { $0.isEmpty == false }.joined(separator: " · ")
            codeCell.configure(row, detail: detail, rowIdentifier: rowIdentifier,
                               display: codeClock.display(for: row.id, session: session))
        } else {
            cell.configure(row, username: username, rowIdentifier: rowIdentifier)
        }
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

    private func bulkMenuItems() -> [NSMenuItem] {
        guard session.isReadOnly == false else { return [] }
        let item = NSMenuItem(title: String(localized: "Move to Group"), action: #selector(moveSelection(_:)),
                              keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(EntryRowActions.moveIdentifier)
        return [item]
    }

    func contextMenuItems(forEntryID entryID: UUID) -> [NSMenuItem] {
        let actions = EntryRowActions(entryID: entryID, session: session)
        var menuItems: [NSMenuItem] = []
        func add(_ title: String, _ identifier: String, _ action: Selector, symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = entryID
            item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menuItems.append(item)
        }
        if actions.canCopyUsername {
            add(String(localized: "Copy Username"), EntryRowActions.copyUsernameIdentifier, #selector(copyUsername(_:)))
        }
        if actions.canCopyPassword {
            add(String(localized: "Copy Password"), EntryRowActions.copyPasswordIdentifier, #selector(copyPassword(_:)))
        }
        if actions.canDuplicate {
            add(String(localized: "Duplicate"), EntryRowActions.duplicateIdentifier, #selector(duplicateEntry(_:)))
        }
        if actions.canRestore {
            add(String(localized: "Restore"), EntryRowActions.restoreIdentifier, #selector(restoreEntry(_:)),
                symbol: "arrow.uturn.backward")
        }
        if actions.canMove {
            add(String(localized: "Move to Group"), EntryRowActions.moveIdentifier, #selector(moveEntry(_:)))
        }
        if actions.canDelete {
            add(actions.deleteTitle, actions.deleteAccessibilityIdentifier, #selector(deleteEntry(_:)))
        }
        return menuItems
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard session.state == .unlocked, session.isSaving == false else { return false }
        if menuItem.action == #selector(moveSelection(_:)) {
            return session.isReadOnly == false && session.workspace.entrySelection?.isEmpty == false
        }
        guard let entryID = menuItem.representedObject as? UUID, session.entry(withID: entryID) != nil else {
            return false
        }
        let actions = EntryRowActions(entryID: entryID, session: session)
        switch menuItem.action {
        case #selector(copyUsername(_:)): return actions.canCopyUsername
        case #selector(copyPassword(_:)): return actions.canCopyPassword && passwordCopyAction.isAuthenticating == false
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

    @objc private func copyUsername(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        DatabaseCommands(session: session).copyUsername(entryID: entryID, copy: copyToClipboard)
    }

    @objc private func copyPassword(_ sender: NSMenuItem) {
        guard let entryID = validatedEntryID(sender) else { return }
        copyPassword(entryID: entryID)
    }

    /// The menu-bar ⇧⌘C path for one row: device-owner prompt, then the window's session recheck.
    @discardableResult
    func copyPassword(entryID: UUID) -> Task<Void, Never>? {
        DatabaseCommands(session: session, passwordCopyAction: passwordCopyAction).copyPassword(
            entryID: entryID,
            currentSession: currentSession,
            authenticate: authenticatePassword,
            copy: copyToClipboard
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
    let expiredGlyph = NSImageView()
    let passkeyGlyph = NSImageView()
    let verificationCodeGlyph = NSImageView()
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
        let folderSymbol = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        folderSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        folderSymbol.contentTintColor = .secondaryLabelColor
        folderSymbol.setAccessibilityElement(false)
        folderSymbol.setContentHuggingPriority(.required, for: .horizontal)
        folderRow = NSStackView(views: [folderSymbol, folderField])
        let title = NSTextField(labelWithString: "")
        textStack = NSStackView(views: [title, usernameField, folderRow])
        accessoryStack = NSStackView(views: [expiredGlyph, passkeyGlyph, verificationCodeGlyph])
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        for field in [usernameField, folderField] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        usernameField.lineBreakMode = .byTruncatingTail
        folderField.lineBreakMode = .byTruncatingHead
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

        configureGlyph(expiredGlyph, symbol: "exclamationmark.triangle.fill", label: String(localized: "Expired"),
                       identifier: "entry-row.expired")
        configureGlyph(passkeyGlyph, symbol: "person.badge.key.fill", label: String(localized: "Has a passkey"),
                       identifier: "entry-row.passkey")
        configureGlyph(verificationCodeGlyph, symbol: "clock", label: String(localized: "Has a verification code"),
                       identifier: "entry-row.totp")
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

    private func configureGlyph(_ glyph: NSImageView, symbol: String, label: String, identifier: String) {
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        glyph.setAccessibilityElement(true)
        glyph.setAccessibilityRole(.image)
        glyph.setAccessibilityLabel(label)
        glyph.setAccessibilityIdentifier(identifier)
    }

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
        expiredGlyph.contentTintColor = emphasized ? .white : .systemRed
        passkeyGlyph.contentTintColor = emphasized ? .white : .systemPurple
        verificationCodeGlyph.contentTintColor = emphasized ? .white : .systemGreen
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

// MARK: - Verification-code cells

/// A Verification Codes row: the entry with its username and folder on one
/// line, its live code under them, the countdown and a copy button.
final class MacVerificationCodeCellView: MacEntryCellView {
    static let codeReuseIdentifier = NSUserInterfaceItemIdentifier("entries.code-row")

    let codeField = NSTextField(labelWithString: "")
    let countdown = MacCountdownRingView()
    let copyButton = NSButton()
    var onCopy: (@MainActor (UUID) -> Void)?
    private(set) var entryID: UUID?
    private(set) var display: MacVerificationCodeClock.Display?

    override init(loadFavicon: @escaping @MainActor (String) async -> PlatformImage?) {
        super.init(loadFavicon: loadFavicon)
        identifier = Self.codeReuseIdentifier
        codeField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        codeField.lineBreakMode = .byClipping
        // Read through the cell's value, digit by digit.
        codeField.setAccessibilityElement(false)
        textStack.addArrangedSubview(codeField)
        textStack.setCustomSpacing(3, after: usernameField)

        let label = String(localized: "Copy Verification Code")
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: label)
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.toolTip = label
        copyButton.setAccessibilityLabel(label)
        copyButton.setAccessibilityIdentifier("verification-code-row.copy")
        copyButton.target = self
        copyButton.action = #selector(copyCode(_:))
        countdown.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countdown.widthAnchor.constraint(equalToConstant: 22),
            countdown.heightAnchor.constraint(equalToConstant: 22),
        ])
        accessoryStack.spacing = 8
        accessoryStack.addArrangedSubview(countdown)
        accessoryStack.addArrangedSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: MacEntryListSnapshot.Row, detail: String, rowIdentifier: String,
                   display: MacVerificationCodeClock.Display?) {
        configure(row, username: detail, rowIdentifier: rowIdentifier)
        entryID = row.id
        folderRow.isHidden = true
        for glyph in [expiredGlyph, passkeyGlyph, verificationCodeGlyph] { glyph.isHidden = true }
        update(display)
    }

    func update(_ display: MacVerificationCodeClock.Display?) {
        self.display = display
        codeField.stringValue = display?.grouped ?? ""
        codeField.isHidden = display == nil
        countdown.isHidden = display == nil
        copyButton.isHidden = display == nil
        countdown.update(seconds: display?.secondsRemaining ?? 0, progress: display?.progress ?? 0)
        setAccessibilityValue(display.map { $0.code.map(String.init).joined(separator: " ") })
    }

    override func refreshAppearance() {
        super.refreshAppearance()
        let emphasized = backgroundStyle == .emphasized
        codeField.textColor = emphasized ? .white : .controlAccentColor
        copyButton.contentTintColor = emphasized ? .white : .secondaryLabelColor
        countdown.isEmphasized = emphasized
    }

    @objc private func copyCode(_ sender: Any?) {
        guard let entryID else { return }
        onCopy?(entryID)
    }
}

/// The seconds left in the code's period, inside a ring that empties with them.
final class MacCountdownRingView: NSView {
    private(set) var seconds = 0
    private(set) var progress: Double = 0
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

    func update(seconds: Int, progress: Double) {
        guard seconds != self.seconds || progress != self.progress else { return }
        self.seconds = seconds
        self.progress = progress
        setAccessibilityLabel(String(localized: "\(seconds) seconds remaining"))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let tint: NSColor = isEmphasized ? .white : .controlAccentColor
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        track.lineWidth = lineWidth
        tint.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * CGFloat(max(0, min(1, progress))), clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        tint.setStroke()
        arc.stroke()

        let text = NSAttributedString(string: "\(seconds)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 2, weight: .regular),
            .foregroundColor: isEmphasized ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

// MARK: - Empty state

/// The native counterpart of `ContentUnavailableView`: a symbol, a title and a message.
final class MacEntryListEmptyView: NSView {
    let imageView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let messageField = NSTextField(wrappingLabelWithString: "")
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
        let stack = NSStackView(views: [imageView, titleField, messageField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: imageView)
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

    func update(_ state: MacEntryListSnapshot.EmptyState?) {
        guard state != self.state else { return }
        self.state = state
        imageView.image = state.flatMap { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: nil) }
        titleField.stringValue = state?.title ?? ""
        messageField.stringValue = state?.message ?? ""
        setAccessibilityLabel(state?.title)
        setAccessibilityIdentifier(state?.accessibilityIdentifier)
    }
}

// MARK: - Selection bar

/// Shown while several entries are picked: Cancel, how many, and Move to Group.
final class MacEntrySelectionBarView: NSView {
    let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    let countField = NSTextField(labelWithString: "")
    let moveButton = NSButton(title: String(localized: "Move to Group"), target: nil, action: nil)
    var onCancel: (@MainActor () -> Void)?
    var onMove: (@MainActor () -> Void)?

    init() {
        super.init(frame: .zero)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("entry-selection.cancel")
        moveButton.target = self
        moveButton.action = #selector(move(_:))
        moveButton.setAccessibilityIdentifier("entry-selection.move")
        countField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        countField.textColor = .secondaryLabelColor
        countField.alignment = .center
        countField.lineBreakMode = .byTruncatingTail
        countField.setAccessibilityIdentifier("entry-selection.count")
        let separator = NSBox()
        separator.boxType = .separator
        // The count sits above the buttons: beside them it truncates in the column's default width.
        let buttons = NSStackView(views: [cancelButton, moveButton])
        buttons.orientation = .horizontal
        buttons.distribution = .equalSpacing
        let stack = NSStackView(views: [countField, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        for view in [separator, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            countField.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(selection: Set<UUID>?, isReadOnly: Bool, isSaving: Bool) {
        isHidden = selection == nil
        guard let selection else { return }
        countField.stringValue = selection.isEmpty
            ? String(localized: "Select Entries")
            : String(localized: "\(selection.count) entries")
        cancelButton.isEnabled = isSaving == false
        moveButton.isEnabled = selection.isEmpty == false && isReadOnly == false && isSaving == false
    }

    @objc private func cancel(_ sender: Any?) { onCancel?() }
    @objc private func move(_ sender: Any?) { onMove?() }
}
