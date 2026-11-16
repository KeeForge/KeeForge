import AppKit
import SwiftUI

@MainActor
final class MacFormSheetController: NSWindowController {
    let cancellationScope: MacSheetCancellationScope
    let bodyController: NSViewController
    let cancelButton: NSButton
    let defaultButton: NSButton
    private let progress = NSProgressIndicator()
    private let heading = NSTextField(labelWithString: "")
    private let busyLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    private var updateHostedBusy: (@MainActor (Bool) -> Void)?
    private var clearHostedContent: (@MainActor () -> Void)?
    private var completion: (@MainActor (Bool) -> Void)?
    let ownsFooter: Bool
    var presentWindow: @MainActor (NSWindow, NSWindow, @escaping @MainActor () -> Void) -> Void = { sheet, parent, completion in
        parent.beginSheet(sheet) { _ in MainActor.assumeIsolated { completion() } }
    }
    private var hasEnded = false
    private(set) var isPresented = false
    var onConfirm: (@MainActor () -> Void)?
    var canConfirm = true { didSet { updateButtons() } }
    var isBusy = false {
        didSet {
            guard oldValue != isBusy else { return }
            updateButtons()
            updateHostedBusy?(isBusy)
            bodyController.view.alphaValue = isBusy ? 0.35 : 1
            progress.isHidden = !isBusy
            busyLabel.isHidden = !isBusy
            if isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        }
    }

    init(title: String, content: NSViewController, size: NSSize,
         cancelTitle: String = String(localized: "Cancel"), defaultTitle: String = String(localized: "Save"),
         showsFooter: Bool = true, tabs: NSView? = nil, accessory: NSView? = nil,
         maxHeight: CGFloat = MacSheetMetrics.maxHeight,
         cancellationScope: MacSheetCancellationScope = MacSheetCancellationScope()) {
        self.cancellationScope = cancellationScope
        ownsFooter = showsFooter
        bodyController = content
        cancelButton = NSButton(title: cancelTitle, target: nil, action: nil)
        defaultButton = NSButton(title: defaultTitle, target: nil, action: nil)
        let contentSize = NSSize(width: size.width, height: min(size.height, maxHeight))
        let window = FormSheetWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                     styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        super.init(window: window)
        window.shell = self
        let root = NSView()
        let container = NSViewController()
        container.view = root
        container.addChild(content)
        window.contentViewController = container
        // Installing a content controller resizes the window to the empty root view's zero size.
        window.setContentSize(contentSize)
        heading.stringValue = title
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        if let tabs {
            // DatabaseSettingsTabs board: a centred title over the tabs, set off from the body by a rule.
            heading.alignment = .center
            let header = NSStackView(views: [heading, tabs])
            header.orientation = .vertical
            header.alignment = .centerX
            header.spacing = 12
            header.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 8, right: 0)
            let rule = NSBox()
            rule.boxType = .separator
            for view in [header, rule] {
                view.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(view)
            }
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                rule.topAnchor.constraint(equalTo: header.bottomAnchor),
                rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                stack.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8)
            ])
        } else {
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16).isActive = true
            stack.addArrangedSubview(heading)
        }
        stack.addArrangedSubview(contentContainer)
        contentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let body = content.view
        contentContainer.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        progress.style = .spinning
        progress.isHidden = true
        busyLabel.isHidden = true
        let busy = NSStackView(views: [progress, busyLabel])
        busy.orientation = .vertical
        contentContainer.addSubview(busy)
        busy.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            busy.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            busy.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor)
        ])
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"
        defaultButton.target = self
        defaultButton.action = #selector(confirmAction)
        defaultButton.keyEquivalent = "\r"
        if showsFooter {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let footer = NSStackView(views: (accessory.map { [$0] } ?? []) + [spacer, cancelButton, defaultButton])
            stack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if tabs != nil {
                let rule = NSBox()
                rule.boxType = .separator
                rule.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(rule)
                NSLayoutConstraint.activate([
                    rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                    rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    rule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12)
                ])
            }
        }
    }

    /// `maxHeight` above `MacSheetMetrics.maxHeight` only for a sheet on the Databases window, which grows to fit it.
    convenience init<Content: View>(title: String, content: Content, size: NSSize, showsFooter: Bool = true,
                                    maxHeight: CGFloat = MacSheetMetrics.maxHeight) {
        let scope = MacSheetCancellationScope()
        let host = NSHostingController(rootView: AnyView(content.disabled(false).environment(\.macSheetCancellationScope, scope).modifier(MacHostingAppearance())))
        host.sizingOptions = []
        // The transitional forms retain their own navigation toolbar.
        self.init(title: title, content: host, size: size, showsFooter: showsFooter, maxHeight: maxHeight, cancellationScope: scope)
        updateHostedBusy = { [weak host] busy in
            host?.rootView = AnyView(content.disabled(busy).environment(\.macSheetCancellationScope, scope).modifier(MacHostingAppearance()))
        }
        clearHostedContent = { [weak host] in host?.rootView = AnyView(EmptyView()) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTitle(_ title: String) {
        window?.title = title
        heading.stringValue = title
    }

    func setBusy(_ busy: Bool, label: String) {
        busyLabel.stringValue = label
        isBusy = busy
    }

    func begin(on parent: NSWindow, initialFocus: (@MainActor () -> NSView?)? = nil,
               completion: @escaping @MainActor (Bool) -> Void) {
        guard let window, !isPresented, !hasEnded else { return }
        self.completion = completion
        isPresented = true
        window.sharingType = parent.sharingType
        presentWindow(window, parent) { [weak self] in self?.finish(confirmed: false) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(initialFocus?() ?? Self.firstInput(in: bodyController.view))
    }

    /// Also closes hosted child sheets; their dismissal cancels pending authentication/import state.
    func end(confirmed: Bool = false) {
        guard let window else { return }
        Self.endChildren(of: window)
        finish(confirmed: confirmed)
        window.sheetParent?.endSheet(window, returnCode: confirmed ? .OK : .cancel)
        window.orderOut(nil)
    }

    static func endChildren(of window: NSWindow) {
        if let sheet = window.attachedSheet {
            endChildren(of: sheet)
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
    }

    private func finish(confirmed: Bool) {
        guard isPresented || completion != nil else { return }
        isPresented = false
        hasEnded = true
        cancellationScope.cancel()
        let completion = completion
        self.completion = nil
        onConfirm = nil
        completion?(confirmed)
        bodyController.view.removeFromSuperview()
        clearHostedContent?()
        clearHostedContent = nil
        updateHostedBusy = nil
    }

    func performCancel() { guard !isBusy else { return }; end() }
    func performDefault() {
        guard !isBusy, canConfirm else { return }
        if let onConfirm { onConfirm() } else { end(confirmed: true) }
    }
    @objc private func cancelAction() { performCancel() }
    @objc private func confirmAction() { performDefault() }
    private func updateButtons() {
        cancelButton.isEnabled = !isBusy
        defaultButton.isEnabled = !isBusy && canConfirm
    }
    private static func firstInput(in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { firstInput(in: $0) }.first
    }
}

@MainActor
private final class FormSheetWindow: NSWindow {
    weak var shell: MacFormSheetController?
    override func sendEvent(_ event: NSEvent) {
        if shell?.isBusy == true { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) {
        if shell?.ownsFooter == true { shell?.performCancel() } else { super.cancelOperation(sender) }
    }
}
