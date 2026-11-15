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
        prepareWindow: (NSWindow) -> Void = { window in
            window.sharingType = ScreenProtectionService.windowSharingType(blockCapture: SettingsService.blockScreenCapture)
        }
    ) {
        tabs = MacSettingsTabController(listViewModel: listViewModel, sessionStore: sessionStore,
                                       quickAccess: quickAccess, sshAgent: sshAgent)
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
        super.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum MacSettingsTab: String, CaseIterable {
    case general, security, autofill, quickSearch = "quick-search", sshAgent = "ssh-agent", appearance, servers, about

    var identifier: String { "settings.tab.\(rawValue)" }
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .security: String(localized: "Security")
        case .autofill: String(localized: "AutoFill")
        case .quickSearch: String(localized: "Quick Search")
        case .sshAgent: String(localized: "SSH Agent")
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
        case .appearance: "circle.lefthalf.filled"
        case .servers: "server.rack"
        case .about: "info.circle"
        }
    }
    var contentSize: NSSize {
        let height: CGFloat = switch self {
        case .general: 420
        case .security: 700
        case .autofill: 530
        case .quickSearch: 300
        case .sshAgent: 500
        case .appearance: 300
        case .servers: 360
        case .about: 560
        }
        return NSSize(width: 900, height: height)
    }
}

@MainActor
final class MacSettingsTabController: NSTabViewController {
    let settings: AppSettingsViewModel
    private var acknowledgmentsSheet: NSWindow?
    var presentAlert: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }

    init(listViewModel: DatabaseListViewModel, sessionStore: DatabaseSessionStore?,
         quickAccess: MacQuickAccessController?, sshAgent: MacSSHAgentController?,
         settings: AppSettingsViewModel = AppSettingsViewModel()) {
        self.settings = settings
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
            case .appearance: content = AnyView(MacAppearanceSettingsTab(settings: settings))
            case .servers:
                content = AnyView(MacServersSettingsTab(settings: settings, disconnect: { [weak self] in self?.confirmDisconnect($0) }))
            case .about:
                content = AnyView(MacAboutSettingsTab(acknowledgments: { [weak self] in self?.showAcknowledgments() }))
            }
            let hosting = NSHostingController(rootView: ScrollView {
                // The board's centred label and control columns; unbounded, long captions run past the window.
                content.frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
            }
                .accessibilityIdentifier(tab.identifier)
                .modifier(MacHostingAppearance()))
            hosting.sizingOptions = []
            hosting.preferredContentSize = tab.contentSize
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

    private func updateWindow(for item: NSTabViewItem) {
        guard let window = view.window, let controller = item.viewController else { return }
        window.title = item.label
        window.setContentSize(controller.preferredContentSize)
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
