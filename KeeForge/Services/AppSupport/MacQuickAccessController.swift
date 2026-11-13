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
/// Nothing here changes a lock rule. The panel searches only the database the
/// app reports as focused and reads its session live, so every existing lock
/// trigger empties it, and a locked or closed target sends the user to
/// KeeForge to unlock or choose a database. It never searches another one.
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

    /// The database window the user last focused, set by the app. Observable
    /// rather than a `Binding` to the app's state: the panel reads it from its
    /// own view update, where a captured binding returns the value it was
    /// created with. Only the ID is held, never the session.
    var focusedDatabaseID: UUID?

    /// The open session of a database, if any; set by the app.
    @ObservationIgnored var sessionForDatabase: @MainActor (UUID) -> DatabaseViewModel? = { _ in nil }
    /// Fronts the window showing this database and reports whether one now
    /// is in front; set by the app.
    @ObservationIgnored var showDatabaseWindow: ((UUID) -> Bool)?
    /// Fronts KeeForge to choose a database, reopening its window if it was
    /// closed; set by the app.
    @ObservationIgnored var showDatabaseList: (() -> Void)?

    @ObservationIgnored private let presenter: MacQuickSearchPanelPresenting
    @ObservationIgnored private let hotKey: MacHotKeyRegistering
    @ObservationIgnored private let activateApp: @MainActor () -> Void
    @ObservationIgnored private var isStarted = false

    init(
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
            authenticateDeviceOwner: { gate in
                // LocalAuthentication only prompts for the active app, and the
                // panel does not activate KeeForge on its own.
                if gate.requiresAuthentication {
                    NSApp.activate()
                }
                return await MacQuickSearchViewModel.deviceOwnerGate(gate)
            }
        )
        self.searchModel = searchModel
        self.presenter = presenter ?? MacQuickSearchPanel(searchModel: searchModel)
        self.hotKey = hotKey
        self.activateApp = activateApp
        isMenuBarItemEnabled = SettingsService.macMenuBarQuickAccessEnabled
        shortcut = SettingsService.macQuickSearchShortcut
        searchModel.focusedDatabaseID = { [weak self] in self?.focusedDatabaseID }
        searchModel.sessionForDatabase = { [weak self] in self?.sessionForDatabase($0) }
    }

    func start() {
        guard isStarted == false else { return }
        isStarted = true

        presenter.onToggleRequested = { [weak self] in self?.togglePanel() }
        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        searchModel.onCopied = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: true)
        }
        searchModel.onCopyAborted = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: true)
        }
        searchModel.onDismiss = { [weak self] in
            self?.presenter.hidePanel(restoringPreviousApp: true)
        }
        searchModel.onShowDatabase = { [weak self] databaseID in
            guard let self else { return false }
            presenter.hidePanel(restoringPreviousApp: false)
            activateApp()
            return showDatabaseWindow?(databaseID) ?? false
        }
        searchModel.onShowDatabaseList = { [weak self] in
            guard let self else { return }
            presenter.hidePanel(restoringPreviousApp: false)
            activateApp()
            showDatabaseList?()
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
}

/// The status item and the borderless, non-activating panel it opens.
///
/// Non-activating so a search started from another app leaves that app
/// frontmost: the panel takes the keyboard, and closing it hands nothing back
/// because nothing was taken. Only the password copy activates KeeForge, for
/// its authentication prompt, and the app the user came from is re-activated
/// once the prompt ends, whether the copy landed or not.
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
        // On the window: an identifier on the SwiftUI root replaces the
        // identifier of every element inside it.
        panel.setAccessibilityIdentifier("quick-search.panel")

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
                // key status still hands focus back once the prompt ends,
                // cancelled or not.
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
                guard let self, let panel = self.panel, panel.windowNumber == windowNumber,
                      Self.isComposingText(in: panel.firstResponder) == false
                else { return false }
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

    /// Whether an input method (Chinese, Japanese, Korean, …) is composing in
    /// the search field. It confirms, picks, and cancels its candidates with
    /// Return, the arrow keys, and Escape, so while the field editor holds
    /// marked text every key stays with it and none becomes a panel command.
    static func isComposingText(in firstResponder: NSResponder?) -> Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
}

private final class QuickSearchPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
