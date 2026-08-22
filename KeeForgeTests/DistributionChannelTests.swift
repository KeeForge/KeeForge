import XCTest
@testable import KeeForge

/// The channel seam decides what a build is *allowed* to contain, so these
/// assertions are about the build itself, not about runtime state. They fail
/// loudly if the `KEEFORGE_DIRECT_DOWNLOAD` condition is ever set on the wrong
/// target — which would either ship Sparkle to the App Store or ship a direct
/// build that tries to talk to StoreKit.
final class DistributionChannelTests: XCTestCase {

    func testStoreKitAndUpdatesAreMutuallyExclusive() {
        XCTAssertNotEqual(
            DistributionChannel.supportsStoreKit,
            DistributionChannel.supportsInAppUpdates,
            "A build either sells through the App Store or updates itself, never both"
        )
    }

    func testChannelMatchesCompilationCondition() {
        #if KEEFORGE_DIRECT_DOWNLOAD
        XCTAssertEqual(DistributionChannel.current, .directDownload)
        XCTAssertFalse(DistributionChannel.supportsStoreKit)
        XCTAssertTrue(DistributionChannel.supportsInAppUpdates)
        #else
        XCTAssertEqual(DistributionChannel.current, .appStore)
        XCTAssertTrue(DistributionChannel.supportsStoreKit)
        XCTAssertFalse(DistributionChannel.supportsInAppUpdates)
        #endif
    }

    /// The unit suites host in the App Store app. If this ever fails, the test
    /// host is the direct build — which also means the tests just ran against a
    /// binary with Sparkle linked in. Asserted on the channel rather than on
    /// `ReviewPromptService.isAppStoreBuild`, which is a mutable seam other
    /// suites drive and execution order is randomized.
    func testTestHostIsAnAppStoreBuild() {
        XCTAssertEqual(DistributionChannel.current, .appStore)
    }
}
