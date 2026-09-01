import SwiftUI

/// Toolbar status for a database that cannot be edited — KDBX 3.1, or editing
/// turned off in Database Details.
///
/// A `Button`, not a bare `Image`: a toolbar sizes a button's glyph to its own
/// control metrics, while a loose image keeps body size and reads a size small
/// beside its neighbours. Pressing it explains which of the two reasons applies,
/// the way `CloudSyncWarningButton` explains its own state.
///
/// `eyeglasses` rather than a lock: the lock glyph is what the Lock Database
/// button next to it uses, and two locks in one toolbar say nothing about
/// editing being off. Not an eye either — that is the reveal-secret control
/// everywhere else in the app, and the entry detail shows one on its password
/// row while this sits in the same window's toolbar.
struct ReadOnlyIndicator: View {
    let isFormatReadOnly: Bool
    @State private var isShowingExplanation = false

    private var explanation: String {
        isFormatReadOnly
            ? String(localized: "Legacy KDBX 3.1 databases can be opened, but KeeForge intentionally keeps them read-only.")
            : String(localized: "You can still open this database, but create, edit, and delete actions stay blocked until you turn editing back on.")
    }

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
