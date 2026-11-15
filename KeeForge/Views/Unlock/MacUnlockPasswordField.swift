#if os(macOS)
import AppKit
import SwiftUI

/// AppKit-backed password field for the macOS unlock screen.
///
/// A focused `NSSecureTextField` turns on secure event input, which delivers
/// keystrokes straight to the field's field editor and bypasses every
/// app-level key hook: `NSEvent.addLocalMonitorForEvents`, `.keyboardShortcut`
/// (including `.cancelAction`), `.onExitCommand`, and `.onKeyPress`. That is
/// why every SwiftUI-only attempt to catch Escape on the unlock screen fails
/// while the password field is first responder.
///
/// The one layer that reliably sees Return and Escape in that state is the
/// field editor's `doCommandBySelector`, surfaced through `NSTextFieldDelegate`.
/// Owning the `NSTextField` lets the unlock screen submit on Return and back
/// out to the database list on Escape from within the focused field.
///
/// The field draws no bezel: the unlock page's capsule around it draws the
/// border, the focus ring and the wrong-attempt ring. It offers no completion,
/// and the shown variant never puts the password on a pasteboard.
///
/// Initial focus, the field-editor routing and the pasteboard rules are
/// covered by `MacUnlockPasswordFieldTests`.
struct MacUnlockPasswordField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String
    var accessibilityIdentifier: String
    var focusOnAppear: Bool
    /// Each increase asks for focus once; mounting with any value asks nothing.
    var focusRequest = 0
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let coordinator = context.coordinator
        let initialFocus = coordinator.initialFocus
        let field: NSTextField
        if isSecure {
            let secureField = MacUnlockSecureTextField()
            secureField.onMoveToWindow = { initialFocus.fieldDidMoveToWindow($0) }
            secureField.onFocusChange = { [weak coordinator] in coordinator?.parent.onFocusChange($0) }
            field = secureField
        } else {
            let plainField = MacUnlockPlainTextField()
            plainField.onMoveToWindow = { initialFocus.fieldDidMoveToWindow($0) }
            plainField.onFocusChange = { [weak coordinator] in coordinator?.parent.onFocusChange($0) }
            field = plainField
        }
        configure(field, context: context)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            // After this update, so the request never moves focus mid-update.
            DispatchQueue.main.async { [weak nsView] in
                MainActor.assumeIsolated {
                    guard let nsView, let window = nsView.window, MacInitialFocus.hasFocus(nsView) == false else { return }
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }

    private func configure(_ field: NSTextField, context: Context) {
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.isAutomaticTextCompletionEnabled = false
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacUnlockPasswordField
        let initialFocus: MacInitialFocus

        var focusRequest: Int

        init(_ parent: MacUnlockPasswordField) {
            self.parent = parent
            focusRequest = parent.focusRequest
            initialFocus = MacInitialFocus(isEnabled: parent.focusOnAppear)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}

/// Gives a field keyboard focus once, when it first lands in a window.
///
/// Clicking a sidebar row mounts the unlock field while the sidebar outline is
/// first responder, and a single `makeFirstResponder` can lose to that hand-off.
/// Focus is re-applied on following main-queue turns only while the responder
/// the field displaced still holds focus, so any other focus change wins.
@MainActor
final class MacInitialFocus {
    typealias Scheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    /// Bounds the retries so a responder that keeps reclaiming focus is not fought.
    static let maximumAttempts = 3

    private let schedule: Scheduler
    private(set) var isPending: Bool
    private var attempts = 0
    private weak var displacedResponder: NSResponder?

    init(isEnabled: Bool, schedule: @escaping Scheduler = MacInitialFocus.nextMainQueueTurn) {
        isPending = isEnabled
        self.schedule = schedule
    }

    nonisolated static func nextMainQueueTurn(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    func fieldDidMoveToWindow(_ field: NSTextField) {
        guard isPending, let window = field.window else { return }
        displacedResponder = window.firstResponder
        focus(field)
    }

    private func focus(_ field: NSTextField) {
        guard isPending, let window = field.window else { return }
        guard !Self.hasFocus(field),
              attempts < Self.maximumAttempts,
              window.firstResponder === displacedResponder else {
            isPending = false
            return
        }
        attempts += 1
        window.makeFirstResponder(field)
        schedule { [weak self, weak field] in
            guard let self, let field else { return }
            focus(field)
        }
    }

    static func hasFocus(_ field: NSTextField) -> Bool {
        guard let responder = field.window?.firstResponder else { return false }
        return responder === field || (field.currentEditor().map { $0 === responder } ?? false)
    }
}

final class MacUnlockSecureTextField: NSSecureTextField {
    var onMoveToWindow: ((NSTextField) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(self)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// The shown master password: its field editor never copies, cuts, drags or
/// serves the text, so it cannot reach a pasteboard outside the clipboard rules.
final class MacUnlockPlainTextField: NSTextField {
    var onMoveToWindow: ((NSTextField) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override class var cellClass: AnyClass? {
        get { MacUnlockPlainTextFieldCell.self }
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(self)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

final class MacUnlockPlainTextFieldCell: NSTextFieldCell {
    private lazy var editor: MacUnlockPasswordFieldEditor = {
        let editor = MacUnlockPasswordFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }
}

final class MacUnlockPasswordFieldEditor: NSTextView {
    private static let refusedActions: Set<Selector> = [#selector(copy(_:)), #selector(cut(_:))]

    override func copy(_ sender: Any?) {}
    override func cut(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.refusedActions.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        false
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        sendType == nil ? super.validRequestor(forSendType: sendType, returnType: returnType) : nil
    }
}
#endif
