#if os(iOS)
import UIKit
#else
import Foundation
#endif

@MainActor
enum HapticService {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        // No haptics on macOS.
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        // No haptics on macOS.
    }
}
