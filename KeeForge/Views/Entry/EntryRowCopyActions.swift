import SwiftUI

/// The Copy Username / Copy Password pair every entry row's context menu
/// offers. Shared by the iOS group list, the entry list behind search and the
/// tag browser, and the macOS rows, so the wording, the device-owner gate, and
/// the accessibility identifiers cannot drift per shell.
struct EntryRowCopyActions: View {
    let entry: KPEntry
    let viewModel: DatabaseViewModel

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
            .accessibilityIdentifier("entry-row.copy-password-context")
        }
    }

    /// Same device-owner gate as the detail view's copy button and the macOS
    /// ⇧⌘C command: biometrics when available, passcode / login password /
    /// Apple Watch otherwise, skipped only when the device has no protection.
    private func copyPassword() {
        guard BiometricService.canAuthenticateDeviceOwner else {
            performPasswordCopy()
            return
        }

        Task { @MainActor in
            do {
                _ = try await BiometricService.authenticateDeviceOwner(
                    reason: String(localized: "Copy password")
                )
            } catch {
                return
            }
            performPasswordCopy()
        }
    }

    private func performPasswordCopy() {
        ClipboardService.copy(viewModel.resolvedPassword(for: entry))
        HapticService.success()
    }
}
