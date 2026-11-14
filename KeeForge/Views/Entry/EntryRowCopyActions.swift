#if os(iOS)
import SwiftUI

/// The Copy Username / Copy Password pair every entry row's context menu
/// offers, over the shared `EntryRowActions` gates and effects.
struct EntryRowCopyActions: View {
    let entry: KPEntry
    let viewModel: DatabaseViewModel
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        let actions = EntryRowActions(entry: entry, session: viewModel)
        if actions.canCopyUsername {
            Button("Copy Username") {
                actions.copyUsername(copy: copyWithFeedback)
            }
            .accessibilityIdentifier(EntryRowActions.copyUsernameIdentifier)
        }

        if actions.canCopyPassword {
            Button("Copy Password") {
                actions.copyPassword(using: secretAction, copy: copyWithFeedback)
            }
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier(EntryRowActions.copyPasswordIdentifier)
            .onChange(of: entry.password) { secretAction.invalidate() }
            .onChange(of: entry.id) { secretAction.invalidate() }
        }
    }

    private func copyWithFeedback(_ value: String) {
        ClipboardService.copy(value)
        HapticService.success()
    }
}
#endif
