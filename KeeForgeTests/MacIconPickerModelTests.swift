#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacIconPickerModelTests: XCTestCase {
    func testGroupOffersOnlyStandardIconsAndUseRequiresAValidChange() {
        let model = MacIconPickerModel(purpose: .group, selection: .standard(iconID: 48),
                                       customIcons: [.init(id: UUID(), data: Data([1]))], websiteURL: "https://example.com")
        XCTAssertTrue(model.customIcons.isEmpty)
        XCTAssertNil(model.websiteHost)
        XCTAssertEqual(model.standardIconIDs, KPEntry.standardIconNames.keys.sorted())
        XCTAssertFalse(model.canUse)
        model.selection = .standard(iconID: 1)
        XCTAssertTrue(model.canUse)
        model.selection = .custom(uuid: UUID())
        XCTAssertFalse(model.canUse)
        model.selection = .standard(iconID: -1)
        XCTAssertFalse(model.canUse)
    }

    func testEntryCustomSelectionRefreshAndSuccessfulDownload() async {
        let first = DatabaseViewModel.CustomIcon(id: UUID(), data: Data([1]))
        let second = DatabaseViewModel.CustomIcon(id: UUID(), data: Data([2]))
        let model = MacIconPickerModel(purpose: .entry, selection: .custom(uuid: first.id),
                                       customIcons: [first, second], websiteURL: "https://example.com")
        XCTAssertFalse(model.canUse)
        model.selection = .custom(uuid: second.id)
        XCTAssertTrue(model.canUse)
        model.refreshCustomIcons([first])
        XCTAssertFalse(model.canUse)
        model.selection = .standard(iconID: 1)
        var completions = 0
        model.download({ await Task.yield() }) { completions += 1 }
        XCTAssertFalse(model.canUse)
        for _ in 0..<16 { await Task.yield() }
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(model.isDownloading)
        XCTAssertNil(model.errorMessage)
        model.end()
    }

    func testEntryHostDownloadFailureAndEndRejectLateCompletion() async {
        let model = MacIconPickerModel(purpose: .entry, selection: .standard(iconID: 0), websiteURL: "https://example.com/private?q=secret")
        XCTAssertEqual(model.websiteHost, "example.com")
        var completed = false
        model.download({ throw SaveError.saveContextUnavailable }) { completed = true }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(model.isDownloading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(completed)
        model.download({ await Task.yield() }) { completed = true }
        XCTAssertTrue(model.isDownloading)
        model.end()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(completed)
        XCTAssertNil(model.errorMessage)
        model.selection = .standard(iconID: 1)
        XCTAssertFalse(model.canUse)
    }
}
#endif
