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
/// The field-editor routing is covered by `MacUnlockPasswordFieldTests`.
struct MacUnlockPasswordField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String
    var accessibilityIdentifier: String
    var focusOnAppear: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        configure(field, context: context)

        if focusOnAppear {
            // The field is not in a window yet inside makeNSView; defer until it
            // has been mounted so `makeFirstResponder` can take effect.
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

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

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacUnlockPasswordField

        init(_ parent: MacUnlockPasswordField) {
            self.parent = parent
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
#endif
