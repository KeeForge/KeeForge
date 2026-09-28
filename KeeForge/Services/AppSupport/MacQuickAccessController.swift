#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The AppKit half of quick access: the status item and the panel it opens.
/// `MacQuickSearchPanel` is the real one; tests substitute a fake.
@MainActor
protocol MacQuickSearchPanelPresenting: AnyObject {
    var isPanelVisible: Bool { get }
    var onToggleRequested: (() -> Void)? { get set }
    func setStatusItemVisible(_ visible: Bool)
    func showPanel()
    func hidePanel(restoringPreviousApp: Bool)
}

@MainActor
protocol MacHotKeyRegistering: AnyObject {
    var onPressed: (() -> Void)? { get set }
    func register(_ hotKey: SettingsService.MacHotKey) -> Bool
    func unregister()
}

extension MacGlobalHotKey: MacHotKeyRegistering {}

/// Owns the optional menu bar item, the quick-search panel behind it, and the
/// global shortcut that opens that panel from any app.
///
/// Both are opt-in (`SettingsService`), and the shortcut only exists while the
/// menu bar item does: the panel hangs off the item, and a system-wide key
/// combination with nothing visible behind it would be hard to trace back to
/// KeeForge.
///
/// Nothing here changes a lock rule. The panel reads the one active session,
/// so every existing lock trigger empties it, and a locked or missing session
/// sends the user to the main window to choose and unlock a database.
@MainActor
@Observable
final class MacQuickAccessController {
    let searchModel: MacQuickSearchViewModel

    var isMenuBarItemEnabled: Bool {
        didSet {
            guard oldValue != isMenuBarItemEnabled else { return }
            SettingsService.macMenuBarQuickAccessEnabled = isMenuBarItemEnabled
            apply()
        }
    }

    var shortcut: SettingsService.MacHotKey? {
        didSet {
            guard oldValue != shortcut else { return }
            SettingsService.macQuickSearchShortcut = shortcut
            apply()
        }
    }

    /// The shortcut is released while Settings records a new one, so pressing
    /// the current combination records it instead of opening the panel.
    var isRecordingShortcut = false {
        didSet {
            guard oldValue != isRecordingShortcut else { return }
            apply()
        }
    }

    /// macOS refused the shortcut, normally because another app holds it.
    private(set) var isShortcutUnavailable = false

    /// Opens a new main window; set by the app, which owns `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored weak var mainWindow: NSWindow?

    @ObservationIgnored private let presenter: MacQuickSearchPanelPresenting
    @ObservationIgnored private let hotKey: MacHotKeyRegistering
    @ObservationIgnored private let activateApp: @MainActor () -> Void
    @ObservationIgnored private var isStarted = false

    init(
        sessionProvider: @escaping MacQuickSearchViewModel.SessionProvider = { nil },
        presenter: MacQuickSearchPanelPresenting? = nil,
        hotKey: MacHotKeyRegistering = MacGlobalHotKey(),
        activateApp: @escaping @MainActor () -> Void = {
            if NSApp.isHidden {
                NSApp.unhide(nil)
            }
            NSApp.activate()
        }
    ) {
        let searchModel = MacQuickSearchViewModel(
            sessionProvider: sessionProvider,
            authenticateDeviceOwner: {
                // LocalAuthentication only prompts for the active app, and the
                // panel does not activate KeeForge on its own.
                NSApp.activate()
                return await MacQuickSearchViewModel.deviceOwnerGate()
            }
        )
        self.searchModel = searchModel
        self.presenter = presenter ?? MacQuickSearchPanel(searchModel: searchModel)
        self.hotKey = hotKey
        self.activateApp = activateApp
        isMenuBarItemEnabled = SettingsService.macMenuBarQuickAccessEnabled
        shortcut = SettingsService.macQuickSearchShortcut
    }

    func start() {
        guard isStarted == false else { return }
        isStarted = true

        presenter.onToggleRequested = { [weak self] in self?.togglePanel() }
        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        searchModel.onCopied = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: true)
        }
        searchModel.onDismiss = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: true)
        }
        searchModel.onShowMainWindow = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: false)
            self?.showMainWindow()
        }
        apply()
    }

    func togglePanel() {
        guard isMenuBarItemEnabled else { return }
        if presenter.isPanelVisible {
            presenter.hidePanel(restoringPreviousApp: true)
        } else {
            searchModel.prepareForPresentation()
            presenter.showPanel()
        }
    }

    private func apply() {
        guard isStarted else { return }

        presenter.setStatusItemVisible(isMenuBarItemEnabled)
        if isMenuBarItemEnabled == false {
            presenter.hidePanel(restoringPreviousApp: false)
        }

        guard isMenuBarItemEnabled, isRecordingShortcut == false, let shortcut else {
            hotKey.unregister()
            isShortcutUnavailable = false
            return
        }
        isShortcutUnavailable = hotKey.register(shortcut) == false
    }

    /// Fronts the existing main window, or opens one after ⌘W closed it (which
    /// also locked the database, so the window lands on the unlock screen).
    private func showMainWindow() {
        activateApp()
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// Reports the window it is placed in, so the controller can front the main
/// window instead of opening a second one.
struct MacWindowReader: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        ReportingView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        private let onWindowChange: @MainActor (NSWindow?) -> Void

        init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }
    }
}

/// The status item and the borderless, non-activating panel it opens.
///
/// Non-activating so a search started from another app leaves that app
/// frontmost: the panel takes the keyboard, and closing it hands nothing back
/// because nothing was taken. Only the password copy activates KeeForge, for
/// its authentication prompt, and the app the user came from is re-activated
/// once the copy lands.
@MainActor
final class MacQuickSearchPanel: NSObject, MacQuickSearchPanelPresenting {
    static let panelSize = NSSize(width: 380, height: 420)

    var onToggleRequested: (() -> Void)?

    private let searchModel: MacQuickSearchViewModel
    private var statusItem: NSStatusItem?
    private var panel: QuickSearchPanelWindow?
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    /// A click on the status item arrives after the panel has already lost key
    /// to it; without this the click would reopen the panel it just closed.
    private var lastResignedKeyAt: Date?

    init(searchModel: MacQuickSearchViewModel) {
        self.searchModel = searchModel
    }

    var isPanelVisible: Bool {
        panel?.isVisible == true
    }

    func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: String(localized: "KeeForge Quick Search"))
                image?.isTemplate = true
                button.image = image
                button.toolTip = String(localized: "KeeForge Quick Search")
                button.target = self
                button.action = #selector(statusItemClicked)
                button.setAccessibilityIdentifier("menu-bar.quick-search.status-item")
            }
            statusItem = item
        } else if visible == false, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost

        // A hidden app's windows stay hidden, the panel included.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        // Set here rather than left to `ScreenProtectionService`, whose sweep
        // keys off `NSApp.keyWindow`, which a non-activating panel need not be.
        panel.sharingType = ScreenProtectionService.windowSharingType(blockCapture: SettingsService.blockScreenCapture)
        panel.setFrameOrigin(panelOrigin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        installKeyMonitor()
    }

    func hidePanel(restoringPreviousApp: Bool) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
        statusItem?.button?.highlight(false)
        removeKeyMonitor()
        searchModel.query = ""

        guard restoringPreviousApp else { return }
        if let previousApp, previousApp.isTerminated == false {
            previousApp.activate()
        }
        previousApp = nil
    }

    @objc private func statusItemClicked() {
        if isPanelVisible == false, let lastResignedKeyAt, Date().timeIntervalSince(lastResignedKeyAt) < 0.3 {
            return
        }
        onToggleRequested?()
    }

    private func makePanel() -> QuickSearchPanelWindow {
        let panel = QuickSearchPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: MacQuickSearchView(model: searchModel))
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPanelVisible else { return }
                self.lastResignedKeyAt = Date()
                // Keeps `previousApp`: a password copy whose prompt took the
                // key status still hands focus back once it lands.
                self.hidePanel(restoringPreviousApp: false)
            }
        }
        return panel
    }

    private func panelOrigin(for size: NSSize) -> NSPoint {
        let anchor: NSRect?
        let screen: NSScreen?
        if let button = statusItem?.button, let buttonWindow = button.window {
            anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            screen = buttonWindow.screen
        } else {
            anchor = nil
            screen = NSScreen.main
        }
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let gap: CGFloat = 4
        let preferredX = (anchor?.midX ?? visible.midX) - size.width / 2
        let x = min(max(preferredX, visible.minX + gap), visible.maxX - size.width - gap)
        let y = (anchor?.minY ?? visible.maxY) - size.height - gap
        return NSPoint(x: x, y: max(y, visible.minY + gap))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `NSEvent` is not `Sendable`, so it is read before the hop.
            let windowNumber = event.windowNumber
            guard let command = Self.command(for: event) else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.windowNumber == windowNumber else { return false }
                self.searchModel.perform(command)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Arrow keys move the selection, Return copies (the password, or the user
    /// name when there is none), ⌘Return opens the entry in KeeForge, Escape
    /// closes, and the main window's ⇧⌘B / ⇧⌘C / ⇧⌘T copy one field.
    nonisolated static func command(for event: NSEvent) -> MacQuickSearchViewModel.Command? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_UpArrow where flags.isEmpty:
            return .moveUp
        case kVK_DownArrow where flags.isEmpty:
            return .moveDown
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags == .command { return .openInKeeForge }
            return flags.isEmpty ? .primaryAction : nil
        case kVK_Escape:
            return .dismiss
        default:
            break
        }
        guard flags == [.command, .shift] else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": return .copy(.username)
        case "c": return .copy(.password)
        case "t": return .copy(.verificationCode)
        default: return nil
        }
    }
}

private final class QuickSearchPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
