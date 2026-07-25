#if os(iOS)
import UIKit

/// iOS pasteboard behavior.
///
/// Every copy expires automatically via `UIPasteboard`'s `.expirationDate`
/// option and stays off Universal Clipboard via `.localOnly`. On database
/// lock, `clearOwnedContents()` additionally scrubs a still-pending copy
/// early — otherwise a password copied just before locking would linger on
/// the pasteboard for the rest of its expiration window. The clear is
/// guarded by `changeCount` (mirroring the macOS branch below) so content
/// the user copied elsewhere afterwards is never clobbered.
///
/// The one lock that does *not* scrub is iOS backgrounding, because that is
/// when the user switches to another app to paste (see
/// `DatabaseViewModel.lock(manuallyTriggered:preservingClipboard:)`); the
/// expiration date bounds the copy there instead.
@MainActor
enum ClipboardService {
    private static var ownedChangeCount: Int?

    static func copy(_ string: String) {
        let pasteboard = UIPasteboard.general
        pasteboard.setItems(
            [[UIPasteboard.typeAutomatic: string]],
            options: [
                .expirationDate: Date().addingTimeInterval(SettingsService.clipboardTimeout.seconds),
                .localOnly: true,
            ]
        )
        ownedChangeCount = pasteboard.changeCount
    }

    /// Clears the pasteboard only if the most recent write is still ours
    /// (changeCount guard) so we never clobber something the user copied
    /// afterwards. Called on database lock; natural expiration also bumps
    /// `changeCount`, so an already-expired copy is left untouched here.
    static func clearOwnedContents() {
        defer { ownedChangeCount = nil }
        guard let ownedChangeCount else { return }

        let pasteboard = UIPasteboard.general
        if pasteboard.changeCount == ownedChangeCount {
            pasteboard.items = []
        }
    }
}
#else
import AppKit

/// macOS pasteboard behavior.
///
/// `NSPasteboard` has no expiration or "local only" options, so the iOS
/// guarantees are approximated as closely as the platform allows:
/// - every copy is marked with `org.nspasteboard.ConcealedType` so clipboard
///   managers (Alfred, Maccy, Paste, ...) skip recording it;
/// - a timer clears the pasteboard after `SettingsService.clipboardTimeout`,
///   guarded by `changeCount` so a later user copy is never clobbered;
/// - `clearOwnedContents()` is invoked on database lock, with the same
///   `changeCount` guard. Every Mac lock trigger (screen lock, screensaver,
///   sleep, user switching, explicit lock) scrubs; the iOS
///   backgrounding exemption does not apply here, since none of those mean
///   the user is switching apps to paste — and macOS has no expiration or
///   Universal Clipboard exclusion to fall back on.
///
/// There is no macOS equivalent of iOS's `.localOnly` (Universal Clipboard
/// exclusion) — Settings documents this honest regression.
@MainActor
enum ClipboardService {
    /// De-facto standard type that tells clipboard managers not to store this
    /// pasteboard entry. See http://nspasteboard.org.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static var pendingClear: Task<Void, Never>?
    private static var ownedChangeCount: Int?

    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("", forType: concealedType)
        ownedChangeCount = pasteboard.changeCount
        scheduleClear(after: SettingsService.clipboardTimeout.seconds)
    }

    /// Clears the pasteboard only if the most recent write is still ours
    /// (changeCount guard) so we never clobber something the user copied
    /// afterwards. Called by the clear timer and on database lock.
    static func clearOwnedContents() {
        pendingClear?.cancel()
        pendingClear = nil

        defer { ownedChangeCount = nil }
        guard let ownedChangeCount else { return }

        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == ownedChangeCount {
            pasteboard.clearContents()
        }
    }

    private static func scheduleClear(after seconds: TimeInterval) {
        pendingClear?.cancel()
        pendingClear = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard Task.isCancelled == false else { return }
            clearOwnedContents()
        }
    }
}
#endif
