import Foundation

/// Which channel this build was produced for.
///
/// KeeForge for Mac ships two ways from one source tree: through the Mac App
/// Store (universal purchase with iOS) and as a notarized Developer ID direct
/// download. The two differ in what they are *allowed* to contain, not just in
/// how they behave — Sparkle must not be present in an App Store build, and
/// StoreKit is meaningless in a direct one — so the split is a build-time
/// condition, not a runtime setting.
///
/// `KEEFORGE_DIRECT_DOWNLOAD` is defined by the `KeeForgeMacDirect` target only
/// (see `project.yml`). Every other target, including iOS, is an App Store
/// build.
enum DistributionChannel {
    case appStore
    case directDownload

    static var current: DistributionChannel {
        #if KEEFORGE_DIRECT_DOWNLOAD
        .directDownload
        #else
        .appStore
        #endif
    }

    /// StoreKit — the tip jar and the review prompt — only works for an App
    /// Store install. A direct build offers GitHub Sponsors instead.
    static var supportsStoreKit: Bool {
        current == .appStore
    }

    /// Only the direct build updates itself; the App Store build is updated by
    /// the App Store, and shipping a user-reachable updater there is grounds
    /// for rejection.
    static var supportsInAppUpdates: Bool {
        current == .directDownload
    }
}
