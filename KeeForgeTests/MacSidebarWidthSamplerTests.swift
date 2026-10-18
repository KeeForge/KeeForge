#if os(macOS)
import XCTest
@testable import KeeForge

final class MacSidebarWidthSamplerTests: XCTestCase {
    func testFirstLayoutIsNotAPreference() {
        var sampler = MacSidebarWidthSampler()

        XCTAssertNil(sampler.preferredWidth(sidebarWidth: 240, splitWidth: 1_000))
    }

    func testDividerDragInAnUnchangedWindowIsRemembered() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 240, splitWidth: 1_000)

        XCTAssertEqual(sampler.preferredWidth(sidebarWidth: 300, splitWidth: 1_000), 300)
        XCTAssertEqual(sampler.preferredWidth(sidebarWidth: 320, splitWidth: 1_000), 320)
    }

    func testWidthCompressedByANarrowerWindowIsNotRemembered() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 320, splitWidth: 1_000)

        XCTAssertNil(sampler.preferredWidth(sidebarWidth: 250, splitWidth: 700))
        XCTAssertNil(sampler.preferredWidth(sidebarWidth: 280, splitWidth: 900))
    }

    func testDragAfterAWindowResizeIsRememberedAgain() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 320, splitWidth: 1_000)
        _ = sampler.preferredWidth(sidebarWidth: 250, splitWidth: 700)

        XCTAssertEqual(sampler.preferredWidth(sidebarWidth: 230, splitWidth: 700), 230)
    }

    func testUnknownSplitWidthIsNotAPreference() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 240, splitWidth: nil)

        XCTAssertNil(sampler.preferredWidth(sidebarWidth: 300, splitWidth: nil))
    }

    func testCollapsedAndInvalidWidthsAreIgnored() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 240, splitWidth: 1_000)

        XCTAssertNil(sampler.preferredWidth(sidebarWidth: 0, splitWidth: 1_000))
        XCTAssertNil(sampler.preferredWidth(sidebarWidth: .infinity, splitWidth: 1_000))
        XCTAssertNil(sampler.preferredWidth(sidebarWidth: .nan, splitWidth: 1_000))
    }

    func testWidthBeyondTheColumnMaximumIsClamped() {
        var sampler = MacSidebarWidthSampler()
        _ = sampler.preferredWidth(sidebarWidth: 240, splitWidth: 1_000)

        XCTAssertEqual(sampler.preferredWidth(sidebarWidth: 400, splitWidth: 1_000), MacSidebarWidthSampler.maximumWidth)
    }
}
#endif
