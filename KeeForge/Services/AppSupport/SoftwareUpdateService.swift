#if KEEFORGE_DIRECT_DOWNLOAD
import Sparkle
import SwiftUI

/// In-app updates for the notarized direct-download build.
///
/// Only this channel compiles: the Mac App Store target does not link Sparkle,
/// so nothing here exists in that binary. Sparkle runs inside the sandbox with
/// the Hardened Runtime and no `com.apple.security.cs.*` exceptions — Xcode
/// signs its XPC services with the team id, and library validation permits a
/// same-team load. Do not add exceptions to make an update work; a failure
/// there means the signing is wrong, not the entitlements.
///
/// The feed URL and the public EdDSA key come from `SUFeedURL` /
/// `SUPublicEDKey` in `KeeForgeMac/Info.plist`, which read the
/// `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` build settings.
@MainActor
final class SoftwareUpdateService {
    static let shared = SoftwareUpdateService()

    private let controller: SPUStandardUpdaterController

    private init() {
        // `startingUpdater: true` is safe here because a misconfigured feed
        // only disables update checks; it does not block launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// "Check for Updates…" for the app menu. Present only in the direct build —
/// the App Store build is updated by the App Store, and a user-reachable
/// updater there is grounds for rejection.
struct CheckForUpdatesCommand: View {
    @State private var canCheckForUpdates = SoftwareUpdateService.shared.canCheckForUpdates

    var body: some View {
        Button("Check for Updates…") {
            SoftwareUpdateService.shared.checkForUpdates()
        }
        .disabled(canCheckForUpdates == false)
        .task {
            canCheckForUpdates = SoftwareUpdateService.shared.canCheckForUpdates
        }
    }
}
#endif
