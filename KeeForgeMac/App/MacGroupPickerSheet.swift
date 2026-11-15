import AppKit

@MainActor
final class MacGroupPickerSheet: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node {
        let row: MacGroupPickerModel.Row
        var children: [Node] = []
        init(_ row: MacGroupPickerModel.Row) { self.row = row }
    }
    let model: MacGroupPickerModel
    let outline = NSOutlineView()
    private var roots: [Node] = []
    var onSelectionChange: (@MainActor () -> Void)?
    var onDoubleClick: (@MainActor () -> Void)?

    init(model: MacGroupPickerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        var ancestors: [Node] = []
        for row in model.rows {
            let node = Node(row)
            ancestors = Array(ancestors.prefix(row.depth))
            if let parent = ancestors.last { parent.children.append(node) } else { roots.append(node) }
            ancestors.append(node)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        view = stack
        if !model.itemName.isEmpty {
            let icon = NSImageView()
            icon.image = image(iconID: model.itemIconID, custom: model.itemCustomIconData)
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let text = NSStackView()
            text.orientation = .vertical
            text.alignment = .leading
            text.addArrangedSubview(NSTextField(labelWithString: model.itemName))
            if let path = model.currentPath {
                let caption = NSTextField(labelWithString: String(localized: "Now in \(path)"))
                caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                caption.textColor = .secondaryLabelColor
                text.addArrangedSubview(caption)
            }
            stack.addArrangedSubview(NSStackView(views: [icon, text]))
        }
        let column = NSTableColumn(identifier: .init("group"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 20
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = outline
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let caption = NSTextField(wrappingLabelWithString: String(localized: "Double-click a group to move right away. Entries can also be dragged onto a group in the sidebar."))
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node)?.children ?? roots)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children.isEmpty == false
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.row.isSelectable == true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = (item as? Node)?.row else { return nil }
        let label = NSTextField(labelWithString: row.name)
        label.setAccessibilityIdentifier("move-picker.group.\(row.id.uuidString)")
        label.textColor = row.isCurrent ? .secondaryLabelColor : .labelColor
        if row.isCurrent { label.setAccessibilityLabel(String(localized: "\(row.name), current group")) }
        let icon = NSImageView()
        icon.image = image(iconID: row.iconID, custom: row.customIconData)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let spacer = NSView()
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        tick.isHidden = !row.isCurrent
        return NSStackView(views: [icon, label, spacer, tick])
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        model.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.row.id
        onSelectionChange?()
    }
    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? Node,
              model.confirmOnDoubleClick(node.row.id) != nil else { return }
        onDoubleClick?()
    }
    private func image(iconID: Int, custom: Data?) -> NSImage? {
        custom.flatMap { MacIconImages.custom($0, size: 28) }
            ?? MacIconImages.standard(iconID, fallbackSymbol: "folder.fill", fallbackPalette: .blue, pointSize: 16, emphasized: false)
    }
}
