import SwiftUI

/// Toolbar button that closes the open database.
///
/// The shackle snaps shut on tap, and the lock request is deferred by one
/// animation beat: locking tears this toolbar down immediately, so firing it
/// synchronously would cut the transition off before it draws. The delay runs
/// in a detached task rather than an animation-completion handler so the lock
/// still happens if the view goes away first.
struct LockDatabaseButton: View {
    let action: () -> Void

    @State private var isClosing = false

    private static let closeDuration: Duration = .milliseconds(250)

    var body: some View {
        Button {
            guard isClosing == false else { return }
            withAnimation(.snappy(duration: 0.25)) {
                isClosing = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.closeDuration)
                action()
                isClosing = false
            }
        } label: {
            Image(systemName: isClosing ? "lock.fill" : "lock.open.fill")
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .help("Lock Database")
        .accessibilityLabel("Lock Database")
        .accessibilityIdentifier("lock.button")
    }
}

#Preview {
    NavigationStack {
        Text(verbatim: "Vault")
            .toolbar {
                LockDatabaseButton {}
            }
    }
}
