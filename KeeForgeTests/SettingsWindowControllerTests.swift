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
        let bridgeDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = BrowserPairingStore(defaults: UserDefaults(suiteName: suite)!, keychain: FakeBrowserBridgeKeychain())
        let bridge = MacBrowserBridgeController(defaults: bridgeDefaults, store: store, socketPath: nil)
        return SettingsWindowController(listViewModel: DatabaseListViewModel(), sessionStore: DatabaseSessionStore(),
                                        quickAccess: MacQuickAccessController(), sshAgent: agent,
                                        browserBridge: bridge, browserHosts: FakeBrowserHostInstaller())
    }

    func testToolbarTabOrderIdentifiersDefaultAndWindowTitle() throws {
        let controller = try makeController()
        let tabs = controller.tabs
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.compactMap { $0.identifier as? String }, MacSettingsTab.allCases.map(\.identifier))
        XCTAssertEqual(tabs.tabViewItems.map(\.label), MacSettingsTab.allCases.map(\.title))
        XCTAssertEqual(tabs.tabViewItems.map { $0.viewController?.title }, MacSettingsTab.allCases.map(\.title))
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

    func testEveryTabSharesOneWidthAndIsAsTallAsItsContent() throws {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        let top = window.frame.maxY
        var heights: [MacSettingsTab: CGFloat] = [:]
        for tab in MacSettingsTab.allCases {
            controller.tabs.select(tab)
            let size = try XCTUnwrap(window.contentView?.frame.size)
            XCTAssertEqual(size.width, MacSettingsLayout.windowWidth, tab.rawValue)
            XCTAssertGreaterThanOrEqual(size.height, MacSettingsLayout.minimumHeight, tab.rawValue)
            XCTAssertLessThanOrEqual(size.height, MacSettingsLayout.maximumHeight, tab.rawValue)
            XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "Switching to \(tab.rawValue) moved the title bar")
            heights[tab] = size.height
        }
        XCTAssertLessThan(try XCTUnwrap(heights[.appearance]), try XCTUnwrap(heights[.security]))
        controller.close()
    }

    /// `MacAppAppearance` applies the setting to the whole app; the window pins none of its own.
    func testWindowLeavesTheAppearanceToTheAppSeam() async throws {
        let original = SettingsService.appearanceMode
        defer { SettingsService.appearanceMode = original }
        SettingsService.appearanceMode = .light
        let controller = try makeController()
        XCTAssertNil(controller.window?.appearance)
        controller.tabs.settings.appearanceMode = .dark
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(SettingsService.appearanceMode, .dark, "The setting is written for the seam to read")
        XCTAssertNil(controller.window?.appearance)
        controller.close()
    }

    func testCloseRetainsSelectionAndFreshControllerSelectsSecurity() throws {
        let controller = try makeController()
        controller.tabs.select(.appearance)
        controller.close()
        controller.tabs.viewWillAppear()
        XCTAssertEqual(controller.tabs.selectedTabViewItemIndex, 6)
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
                                            quickAccess: nil, sshAgent: nil, browserBridge: nil, settings: settings)
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

    /// The Browsers tab's Remove… and Remove All… buttons call these. The alert is gone before its
    /// completion runs, as with a real sheet, so the confirmed removal must not depend on state the dismissal clears.
    func testBrowserRemovalConfirmationsRemoveOnlyAfterTheDestructiveAnswer() async throws {
        let suite = "SettingsWindowControllerTests.browsers.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeBrowserBridgeKeychain()
        let store = BrowserPairingStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain)
        func browser(_ name: String, byte: UInt8) -> PairedBrowser {
            let key = Data(repeating: byte, count: 32)
            return PairedBrowser(clientID: BrowserBridgeCrypto.clientID(key), publicKey: key, name: name, pairedAt: Date())
        }
        let brave = browser("Brave", byte: 1), arc = browser("Arc", byte: 2)
        try await store.addOrReplace(brave)
        try await store.addOrReplace(arc)
        let bridge = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: nil)
        defer { bridge.stop() }
        bridge.start()
        let model = MacBrowserBridgeSettingsModel(controller: bridge, installer: FakeBrowserHostInstaller())
        func wait(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
            var tries = 0
            while try await !condition(), tries < 500 {
                tries += 1
                try await Task.sleep(for: .milliseconds(10))
            }
            let met = try await condition()
            XCTAssertTrue(met, what)
        }
        try await wait("Loaded") { model.pairedRows.count == 2 }
        let tabs = MacSettingsTabController(listViewModel: DatabaseListViewModel(), sessionStore: nil,
                                            quickAccess: nil, sshAgent: nil, browserBridge: model)
        let window = NSWindow(contentViewController: tabs)
        defer { window.close() }
        var shown: NSAlert?
        var answer: ((NSApplication.ModalResponse) -> Void)?
        tabs.presentAlert = { alert, parent, completion in
            XCTAssertTrue(parent === window)
            shown = alert
            answer = completion
        }
        let row = try XCTUnwrap(model.pairedRows.first { $0.name == "Brave" })

        tabs.confirmRemoveBrowser(row)
        let alert = try XCTUnwrap(shown)
        XCTAssertEqual(alert.messageText, String(localized: "Remove “\("Brave")”?"))
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Remove"), String(localized: "Cancel")])
        XCTAssertEqual(alert.buttons.first?.accessibilityIdentifier(), "settings.browsers.remove.confirm")
        XCTAssertTrue(alert.buttons.first?.hasDestructiveAction == true)
        try await Task.sleep(for: .milliseconds(50))
        var listed = try await store.list()
        XCTAssertEqual(listed.count, 2, "Asking removes nothing")
        answer?(.alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(50))
        listed = try await store.list()
        XCTAssertEqual(listed.count, 2, "Cancel removes nothing")

        tabs.confirmRemoveBrowser(row)
        answer?(.alertFirstButtonReturn)
        try await wait("Brave removed") { try await store.list().map(\.clientID) == [arc.clientID] }
        try await wait("The tab's list follows") { model.pairedRows.map(\.id) == [arc.clientID] }
        XCTAssertFalse(model.removalFailed)

        tabs.confirmRemoveAllBrowsers()
        XCTAssertEqual(shown?.messageText, String(localized: "Remove All Browsers?"))
        answer?(.alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(keychain.deletions, 0)
        tabs.confirmRemoveAllBrowsers()
        answer?(.alertFirstButtonReturn)
        try await wait("All removed") { try await store.list().isEmpty }
        try await wait("Key deleted") { keychain.deletions == 1 }
        XCTAssertFalse(model.removalFailed)
    }
}
#endif
