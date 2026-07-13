#if os(iOS)
import UIKit

enum ClipboardService {
    static func copy(_ string: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: string]],
            options: [
                .expirationDate: Date().addingTimeInterval(SettingsService.clipboardTimeout.seconds),
                .localOnly: true,
            ]
        )
    }
}
#else
import AppKit

enum ClipboardService {
    // Basic NSPasteboard set for slice 01. NSPasteboard has no expiration
    // support, so the iOS auto-clear guarantee does not carry over yet; the
    // full macOS auto-clear behavior (timer-based clearing) lands in slice 02.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
#endif
