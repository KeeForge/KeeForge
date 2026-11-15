#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import KeeForge

@MainActor
final class MacAppAppearanceTests: XCTestCase {
    func testTheSettingReachesTheAppAndFollowsEveryChange() async {
        let center = NotificationCenter()
        var mode = SettingsService.AppearanceMode.dark
        var applied: [NSAppearance.Name?] = []
        let seam = MacAppAppearance(notificationCenter: center, readMode: { mode },
                                    setAppearance: { applied.append($0?.name) })
        seam.start()
        XCTAssertEqual(applied, [.darkAqua], "Applied once at launch")

        for (next, expected) in [(SettingsService.AppearanceMode.light, NSAppearance.Name?.some(.aqua)),
                                 (.system, nil), (.dark, .darkAqua)] {
            mode = next
            let count = applied.count
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            for _ in 0..<20 where applied.count == count { await Task.yield() }
            XCTAssertEqual(applied.count, count + 1, next.rawValue)
            XCTAssertEqual(applied.last ?? nil, expected, next.rawValue)
        }

        center.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(applied.count, 4, "An unrelated defaults change leaves the appearance alone")
    }

    func testStartingTwiceObservesOnce() async {
        let center = NotificationCenter()
        var mode = SettingsService.AppearanceMode.system
        var calls = 0
        let seam = MacAppAppearance(notificationCenter: center, readMode: { mode }, setAppearance: { _ in calls += 1 })
        seam.start()
        seam.start()
        mode = .light
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 2)
    }

    func testModesMapToTheSystemAppearances() {
        XCTAssertNil(SettingsService.AppearanceMode.system.appAppearance)
        XCTAssertEqual(SettingsService.AppearanceMode.light.appAppearance?.name, .aqua)
        XCTAssertEqual(SettingsService.AppearanceMode.dark.appAppearance?.name, .darkAqua)
    }

    func testTheEditorSavingScrimDimsHarderInDark() throws {
        func alpha(_ name: NSAppearance.Name) throws -> CGFloat {
            var value: CGFloat = 0
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                value = MacEntryEditorHeaderLayout.savingScrimColor.usingColorSpace(.sRGB)?.alphaComponent ?? 0
            }
            return value
        }
        XCTAssertEqual(try alpha(.aqua), 0.14, accuracy: 0.001)
        XCTAssertEqual(try alpha(.darkAqua), 0.45, accuracy: 0.001)
    }

    func testTheLockedTileShadowIsPlainBlackInDark() {
        XCTAssertEqual(MacLockedPageHeader.tileShadow(for: .dark), Color.black.opacity(0.45))
        XCTAssertNotEqual(MacLockedPageHeader.tileShadow(for: .light), MacLockedPageHeader.tileShadow(for: .dark))
    }
}

final class MacEntryEditorHeaderLayoutTests: XCTestCase {
    func testCompactWidthShrinksTheButtonsAndDropsTheShortcutHint() {
        let regular = MacEntryEditorHeaderLayout(metrics: .forWidth(600))
        XCTAssertEqual(regular.controlSize, .large)
        XCTAssertTrue(regular.showsShortcutHint)
        let compact = MacEntryEditorHeaderLayout(metrics: .forWidth(440))
        XCTAssertEqual(compact.controlSize, .regular)
        XCTAssertFalse(compact.showsShortcutHint)
    }
}
#endif
