#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private func makeController() throws -> SettingsWindowController {
        let suite = "SettingsWindowControllerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agent = MacSSHAgentController(defaults: defaults, notificationCenter: NotificationCenter())
        return SettingsWindowController(listViewModel: DatabaseListViewModel(), sessionStore: DatabaseSessionStore(),
                                        quickAccess: MacQuickAccessController(), sshAgent: agent)
    }

    func testToolbarTabOrderIdentifiersDefaultAndWindowTitle() throws {
        let controller = try makeController()
        let tabs = controller.tabs
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.compactMap { $0.identifier as? String }, MacSettingsTab.allCases.map(\.identifier))
        XCTAssertEqual(tabs.tabViewItems.map(\.label), MacSettingsTab.allCases.map(\.title))
        XCTAssertFalse(try XCTUnwrap(controller.window).canBecomeMain)
        XCTAssertEqual(controller.window?.identifier?.rawValue, "settings")
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 1)
        XCTAssertEqual(controller.window?.title, MacSettingsTab.security.title)
        for tab in MacSettingsTab.allCases {
            let item = try XCTUnwrap(tabs.tabViewItems.first { ($0.identifier as? String) == tab.identifier })
            tabs.tabView.selectTabViewItem(item)
            XCTAssertEqual(controller.window?.title, tab.title)
        }
        controller.close()
    }

    func testCloseRetainsSelectionAndFreshControllerSelectsSecurity() throws {
        let controller = try makeController()
        controller.tabs.select(.appearance)
        controller.close()
        controller.tabs.viewWillAppear()
        XCTAssertEqual(controller.tabs.selectedTabViewItemIndex, 5)
        XCTAssertEqual(controller.window?.title, MacSettingsTab.appearance.title)
        let fresh = try makeController()
        XCTAssertEqual(fresh.tabs.selectedTabViewItemIndex, 1)
        fresh.close()
    }

    func testCapturePolicyAppliedBeforeShowing() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.window?.sharingType,
                       ScreenProtectionService.windowSharingType(blockCapture: SettingsService.blockScreenCapture))
        XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.close()
    }

    func testUpdatesAndMenuMatchBuildChannel() {
        #if KEEFORGE_DIRECT_DOWNLOAD
        XCTAssertTrue(MacAboutSettingsTab.includesUpdates)
        XCTAssertTrue(MainMenu.build().items.flatMap { $0.submenu?.items ?? [] }.contains { $0.title == String(localized: "Check for Updates…") })
        #else
        XCTAssertFalse(MacAboutSettingsTab.includesUpdates)
        XCTAssertFalse(MainMenu.build().items.flatMap { $0.submenu?.items ?? [] }.contains { $0.title == String(localized: "Check for Updates…") })
        #endif
    }

    func testNativeConfirmationsOnlyApplyAcceptedActionsAndClearDoesNotRepublish() throws {
        let account = CloudAccount(id: "test-server", displayName: "Test", provider: "webdav")
        var accounts = [account]
        var cleared = 0
        var refreshed = 0
        let settings = AppSettingsViewModel(refreshCredentials: { refreshed += 1 }, clearCredentialStore: { cleared += 1 },
                                            loadCloudAccounts: { accounts }, signOut: { _ in accounts = [] })
        let tabs = MacSettingsTabController(listViewModel: DatabaseListViewModel(), sessionStore: nil,
                                            quickAccess: nil, sshAgent: nil, settings: settings)
        let window = NSWindow(contentViewController: tabs)
        var answer: ((NSApplication.ModalResponse) -> Void)?
        tabs.presentAlert = { alert, parent, completion in
            XCTAssertTrue(parent === window)
            XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
            answer = completion
        }
        tabs.confirmDisconnect(account)
        answer?(.alertSecondButtonReturn)
        XCTAssertEqual(settings.cloudAccounts, [account])
        tabs.confirmDisconnect(account)
        answer?(.alertFirstButtonReturn)
        XCTAssertTrue(settings.cloudAccounts.isEmpty)
        tabs.confirmClearEntries()
        answer?(.alertSecondButtonReturn)
        XCTAssertEqual(cleared, 0)
        tabs.confirmClearEntries()
        answer?(.alertFirstButtonReturn)
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(refreshed, 0)
        window.close()
    }
}
#endif
