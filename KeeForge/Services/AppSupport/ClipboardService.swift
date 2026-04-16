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
