import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        listViewModel: DatabaseListViewModel,
        sessionStore: DatabaseSessionStore,
        quickAccess: MacQuickAccessController,
        sshAgent: MacSSHAgentController
    ) {
        let hosting = NSHostingController(rootView: MacSettingsRoot(listViewModel: listViewModel, sessionStore: sessionStore)
            .environment(sessionStore)
            .environment(quickAccess)
            .environment(sshAgent)
            .modifier(MacHostingAppearance()))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Settings")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.setAccessibilityIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct MacSettingsRoot: View {
    let listViewModel: DatabaseListViewModel
    let sessionStore: DatabaseSessionStore

    var body: some View {
        SettingsView(viewModel: sessionStore.activeSession, listViewModel: listViewModel)
    }
}
