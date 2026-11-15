#if os(iOS)
import SwiftUI

/// The copy items every entry row's context menu offers, over the shared
/// `EntryRowActions` gates and effects.
struct EntryRowCopyActions: View {
    let entry: KPEntry
    let viewModel: DatabaseViewModel
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        let actions = EntryRowActions(entry: entry, session: viewModel)
        if actions.canCopyUsername {
            Button("Copy Username", systemImage: "person") {
                actions.copyUsername(using: secretAction, copy: copyWithFeedback)
            }
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier(EntryRowActions.copyUsernameIdentifier)
        }

        if actions.canCopyPassword {
            Button("Copy Password", systemImage: "key") {
                actions.copyPassword(using: secretAction, copy: copyWithFeedback)
            }
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier(EntryRowActions.copyPasswordIdentifier)
            .onChange(of: entry.password) { secretAction.invalidate() }
            .onChange(of: entry.id) { secretAction.invalidate() }
        }

        if actions.canCopyVerificationCode {
            Button("Copy Verification Code", systemImage: "timer") {
                actions.copyVerificationCode(copy: copyWithFeedback)
            }
            .accessibilityIdentifier(EntryRowActions.copyVerificationCodeIdentifier)
        }
    }

    private func copyWithFeedback(_ value: String) {
        ClipboardService.copy(value)
        HapticService.success()
    }
}
#endif
