import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    let tabs: MacSettingsTabController

    init(
        listViewModel: DatabaseListViewModel,
        sessionStore: DatabaseSessionStore,
        quickAccess: MacQuickAccessController,
        sshAgent: MacSSHAgentController,
        browserBridge: MacBrowserBridgeController,
        browserHosts: any BrowserHostInstalling,
        prepareWindow: (NSWindow) -> Void = { window in
            window.sharingType = ScreenProtectionService.windowSharingType(blockCapture: SettingsService.blockScreenCapture)
        }
    ) {
        tabs = MacSettingsTabController(listViewModel: listViewModel, sessionStore: sessionStore,
                                       quickAccess: quickAccess, sshAgent: sshAgent,
                                       browserBridge: MacBrowserBridgeSettingsModel(controller: browserBridge, installer: browserHosts))
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.setAccessibilityIdentifier("settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.select(.security)
        prepareWindow(window)
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        tabs.settings.reload()
        tabs.browserBridge?.reload()
        // Sizes the window to the selected tab while it is still hidden.
        tabs.sizeWindowToSelectedTab()
        super.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum MacSettingsTab: String, CaseIterable {
    case general, security, autofill, quickSearch = "quick-search", sshAgent = "ssh-agent", browsers, appearance, servers, about

    var identifier: String { "settings.tab.\(rawValue)" }
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .security: String(localized: "Security")
        case .autofill: String(localized: "AutoFill")
        case .quickSearch: String(localized: "Quick Search")
        case .sshAgent: String(localized: "SSH Agent")
        case .browsers: String(localized: "Browsers")
        case .appearance: String(localized: "Appearance")
        case .servers: String(localized: "Servers")
        case .about: String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .security: "lock.shield"
        case .autofill: "text.cursor"
        case .quickSearch: "magnifyingglass"
        case .sshAgent: "terminal"
        case .browsers: "globe"
        case .appearance: "circle.lefthalf.filled"
        case .servers: "server.rack"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class MacSettingsTabController: NSTabViewController {
    let settings: AppSettingsViewModel
    let browserBridge: MacBrowserBridgeSettingsModel?
    private var acknowledgmentsSheet: NSWindow?
    var presentAlert: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }

    init(listViewModel: DatabaseListViewModel, sessionStore: DatabaseSessionStore?,
         quickAccess: MacQuickAccessController?, sshAgent: MacSSHAgentController?,
         browserBridge: MacBrowserBridgeSettingsModel?,
         settings: AppSettingsViewModel = AppSettingsViewModel()) {
        self.settings = settings
        self.browserBridge = browserBridge
        super.init(nibName: nil, bundle: nil)
        settings.connect(to: sessionStore)
        tabStyle = .toolbar
        transitionOptions = []
        for tab in MacSettingsTab.allCases {
            let content: AnyView
            switch tab {
            case .general: content = AnyView(MacGeneralSettingsTab(settings: settings))
            case .security: content = AnyView(MacSecuritySettingsTab(settings: settings))
            case .autofill:
                content = AnyView(MacAutoFillSettingsTab(settings: settings, listViewModel: listViewModel,
                                                       clearEntries: { [weak self] in self?.confirmClearEntries() }))
            case .quickSearch:
                guard let quickAccess else { continue }
                content = AnyView(MacQuickSearchSettingsTab(controller: quickAccess))
            case .sshAgent:
                guard let sshAgent else { continue }
                content = AnyView(MacSSHAgentSettingsTab(controller: sshAgent))
            case .browsers:
                guard let browserBridge else { continue }
                content = AnyView(MacBrowsersSettingsTab(model: browserBridge))
            case .appearance: content = AnyView(MacAppearanceSettingsTab(settings: settings))
            case .servers:
                content = AnyView(MacServersSettingsTab(settings: settings, disconnect: { [weak self] in self?.confirmDisconnect($0) }))
            case .about:
                content = AnyView(MacAboutSettingsTab(acknowledgments: { [weak self] in self?.showAcknowledgments() }))
            }
            let hosting = NSHostingController(rootView: MacSettingsPane(onHeightChange: { [weak self] height in
                self?.contentHeightChanged(height, for: tab)
            }) { content }
                .accessibilityIdentifier(tab.identifier)
                .modifier(MacHostingAppearance()))
            hosting.sizingOptions = []
            hosting.preferredContentSize = MacSettingsLayout.contentSize(forContentHeight: 0)
            // The tab controller passes the shown tab's title to the window, so an untitled tab blanks it.
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = tab.identifier
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        select(.security)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillAppear() {
        super.viewWillAppear()
        settings.reload()
    }

    func select(_ tab: MacSettingsTab) {
        guard let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab.identifier }) else { return }
        selectedTabViewItemIndex = index
        updateWindow(for: tabViewItems[index])
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tabViewItem { updateWindow(for: tabViewItem) }
    }

    /// Each tab is as tall as its content, up to `MacSettingsLayout.maximumHeight`, where it scrolls.
    private func contentHeightChanged(_ height: CGFloat, for tab: MacSettingsTab) {
        guard let item = tabViewItems.first(where: { ($0.identifier as? String) == tab.identifier }),
              let controller = item.viewController else { return }
        let size = MacSettingsLayout.contentSize(forContentHeight: height)
        guard controller.preferredContentSize != size else { return }
        controller.preferredContentSize = size
        // A hidden window is sized when it is shown or the tab selected; a shown one after this layout pass.
        guard view.window?.isVisible == true else { return }
        DispatchQueue.main.async { [weak self] in self?.sizeWindowToSelectedTab() }
    }

    func sizeWindowToSelectedTab() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        updateWindow(for: tabViewItems[selectedTabViewItemIndex])
    }

    private func updateWindow(for item: NSTabViewItem) {
        guard let window = view.window, let controller = item.viewController else { return }
        window.title = item.label
        // Measures a tab shown for the first time before sizing the window to it.
        controller.view.layoutSubtreeIfNeeded()
        let target = controller.preferredContentSize
        guard let current = window.contentView?.frame.size, current != target else { return }
        // Keeps the title bar and toolbar in place, as system Settings panes do.
        var frame = window.frame
        frame.size.width += target.width - current.width
        frame.size.height += target.height - current.height
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func confirmClearEntries() {
        confirm(title: String(localized: "Clear AutoFill Entries?"),
                message: String(localized: "This removes all suggestions from AutoFill. Suggestions return the next time you unlock each database that has AutoFill turned on."),
                button: String(localized: "Clear Entries"), identifier: "settings.autofill.clear-entries.confirm") { [weak self] in
            self?.settings.clearAutoFillEntries()
        }
    }

    func confirmDisconnect(_ account: CloudAccount) {
        confirm(title: String(localized: "Disconnect Server?"),
                message: String(localized: "Disconnect \(account.displayName)? KeeForge will keep any cached databases until you remove them."),
                button: String(localized: "Disconnect"), identifier: "settings.cloud.signout.confirm") { [weak self] in
            self?.settings.signOut(account)
        }
    }

    private func confirm(title: String, message: String, button: String, identifier: String,
                         action: @escaping () -> Void) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button).setAccessibilityIdentifier(identifier)
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        presentAlert(alert, window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    func showAcknowledgments() {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let hosting = NSHostingController(rootView: VStack {
            AcknowledgmentsView()
            HStack {
                Spacer()
                Button("Done") { [weak self] in self?.endAcknowledgments() }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 620, height: 500)
            .onExitCommand { [weak self] in self?.endAcknowledgments() }
            .modifier(MacHostingAppearance()))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.title = String(localized: "Acknowledgments")
        sheet.styleMask = [.titled]
        sheet.sharingType = window.sharingType
        acknowledgmentsSheet = sheet
        window.beginSheet(sheet) { [weak self] _ in self?.acknowledgmentsSheet = nil }
    }

    private func endAcknowledgments() {
        guard let sheet = acknowledgmentsSheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        acknowledgmentsSheet = nil
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}
