#if KEEFORGE_DIRECT_DOWNLOAD
import Combine
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
/// `SUEnableAutomaticChecks` turns on daily background checks by default;
/// Sparkle persists the user's later choice in its own defaults.
@MainActor
@Observable
final class SoftwareUpdateService {
    static let shared: SoftwareUpdateService = {
        // `startingUpdater: true` is safe here because a misconfigured feed
        // only disables update checks; it does not block launch.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = controller.updater
        return SoftwareUpdateService(
            readiness: updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher(),
            checkForUpdates: { updater.checkForUpdates() },
            automaticChecks: updater.automaticallyChecksForUpdates,
            setAutomaticChecks: { updater.automaticallyChecksForUpdates = $0 }
        )
    }()

    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates: Bool {
        didSet { applyAutomaticChecks(automaticallyChecksForUpdates) }
    }
    @ObservationIgnored private var readinessSubscription: AnyCancellable?
    @ObservationIgnored private let performUpdateCheck: @MainActor () -> Void
    @ObservationIgnored private let applyAutomaticChecks: @MainActor (Bool) -> Void

    init(
        readiness: AnyPublisher<Bool, Never>,
        checkForUpdates: @escaping @MainActor () -> Void,
        automaticChecks: Bool,
        setAutomaticChecks: @escaping @MainActor (Bool) -> Void
    ) {
        performUpdateCheck = checkForUpdates
        automaticallyChecksForUpdates = automaticChecks
        applyAutomaticChecks = setAutomaticChecks
        readinessSubscription = readiness
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = ready
                }
            }
    }

    func checkForUpdates() {
        performUpdateCheck()
    }
}

/// "Check for Updates…" for the app menu. Present only in the direct build —
/// the App Store build is updated by the App Store, and a user-reachable
/// updater there is grounds for rejection.
struct CheckForUpdatesCommand: View {
    var body: some View {
        Button("Check for Updates…") {
            SoftwareUpdateService.shared.checkForUpdates()
        }
        .disabled(SoftwareUpdateService.shared.canCheckForUpdates == false)
    }
}

/// The Updates section of the Mac Settings window's About tab.
struct SoftwareUpdateSettingsSection: View {
    @Bindable private var service = SoftwareUpdateService.shared

    var body: some View {
        Section("Updates") {
            Toggle("Automatically Check for Updates", isOn: $service.automaticallyChecksForUpdates)
                .accessibilityIdentifier("settings.updates.automatic-checks")
            CheckForUpdatesCommand()
                .accessibilityIdentifier("settings.updates.check-now")
        }
    }
}
#endif
