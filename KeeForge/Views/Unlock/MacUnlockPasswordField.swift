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
/// Initial focus and the field-editor routing are covered by
/// `MacUnlockPasswordFieldTests`.
struct MacUnlockPasswordField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String
    var accessibilityIdentifier: String
    var focusOnAppear: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let initialFocus = context.coordinator.initialFocus
        let field: NSTextField
        if isSecure {
            let secureField = MacUnlockSecureTextField()
            secureField.onMoveToWindow = { initialFocus.fieldDidMoveToWindow($0) }
            field = secureField
        } else {
            let plainField = MacUnlockPlainTextField()
            plainField.onMoveToWindow = { initialFocus.fieldDidMoveToWindow($0) }
            field = plainField
        }
        configure(field, context: context)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    private func configure(_ field: NSTextField, context: Context) {
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        // A bordered field with a focus ring is what reads as editable on
        // macOS; borderless inside a capsule reads as a disabled control.
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.controlSize = .large
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
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

        init(_ parent: MacUnlockPasswordField) {
            self.parent = parent
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(self)
    }
}

final class MacUnlockPlainTextField: NSTextField {
    var onMoveToWindow: ((NSTextField) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(self)
    }
}
#endif
