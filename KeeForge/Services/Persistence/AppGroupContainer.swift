import Foundation

/// Single resolution point for the App Group storage the app and its AutoFill
/// extensions share: the container directory and the shared `UserDefaults`
/// suite. Every reader and writer of shared storage goes through here.
///
/// Under an injected XCTest unit-test bundle both are redirected to throwaway
/// per-process locations. `KeeForgeMacTests` is hosted by the real signed Mac
/// app, so a test run would otherwise operate on
/// `~/Library/Group Containers/group.com.keevault.shared` — the developer's own
/// storage — and several suites call `DatabaseListStore.clearAll()` from
/// `setUp`, which deletes the database list, the backups root, and pending
/// upload markers outright. The redirect lives here rather than in each store
/// so a future writer cannot miss it, and it is decided before any test code
/// runs so there is no window in which a suite can reach the real container.
///
/// Extension-safe: pure Foundation.
enum AppGroupContainer {
    /// The App Group declared in every target's entitlements.
    static let identifier = "group.com.keevault.shared"

    /// True when this process hosts an injected XCTest unit-test bundle.
    ///
    /// XCTest sets `XCTestConfigurationFilePath` only in a unit-test host. A UI
    /// test's app under test never gets it, so `KeeForgeUITests` and
    /// `KeeForgeMacUITests` keep exercising the real container and stay able to
    /// share it with the separate AutoFill extension process.
    static let isRedirectedForTesting =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var url: URL {
        resolvedURL ?? FileManager.default.temporaryDirectory
    }

    /// The container as the system reports it, `nil` when the App Group is
    /// denied or undeclared. Only `MacTransitionNoticeService` needs that
    /// distinction — the denial is the signal it reads. Everything else wants
    /// `url`, which absorbs the nil into a temporary directory.
    static var resolvedURL: URL? {
        isRedirectedForTesting
            ? testContainerURL
            : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults {
        isRedirectedForTesting ? testDefaults : liveDefaults
    }

    private static var liveDefaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    private static let testSuiteName = identifier + ".unit-tests"

    /// Emptied on first use so a previous run's leftovers cannot leak in.
    private static let testContainerURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeForgeUnitTestAppGroup", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private nonisolated(unsafe) static let testDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: testSuiteName) else { return .standard }
        defaults.removePersistentDomain(forName: testSuiteName)
        return defaults
    }()
}
