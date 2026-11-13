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
        // Settings picks its own database where it needs one (SSH Agent), never the focused window's.
        let hosting = NSHostingController(rootView: SettingsView(listViewModel: listViewModel)
            .environment(sessionStore)
            .environment(quickAccess)
            .environment(sshAgent)
            .modifier(MacHostingAppearance()))
        hosting.sizingOptions = [.preferredContentSize]
        let window = SettingsWindow(contentViewController: hosting)
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

/// An auxiliary window: database commands keep targeting the main database window behind it.
private final class SettingsWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}
