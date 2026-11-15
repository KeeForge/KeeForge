#if os(macOS)
import SwiftUI

/// A locked database window's unlock page (Unlock and UnlockVariants boards):
/// Touch ID first when it can be used, otherwise the password field, then a
/// card for a failure the form can fix, the key file and why it locked.
struct MacUnlockView: View {
    let session: DatabaseViewModel
    @Bindable var form: MacUnlockFormModel
    let summary: MacLockedDatabaseSummary
    let card: MacDatabaseOpenPage.FailureCard?
    let footer: String?
    let onClose: () -> Void

    @State private var feedbackContext: FeedbackComposerContext?
    @State private var isFieldFocused = false
    @Environment(\.controlActiveState) private var controlActiveState

    static let columnWidth: CGFloat = 320

    var body: some View {
        MacLockedPageLayout {
            VStack(spacing: 0) {
                MacLockedPageHeader(tile: .brand, title: summary.name, subtitle: summary.subline)
                switch form.layout {
                case .biometricPrimary: biometricPrimaryForm
                case .passwordPrimary: passwordPrimaryForm
                }
                keyLine
                    .padding(.top, 18)
            }
            .frame(width: Self.columnWidth)
        } footer: {
            if let footer {
                Label(footer, systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 26)
                    .accessibilityIdentifier("unlock.lock-reason")
            }
        }
        .task { await form.loadAssociatedKeyFileIfNeeded() }
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
                .macSheetFrame()
        }
    }

    // MARK: - Layouts

    private var biometricPrimaryForm: some View {
        VStack(spacing: 0) {
            Button {
                Task { await form.unlockWithBiometrics() }
            } label: {
                Label(session.biometricLabel, systemImage: session.biometricIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
            .disabled(form.canUnlockWithBiometrics == false)
            .accessibilityIdentifier("unlock.biometric.button")
            .padding(.top, 30)

            HStack(spacing: 10) {
                hairline
                Text("or")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                hairline
            }
            .accessibilityHidden(true)
            .padding(.top, 22)

            passwordField(trailing: .inlineUnlock)
                .padding(.top, 14)

            failureCard
        }
    }

    private var passwordPrimaryForm: some View {
        VStack(spacing: 0) {
            passwordField(trailing: .visibilityToggle)
                .padding(.top, 24)

            failureCard

            Button(action: submit) {
                Label("Unlock Database", systemImage: "lock.open.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(form.canSubmit == false)
            .accessibilityIdentifier("unlock.button")
            .padding(.top, 14)

            if form.showsBiometricUnavailableNote {
                biometricUnavailableNote
                    .padding(.top, 20)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Password field

    private enum FieldTrailing {
        case inlineUnlock
        case visibilityToggle
    }

    private func passwordField(trailing: FieldTrailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            MacUnlockPasswordField(
                text: $form.password,
                isSecure: form.isPasswordVisible == false,
                placeholder: String(localized: "Master Password"),
                accessibilityIdentifier: "unlock.password.field",
                focusOnAppear: true,
                focusRequest: form.focusRequest,
                onFocusChange: { isFieldFocused = $0 },
                onSubmit: submit,
                onEscape: {
                    if form.escape() { onClose() }
                }
            )
            .id(form.isPasswordVisible)
            .frame(maxWidth: .infinity)
            switch trailing {
            case .inlineUnlock:
                Button(action: submit) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(form.canSubmit == false)
                .accessibilityLabel(Text("Unlock"))
                .accessibilityIdentifier("unlock.button")
                .macHelp(String(localized: "Unlock"))
            case .visibilityToggle:
                let label = form.isPasswordVisible
                    ? String(localized: "Hide master password")
                    : String(localized: "Show master password")
                Button {
                    form.isPasswordVisible.toggle()
                } label: {
                    Image(systemName: form.isPasswordVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityIdentifier("unlock.password-visibility-button")
                .macHelp(label)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor), in: fieldShape)
        .overlay { fieldRing }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    @ViewBuilder
    private var fieldRing: some View {
        if form.showsFieldError {
            fieldShape.strokeBorder(Color.red.opacity(0.7), lineWidth: 1.5)
        } else if isFieldFocused, controlActiveState == .key {
            fieldShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            fieldShape.stroke(Color.accentColor.opacity(0.4), lineWidth: 3.5)
                .padding(-1.75)
        } else {
            fieldShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func submit() {
        Task { await form.submit() }
    }

    // MARK: - Failure card and notes

    @ViewBuilder
    private var failureCard: some View {
        if let card {
            MacUnlockFailureCard(
                card: card,
                onCopyDetails: copyErrorDetails,
                onSendFeedback: sendFeedback
            )
            .padding(.top, 12)
        }
    }

    private func copyErrorDetails() {
        guard let failure = session.openFailure else { return }
        ClipboardService.copy(failure.copyableDetails)
    }

    private func sendFeedback() {
        guard let failure = session.openFailure else { return }
        feedbackContext = .databaseOpenFailure(failure)
    }

    private var biometricUnavailableNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "touchid")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Touch ID and Apple Watch aren't available right now. You can still use your password and key file.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unlock.biometric-unavailable")
    }

    // MARK: - Key file

    private var keyLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .accessibilityHidden(true)
            Text("Key File:")
            switch form.keyLine {
            case .none:
                Text("None selected")
                    .foregroundStyle(.primary)
                separatorDot
                selectButton
            case .associated(let name):
                keyFileName(name)
                separatorDot
                linkButton("Change…", identifier: "unlock.keyfile.change", action: chooseKeyFile)
            case .picked(let name):
                keyFileName(name)
                Button {
                    form.clearKeyFile()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear key file"))
                .accessibilityIdentifier("unlock.keyfile.clear")
                .macHelp(String(localized: "Clear key file"))
                separatorDot
                selectButton
            }
            if form.isLoadingKeyFile {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .alert(item: $form.selectionAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var separatorDot: some View {
        Text(verbatim: "·")
            .accessibilityHidden(true)
    }

    private var selectButton: some View {
        linkButton("Select…", identifier: "unlock.keyfile.select", action: chooseKeyFile)
    }

    private func keyFileName(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12).monospaced())
            .foregroundStyle(.primary)
            .truncationMode(.middle)
    }

    private func linkButton(_ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .fontWeight(.semibold)
            .foregroundStyle(.tint)
            .disabled(form.isUnlocking)
            .accessibilityIdentifier(identifier)
    }

    private func chooseKeyFile() {
        Task { await form.chooseKeyFile() }
    }
}
#endif
