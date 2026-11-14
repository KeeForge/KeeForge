import AppKit
import SwiftUI

/// The status line's dot and text: the storage in secondary text, then the
/// state, emphasized when it is a warning.
final class MacStatusLineView: NSStackView {
    let dotView = NSView()
    let textField = NSTextField(labelWithString: "")
    private(set) var line: MacDatabaseStatus.Line?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        detachesHiddenViews = true
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),
        ])
        textField.font = .systemFont(ofSize: 11)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.cell?.truncatesLastVisibleLine = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(dotView)
        addArrangedSubview(textField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func color(for dot: MacDatabaseStatus.Dot) -> NSColor {
        switch dot {
        case .synced: .systemGreen
        case .neutral: .systemGray
        case .warning: .systemOrange
        }
    }

    func update(_ line: MacDatabaseStatus.Line, short: Bool = false) {
        self.line = line
        dotView.isHidden = line.dot == nil
        dotView.layer?.backgroundColor = line.dot.map { Self.color(for: $0).cgColor }
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()
        if short == false || line.state == nil, let storage = line.storage {
            text.append(NSAttributedString(string: storage, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            if line.state != nil {
                text.append(NSAttributedString(string: MacDatabaseStatus.separator,
                                               attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        if let state = line.state {
            let isWarning = line.dot == .warning
            text.append(NSAttributedString(string: state, attributes: [
                .font: isWarning ? NSFont.systemFont(ofSize: 11, weight: .semibold) : font,
                .foregroundColor: isWarning ? NSColor(Theme.State.warning) : NSColor.secondaryLabelColor,
            ]))
        }
        textField.attributedStringValue = text
        textField.toolTip = text.string
        setAccessibilityLabel(text.string)
    }
}

/// The database's card at the bottom of the sidebar: its name, Database
/// Settings, Sync Now (cloud only) and Lock, the status line, and the one
/// recovery action the state offers. Always shown while the database is open.
final class MacSidebarStatusCardView: NSView {
    static let identifier = "sidebar.status-card"

    enum Control {
        case settings
        case syncNow
        case lock
        case action
        case readOnly
    }

    /// The board's fills, which the system has no equivalent for: white over
    /// the light sidebar, a faint white over the dark one.
    static let fillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.7)
    }
    static let borderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.08)
    }

    var onControl: ((Control) -> Void)?
    private(set) var status: MacDatabaseStatus?
    let nameField = NSTextField(labelWithString: "")
    let readOnlyBadge = NSButton(title: "", target: nil, action: nil)
    let settingsButton = MacSidebarStatusCardView.iconButton(
        symbol: "slider.horizontal.3", label: String(localized: "Database Settings"), identifier: "database-details.button")
    let syncButton = MacSidebarStatusCardView.iconButton(
        symbol: "arrow.triangle.2.circlepath", label: String(localized: "Sync Now"), identifier: "database.cloud-sync-now")
    let lockButton = MacSidebarStatusCardView.iconButton(
        symbol: "lock.fill", label: String(localized: "Lock Database"), identifier: "lock.button")
    let lineView = MacStatusLineView()
    let actionButton = NSButton(title: "", target: nil, action: nil)
    let box = NSBox()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.identifier)

        box.boxType = .custom
        box.borderWidth = 0.5
        box.borderColor = Self.borderColor
        box.cornerRadius = 10
        box.fillColor = Self.fillColor
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setAccessibilityIdentifier("sidebar.status-card.name")

        readOnlyBadge.isBordered = false
        readOnlyBadge.wantsLayer = true
        readOnlyBadge.layer?.cornerRadius = 7
        readOnlyBadge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        readOnlyBadge.attributedTitle = NSAttributedString(
            string: String(localized: "Read-only").uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.controlAccentColor]
        )
        readOnlyBadge.setAccessibilityLabel(String(localized: "Read-only database"))
        readOnlyBadge.setAccessibilityIdentifier("sidebar.status-card.read-only")
        readOnlyBadge.setContentHuggingPriority(.required, for: .horizontal)
        readOnlyBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        lineView.textField.setAccessibilityIdentifier("sidebar.status-card.line")
        actionButton.bezelStyle = .push
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))

        for (button, control) in [(settingsButton, Control.settings), (syncButton, .syncNow), (lockButton, .lock),
                                  (actionButton, .action), (readOnlyBadge, .readOnly)] {
            button.target = self
            button.action = #selector(controlClicked(_:))
            button.tag = control.tag
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [nameField, readOnlyBadge, spacer, settingsButton, syncButton, lockButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 2
        header.setCustomSpacing(6, after: nameField)
        header.detachesHiddenViews = true

        let stack = NSStackView(views: [header, lineView, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: lineView)
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        lineView.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        box.contentView = content
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ status: MacDatabaseStatus) {
        guard status != self.status else { return }
        self.status = status
        nameField.stringValue = status.name
        readOnlyBadge.isHidden = status.isReadOnly == false
        settingsButton.isEnabled = status.canShowSettings
        syncButton.isHidden = status.offersSyncNow == false
        syncButton.isEnabled = status.canSyncNow
        lockButton.isEnabled = status.canLock
        lineView.update(status.line)
        actionButton.isHidden = status.action == nil
        actionButton.title = status.action?.title ?? ""
        actionButton.isEnabled = status.isActionEnabled
        actionButton.setAccessibilityIdentifier(status.action?.accessibilityIdentifier)
        setAccessibilityLabel(status.name)
    }

    @objc private func controlClicked(_ sender: NSButton) {
        guard let control = Control(tag: sender.tag) else { return }
        onControl?(control)
    }

    static func iconButton(symbol: String, label: String, identifier: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }
}

private extension MacSidebarStatusCardView.Control {
    static let all: [Self] = [.settings, .syncNow, .lock, .action, .readOnly]

    var tag: Int { Self.all.firstIndex(of: self) ?? 0 }

    init?(tag: Int) {
        guard Self.all.indices.contains(tag) else { return nil }
        self = Self.all[tag]
    }
}

/// The notices above the entry list (SyncProblems board): sync and upload
/// problems and transient sync results, each with the action it offers.
final class MacWorkspaceNoticesView: NSStackView {
    var onAction: ((MacDatabaseStatus.Notice.Action) -> Void)?
    private(set) var notices: [MacDatabaseStatus.Notice] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsetsZero
        detachesHiddenViews = true
        isHidden = true
        setAccessibilityIdentifier("entry-list.notices")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// One card per notice, in order.
    var noticeViews: [MacWorkspaceNoticeView] {
        arrangedSubviews.compactMap { $0 as? MacWorkspaceNoticeView }
    }

    func update(_ notices: [MacDatabaseStatus.Notice]) {
        guard notices != self.notices else { return }
        self.notices = notices
        for view in arrangedSubviews { view.removeFromSuperview() }
        for notice in notices {
            let view = MacWorkspaceNoticeView(notice: notice)
            view.onAction = { [weak self] in self?.onAction?($0) }
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
        }
        isHidden = notices.isEmpty
        edgeInsets = notices.isEmpty ? NSEdgeInsetsZero : NSEdgeInsets(top: 8, left: 12, bottom: 0, right: 12)
    }
}

final class MacWorkspaceNoticeView: NSView {
    let notice: MacDatabaseStatus.Notice
    let textField: NSTextField
    let actionButton = NSButton(title: "", target: nil, action: nil)
    var onAction: ((MacDatabaseStatus.Notice.Action) -> Void)?

    init(notice: MacDatabaseStatus.Notice) {
        self.notice = notice
        textField = NSTextField(wrappingLabelWithString: notice.text)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(notice.text)
        setAccessibilityIdentifier(notice.accessibilityIdentifier)

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false

        let symbol = notice.isWarning ? "exclamationmark.triangle.fill" : "icloud.slash"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = notice.isWarning ? NSColor(Theme.State.warning) : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        textField.font = .systemFont(ofSize: 12, weight: .semibold)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [icon, textField])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 7

        actionButton.bezelStyle = .push
        actionButton.controlSize = .small
        actionButton.title = notice.action?.title ?? ""
        actionButton.isHidden = notice.action == nil
        actionButton.keyEquivalent = ""
        if notice.action != nil, notice.action != .dismissSyncResult { actionButton.bezelColor = .controlAccentColor }
        actionButton.isEnabled = notice.isActionEnabled
        actionButton.setAccessibilityIdentifier(notice.actionAccessibilityIdentifier)
        actionButton.target = self
        actionButton.action = #selector(actionClicked(_:))

        let stack = NSStackView(views: [titleRow, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.setCustomSpacing(8, after: titleRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        box.contentView = content
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        if textField.preferredMaxLayoutWidth != textField.frame.width {
            textField.preferredMaxLayoutWidth = textField.frame.width
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard let action = notice.action else { return }
        onAction?(action)
    }
}
