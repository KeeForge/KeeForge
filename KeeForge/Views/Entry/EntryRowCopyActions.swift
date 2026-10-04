import SwiftUI

/// The Copy Username / Copy Password pair every entry row's context menu
/// offers. Shared by the iOS group list, the entry list behind search and the
/// tag browser, and the macOS rows, so the wording, the device-owner gate, and
/// the accessibility identifiers cannot drift per shell.
struct EntryRowCopyActions: View {
    let entry: KPEntry
    let viewModel: DatabaseViewModel
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        if entry.username.isEmpty == false {
            Button("Copy Username") {
                ClipboardService.copy(viewModel.resolvingFieldReferences(entry.username))
                HapticService.success()
            }
            .accessibilityIdentifier("entry-row.copy-username-context")
        }

        if entry.hasPassword, viewModel.sessionKey != nil {
            Button("Copy Password") {
                copyPassword()
            }
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier("entry-row.copy-password-context")
            .onChange(of: entry.password) { secretAction.invalidate() }
            .onChange(of: entry.id) { secretAction.invalidate() }
        }
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
