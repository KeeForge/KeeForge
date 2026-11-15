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
        spacing = 4
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

@MainActor
final class MacSheetTabButton: NSButton {
    static let symbolPointSize: CGFloat = 18

    var isSelected = false {
        didSet { refreshColors() }
    }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
        imagePosition = .imageAbove
        isBordered = false
        (cell as? NSButtonCell)?.highlightsBy = []
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            heightAnchor.constraint(equalToConstant: 50),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: size.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let color: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.labelColor,
        ])
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
        }
        setAccessibilityValue(isSelected ? 1 : 0)
    }
}
