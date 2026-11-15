import AppKit
import Observation
import SwiftUI

/// The app's one Large Type panel: a borderless key panel centred over a database window, showing
/// a password one numbered tile per character. It is given the plaintext only after the reveal
/// gate (`DatabaseCommands.showEntryPasswordInLargeType`) and holds it only while open. Any key,
/// click, Escape or loss of key status closes it, and so do lock, a content change, another
/// selection, its window closing and the app resigning active. Opening another replaces it.
@MainActor @Observable
final class MacLargeTypePanelController {
    static let shared = MacLargeTypePanelController()

    struct Origin: Equatable {
        let entryID: UUID
        let session: ObjectIdentifier
    }

    private struct Stamp: Equatable {
        let isUnlocked: Bool
        let lockCycleID: Int
        let contentRevision: Int
        let commandEntryID: UUID?
    }

    /// What the open panel shows; nil once it closes.
    private(set) var model: LargeTypeModel?
    private(set) var origin: Origin?
    @ObservationIgnored private(set) var panel: MacLargeTypePanel?

    @ObservationIgnored private let blockCapture: @MainActor () -> Bool
    @ObservationIgnored private let present: @MainActor (NSPanel) -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let windowLookup: @MainActor (DatabaseViewModel) -> NSWindow?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let observation = MacObservation()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastClosed: (origin: Origin, at: Date)?

    /// Tests pass a `present` that never orders the panel front.
    init(
        blockCapture: @escaping @MainActor () -> Bool = { SettingsService.blockScreenCapture },
        present: @escaping @MainActor (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
        notificationCenter: NotificationCenter = .default,
        windowLookup: @escaping @MainActor (DatabaseViewModel) -> NSWindow? = MacLargeTypePanelController.window(showing:),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        self.blockCapture = blockCapture
        self.present = present
        self.notificationCenter = notificationCenter
        self.windowLookup = windowLookup
    }

    func isShowing(entryID: UUID, in session: DatabaseViewModel) -> Bool {
        origin == Origin(entryID: entryID, session: ObjectIdentifier(session))
    }

    /// The click on the pressed button closed the panel as it took key status; it must not reopen it.
    func closedJustNow(entryID: UUID, in session: DatabaseViewModel) -> Bool {
        guard let lastClosed, lastClosed.origin == Origin(entryID: entryID, session: ObjectIdentifier(session)) else {
            return false
        }
        return now().timeIntervalSince(lastClosed.at) < 0.5
    }

    /// Call only from a disclosure's `disclose` closure. `window` defaults to the session's own.
    func showPassword(_ password: String, ofEntry entryID: UUID, in session: DatabaseViewModel, over window: NSWindow? = nil) {
        guard let entry = session.entry(withID: entryID) else { return }
        let title = entry.title.isEmpty ? String(localized: "(untitled)") : entry.title
        show(LargeTypeModel(title: title, fieldName: String(localized: "Password"), value: password),
             ofEntry: entryID, in: session, over: window)
    }

    func show(_ model: LargeTypeModel, ofEntry entryID: UUID, in session: DatabaseViewModel, over window: NSWindow? = nil) {
        close()
        guard let window = window ?? windowLookup(session), session.state == .unlocked,
              session.workspace.commandEntryID == entryID else { return }
        let stamp = Self.stamp(of: session)
        let panel = makePanel(model: model, over: window)
        self.model = model
        origin = Origin(entryID: entryID, session: ObjectIdentifier(session))
        self.panel = panel
        observe(session: session, stamp: stamp, window: window)
        present(panel)
    }

    /// Drops the panel and the plaintext it showed.
    func close() {
        observation.cancel()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers = []
        if let panel {
            panel.onDismiss = nil
            panel.orderOut(nil)
            panel.contentView = nil
        }
        if let origin { lastClosed = (origin, now()) }
        panel = nil
        model = nil
        origin = nil
    }

    /// The database window showing `session`, if it has one.
    static func window(showing session: DatabaseViewModel) -> NSWindow? {
        NSApp.windows.first { ($0.windowController as? DatabaseWindowController)?.session === session }
    }

    // MARK: - Layout

    static let columnCount = 10
    static let tileSize = NSSize(width: 60, height: 86)
    static let tileSpacing: CGFloat = 8
    static let minimumWidth: CGFloat = 360
    /// Header and legend with the board's padding (16 top, 18 bottom, 20 at the sides).
    static let chromeHeight: CGFloat = 16 + 22 + 12 + 14 + 14 + 18
    static let horizontalPadding: CGFloat = 20

    /// Up to ten tiles a row; taller content scrolls inside `maximumHeight`.
    static func contentSize(tileCount: Int, maximumHeight: CGFloat) -> NSSize {
        let columns = max(1, min(columnCount, tileCount))
        let rows = max(1, (tileCount + columnCount - 1) / columnCount)
        let width = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * tileSpacing + horizontalPadding * 2
        let height = chromeHeight + CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * tileSpacing
        return NSSize(width: max(minimumWidth, width), height: min(height, maximumHeight))
    }

    /// Centred over `window`, kept on its screen.
    static func frame(for size: NSSize, over window: NSWindow) -> NSRect {
        let parent = window.frame
        var origin = NSPoint(x: parent.midX - size.width / 2, y: parent.midY - size.height / 2)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }

    // MARK: - Private

    private func makePanel(model: LargeTypeModel, over window: NSWindow) -> MacLargeTypePanel {
        let maximumHeight = (window.screen ?? NSScreen.main).map { $0.visibleFrame.height - 80 } ?? 800
        let size = Self.contentSize(tileCount: model.characterCount, maximumHeight: maximumHeight)
        let panel = MacLargeTypePanel(contentRect: Self.frame(for: size, over: window),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
        // Set before it is first shown: the capture sweep runs only when a window becomes key.
        panel.sharingType = ScreenProtectionService.windowSharingType(blockCapture: blockCapture())
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityIdentifier("large-type.panel")
        panel.setAccessibilityLabel("\(model.title) · \(model.fieldName)")
        let hosting = NSHostingView(rootView: MacLargeTypeView(model: model) { [weak self] in self?.close() }
            .modifier(MacHostingAppearance()))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onDismiss = { [weak self] in self?.close() }
        return panel
    }

    private static func stamp(of session: DatabaseViewModel) -> Stamp {
        Stamp(isUnlocked: session.state == .unlocked, lockCycleID: session.lockCycleID,
              contentRevision: session.contentRevision, commandEntryID: session.workspace.commandEntryID)
    }

    private func observe(session: DatabaseViewModel, stamp: Stamp, window: NSWindow) {
        observation.start(reading: { [weak session] in
            session.map(Self.stamp(of:))
        }, onChange: { [weak self] current in
            if current != stamp { self?.close() }
        })
        observers = [
            notificationCenter.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            notificationCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }
}

/// Borderless, yet key so it receives the keys that close it. Every key, key equivalent and mouse
/// press closes it before anything inside handles it; so does losing key status.
final class MacLargeTypePanel: NSPanel {
    var onDismiss: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            dismiss()
        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        dismiss()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    private func dismiss() {
        let dismiss = onDismiss
        onDismiss = nil
        withExtendedLifetime(self) { dismiss?() }
    }
}
