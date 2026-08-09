#if os(iOS)
import UIKit

/// Cross-fades the last frame of the open database over the screen that
/// replaces it.
///
/// The vault cannot be transitioned out as a live view: `DatabaseViewModel.lock`
/// clears `rootGroup` and `sessionKey` synchronously, and the compact host is
/// torn down in the same update, so by the time any SwiftUI transition could run
/// there is nothing left to draw. Snapshotting the window before the swap is
/// what makes the close animatable without holding the lock back — the lock
/// still happens immediately, underneath the snapshot.
@MainActor
enum VaultCloseTransition {
    private static let duration: TimeInterval = 0.3

    /// Call immediately before the state change that closes the database, while
    /// the vault is still the displayed content.
    static func coverCurrentFrame() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow) else { return }

        // `afterScreenUpdates: false` is the point: this runs inside the update
        // that locks the database, so rendering pending changes first would
        // capture the destination instead of the vault being left behind.
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return }

        snapshot.isUserInteractionEnabled = false
        snapshot.frame = window.bounds
        window.addSubview(snapshot)

        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            snapshot.alpha = 0
            snapshot.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }
}
#endif
