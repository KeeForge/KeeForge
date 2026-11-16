import AppKit

/// A sheet's row of icon-over-title tabs, the toolbar-tab look of the Settings window for a sheet,
/// which has no toolbar. The selected tab takes the accent colour on an accent-tinted tile.
@MainActor
final class MacSheetTabBar: NSStackView {
    private(set) var buttons: [MacSheetTabButton] = []
    var onSelect: ((Int) -> Void)?

    var selectedIndex = 0 {
        didSet { refreshSelection() }
    }

    init(tabs: [(title: String, symbol: String)], identifier: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        buttons = tabs.enumerated().map { index, tab in
            let button = MacSheetTabButton(title: tab.title, symbol: tab.symbol)
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
            return button
        }
        for button in buttons { addArrangedSubview(button) }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityIdentifier(identifier)
        refreshSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityChildren() -> [Any]? { buttons }

    @objc private func choose(_ sender: MacSheetTabButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    private func refreshSelection() {
        for button in buttons { button.isSelected = button.tag == selectedIndex }
    }
}

/// Drawn to the Settings window's toolbar tabs, which AppKit draws only in a toolbar and a sheet has
/// none: a large-scale symbol close above an 11 pt title, the selected tab on a raised tile.
@MainActor
final class MacSheetTabButton: NSButton {
    static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .large)
    static let iconHeight: CGFloat = 24
    static let iconSpacing: CGFloat = 2
    static let tileHeight: CGFloat = 48
    static let minimumTileWidth: CGFloat = 56
    static let titleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    let tabTitle: String
    private let symbol: String
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet { refreshColors() }
    }
    var symbolImage: NSImage? { icon.image }

    init(title: String, symbol: String) {
        tabTitle = title
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        imagePosition = .noImage
        (cell as? NSButtonCell)?.highlightsBy = []
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.symbolConfiguration = Self.symbolConfiguration
        icon.imageScaling = .scaleNone
        label.stringValue = title
        label.font = Self.titleFont
        label.alignment = .center
        for view in [icon, label] as [NSView] {
            view.setAccessibilityElement(false)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        let titleHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
        let verticalInset = floor((Self.tileHeight - Self.iconHeight - Self.iconSpacing - titleHeight) / 2)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.tileHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTileWidth),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            icon.heightAnchor.constraint(equalToConstant: Self.iconHeight),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: Self.iconSpacing),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(label.intrinsicContentSize.width + 16, Self.minimumTileWidth), height: Self.tileHeight)
    }

    /// The icon and title are drawing only; the whole tile takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let color: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        // A toolbar shows its selected item's symbol filled.
        icon.image = (isSelected ? NSImage(systemSymbolName: symbol + ".fill", accessibilityDescription: nil) : nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        label.textColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let tint: NSColor = dark ? .white : .black
            layer?.backgroundColor = isSelected ? tint.withAlphaComponent(dark ? 0.08 : 0.02).cgColor : nil
            layer?.borderWidth = isSelected ? 1 : 0
            layer?.borderColor = isSelected ? tint.withAlphaComponent(dark ? 0.16 : 0.12).cgColor : nil
        }
        setAccessibilityValue(isSelected ? 1 : 0)
    }
}
