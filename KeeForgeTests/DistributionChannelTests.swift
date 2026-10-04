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

}
