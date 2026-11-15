import AppKit

@MainActor
final class MacRemoteBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: MacRemoteBrowserModel
    private let provider: any CloudProvider
    private let table = NSTableView()
    private let back = NSButton()
    private let forward = NSButton()
    private let folders = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var isRefreshing = false
    private let showAll = NSButton()
    private let observation = MacObservation()
    private var loadTask: Task<Void, Never>?
    var didChange: (@MainActor () -> Void)?
    var didOpen: (@MainActor () -> Void)?

    init(model: MacRemoteBrowserModel, provider: any CloudProvider) {
        self.model = model
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        back.title = String(localized: "Back")
        forward.title = String(localized: "Forward")
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back.title)
        forward.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward.title)
        back.setAccessibilityLabel(back.title); forward.setAccessibilityLabel(forward.title)
        back.imagePosition = .imageOnly; forward.imagePosition = .imageOnly
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        folders.target = self; folders.action = #selector(chooseFolder)
        back.setAccessibilityIdentifier("remote-browser.back")
        forward.setAccessibilityIdentifier("remote-browser.forward")
        folders.setAccessibilityIdentifier("remote-browser.folder")
        let account = NSTextField(labelWithString: model.account.displayName)
        account.textColor = .secondaryLabelColor
        let status = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
        status.contentTintColor = .systemGreen
        let accountLine = NSStackView(views: [status, account])
        status.widthAnchor.constraint(equalToConstant: 7).isActive = true
        status.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let toolbar = NSStackView(views: [back, forward, folders])
        folders.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        folders.setAccessibilityLabel(String(localized: "Current Folder"))
        showAll.title = String(localized: "Show All Files")
        showAll.target = self; showAll.action = #selector(showAllFiles)
        showAll.setAccessibilityIdentifier("cloud.browser.show-all-files.button")
        for (id, title, width) in [("name", String(localized: "Name"), 300.0),
                                    ("modified", String(localized: "Date Modified"), 150.0),
                                    ("size", String(localized: "Size"), 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(doubleClick)
        table.setAccessibilityIdentifier("remote-browser.table")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [toolbar, accountLine, scroll, message, showAll])
        stack.orientation = .vertical; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observation.start(reading: { [weak self] in
            guard let self else { return false }
            _ = self.model.files; _ = self.model.isLoading; _ = self.model.errorMessage
            _ = self.model.showsAllFiles; _ = self.model.selectedID
            return self.model.canOpen
        }, onChange: { [weak self] _ in self?.refresh() })
        reload()
    }
    func end() { loadTask?.cancel(); observation.cancel(); model.end() }
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        let file = model.rows[row]
        return file.isFolder || model.isSelectable(file)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing else { return }
        model.selectedID = model.rows.indices.contains(table.selectedRow) ? model.rows[table.selectedRow].id : nil
        didChange?()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = model.rows[row]
        let field = NSTextField(labelWithString: "")
        switch tableColumn?.identifier.rawValue {
        case "modified": field.stringValue = file.modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        case "size": field.stringValue = file.isFolder ? "—" : file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        default:
            field.stringValue = file.name
            field.setAccessibilityIdentifier("cloud.browser.file.row")
            let image = NSImageView(image: NSImage(systemSymbolName: file.isFolder ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
            let cell = NSStackView(views: [image, field])
            field.textColor = file.isFolder || model.isSelectable(file) ? .labelColor : .disabledControlTextColor
            return cell
        }
        field.textColor = .secondaryLabelColor
        return field
    }
    private func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        let selection = model.selectedID
        table.reloadData()
        if let index = model.rows.firstIndex(where: { $0.id == selection }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        back.isEnabled = model.canGoBack; forward.isEnabled = model.canGoForward
        folders.removeAllItems()
        folders.addItems(withTitles: model.pathComponents.map(\.name))
        folders.selectItem(at: model.pathComponents.count - 1)
        showAll.isHidden = model.mode == .chooseFolder || model.showsAllFiles || model.isLoading || model.rows.contains { $0.isFolder || model.isSelectable($0) }
        message.stringValue = model.errorMessage ?? (model.isLoading ? String(localized: "Loading…") :
            (!model.rows.contains { $0.isFolder || model.isSelectable($0) } && model.mode == .chooseDatabase ? String(localized: "No Databases") + "\n" + String(localized: "No KeePass databases were found in this location.") : ""))
        didChange?()
    }
    private func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await model.load(provider: provider)
        }
    }
    @objc private func showAllFiles() { model.showsAllFiles = true }
    @objc private func goBack() { model.goBack(); reload() }
    @objc private func goForward() { model.goForward(); reload() }
    @objc private func chooseFolder() { model.visitAncestor(folders.indexOfSelectedItem); reload() }
    @objc private func doubleClick() {
        guard model.rows.indices.contains(table.clickedRow) else { return }
        let file = model.rows[table.clickedRow]
        if file.isFolder { model.navigate(to: file); reload() }
        else if model.isSelectable(file) { model.selectedID = file.id; didOpen?() }
    }
}
