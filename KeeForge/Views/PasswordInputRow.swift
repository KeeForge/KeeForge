import SwiftUI

struct PasswordInputStyle: ViewModifier {
    /// `nil` for a field that only looks like a password. Password AutoFill on
    /// a TOTP setup key offers to replace it with a generated password.
    var contentType: PlatformTextContentType? = .password

    func body(content: Content) -> some View {
        content
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(contentType)
    }
}

extension View {
    func passwordInputStyle(contentType: PlatformTextContentType? = .password) -> some View {
        modifier(PasswordInputStyle(contentType: contentType))
    }
}

struct PasswordInputRow<Actions: View>: View {
    let title: String
    @Binding var text: String
    @Binding var isVisible: Bool
    let fieldAccessibilityIdentifier: String
    let visibilityAccessibilityIdentifier: String
    private let onVisibilityToggle: (() -> Void)?
    /// Off for a row that holds something other than a password, so the
    /// QuickType bar cannot offer to overwrite it with a generated one.
    private let usesPasswordAutoFill: Bool
    private let actions: Actions

    init(
        title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        fieldAccessibilityIdentifier: String,
        visibilityAccessibilityIdentifier: String,
        onVisibilityToggle: (() -> Void)? = nil,
        usesPasswordAutoFill: Bool = true,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        _text = text
        _isVisible = isVisible
        self.fieldAccessibilityIdentifier = fieldAccessibilityIdentifier
        self.visibilityAccessibilityIdentifier = visibilityAccessibilityIdentifier
        self.onVisibilityToggle = onVisibilityToggle
        self.usesPasswordAutoFill = usesPasswordAutoFill
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textContentType(usesPasswordAutoFill ? .newPassword : nil)
            .passwordInputStyle(contentType: usesPasswordAutoFill ? .password : nil)
            .accessibilityIdentifier(fieldAccessibilityIdentifier)

            Button {
                if let onVisibilityToggle {
                    onVisibilityToggle()
                } else {
                    isVisible.toggle()
                }
            } label: {
                Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isVisible ? "Hide \(title)" : "Show \(title)")
            .accessibilityIdentifier(visibilityAccessibilityIdentifier)
            .macHelp(isVisible ? String(localized: "Hide \(title)") : String(localized: "Show \(title)"))

            actions
        }
    }
}
