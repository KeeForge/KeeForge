import SwiftUI

struct PasswordInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
    }
}

extension View {
    func passwordInputStyle() -> some View {
        modifier(PasswordInputStyle())
    }
}

struct PasswordInputRow<Actions: View>: View {
    let title: String
    @Binding var text: String
    @Binding var isVisible: Bool
    let fieldAccessibilityIdentifier: String
    let visibilityAccessibilityIdentifier: String
    private let onVisibilityToggle: (() -> Void)?
    private let actions: Actions

    init(
        title: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        fieldAccessibilityIdentifier: String,
        visibilityAccessibilityIdentifier: String,
        onVisibilityToggle: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        _text = text
        _isVisible = isVisible
        self.fieldAccessibilityIdentifier = fieldAccessibilityIdentifier
        self.visibilityAccessibilityIdentifier = visibilityAccessibilityIdentifier
        self.onVisibilityToggle = onVisibilityToggle
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
            .textContentType(.newPassword)
            .passwordInputStyle()
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

            actions
        }
    }
}
