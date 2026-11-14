import SwiftUI

/// The copy items every entry row's context menu offers. Shared by the iOS group list, the entry list behind search and the
/// tag browser, and the macOS rows, so the wording, the device-owner gate, and
/// the accessibility identifiers cannot drift per shell.
struct EntryRowCopyActions: View {
    let entry: KPEntry
    let viewModel: DatabaseViewModel
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        if entry.username.isEmpty == false {
            Button("Copy Username", systemImage: "person") {
                ClipboardService.copy(viewModel.resolvingFieldReferences(entry.username))
                HapticService.success()
            }
            .accessibilityIdentifier("entry-row.copy-username-context")
        }

        if entry.hasPassword, viewModel.sessionKey != nil {
            Button("Copy Password", systemImage: "key") {
                copyPassword()
            }
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier("entry-row.copy-password-context")
            .onChange(of: entry.password) { secretAction.invalidate() }
            .onChange(of: entry.id) { secretAction.invalidate() }
        }

        if entry.totpConfig != nil, viewModel.sessionKey != nil {
            Button("Copy Verification Code", systemImage: "timer") {
                copyVerificationCode()
            }
            .accessibilityIdentifier("entry-row.copy-code-context")
        }
    }

    /// Not behind the device-owner gate, like the detail's code copy button:
    /// the code expires on its own.
    private func copyVerificationCode() {
        guard let config = viewModel.entry(withID: entry.id)?.totpConfig,
              let sessionKey = viewModel.sessionKey else { return }
        ClipboardService.copy(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
        HapticService.success()
    }

    /// Same device-owner gate as the detail view's copy button and the macOS
    /// ⇧⌘C command: biometrics when available, passcode / login password /
    /// Apple Watch otherwise, skipped only inside the authentication grace
    /// period or when the device has no protection.
    private func copyPassword() {
        let isCurrent = EntrySecretAction.currentSession(viewModel)
        guard isCurrent() else { return }
        guard viewModel.secretAccess.requiresAuthentication else {
            performPasswordCopy()
            return
        }
        secretAction.perform(
            authenticate: {
                try await viewModel.secretAccess.authenticate(reason: String(localized: "Copy password"))
            },
            isCurrent: isCurrent,
            disclose: performPasswordCopy
        )
    }

    private func performPasswordCopy() {
        guard let currentEntry = viewModel.entry(withID: entry.id) else { return }
        ClipboardService.copy(viewModel.resolvedPassword(for: currentEntry))
        HapticService.success()
    }
}
