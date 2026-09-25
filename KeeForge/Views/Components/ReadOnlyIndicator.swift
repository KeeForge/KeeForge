import SwiftUI

/// Toolbar status for a database that cannot be edited — KDBX 3.1, a YubiKey
/// unlock, or editing turned off in Database Details.
///
/// A `Button`, not a bare `Image`: a toolbar sizes a button's glyph to its own
/// control metrics, while a loose image keeps body size and reads a size small
/// beside its neighbours. Pressing it explains which reason applies
/// (`DatabaseViewModel.readOnlyExplanation`), the way `CloudSyncWarningButton`
/// explains its own state.
///
/// `eyeglasses` rather than a lock: the lock glyph is what the Lock Database
/// button next to it uses, and two locks in one toolbar say nothing about
/// editing being off. Not an eye either — that is the reveal-secret control
/// everywhere else in the app, and the entry detail shows one on its password
/// row while this sits in the same window's toolbar.
struct ReadOnlyIndicator: View {
    let explanation: String
    @State private var isShowingExplanation = false

    var body: some View {
        Button {
            isShowingExplanation = true
        } label: {
            Image(systemName: "eyeglasses")
                .foregroundStyle(.orange)
        }
        .tint(.orange)
        .macHelp(String(localized: "Read-only database"))
        .accessibilityLabel("Read-only database")
        .accessibilityIdentifier("database.read-only-indicator")
        .alert("Read-Only Database", isPresented: $isShowingExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(explanation)
        }
    }
}
