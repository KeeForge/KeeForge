import AppKit

/// The bridge state the prompts read and answer; `MacBrowserBridgeController` in the app.
@MainActor
protocol MacBrowserPairingSource: AnyObject {
    var pendingPairing: MacBrowserBridgeController.PendingPairing? { get }
    var pairingFailed: Bool { get }
    func answerPairing(id: UUID, allow: Bool)
    func clearPairingFailure()
}

extension MacBrowserBridgeController: MacBrowserPairingSource {}

/// What the pairing alert shows. The browser name comes from the browser, so it is only ever plain text.
struct MacBrowserPairingAlertContent: Equatable {
    let title: String
    let code: String
    let codeAccessibilityLabel: String
    let message: String

    init(browserName: String, code: String) {
        title = String(localized: "Pair with “\(BrowserPairingStore.displayName(browserName))”?")
        self.code = Self.groupedCode(code)
        // Digits read one by one, not as a number.
        codeAccessibilityLabel = code.map(String.init).joined(separator: " ")
        message = String(localized: "Allow only if your browser shows the same code. A paired browser can see the titles and user names of logins for the sites it asks about, and can fill a password after you confirm.")
    }

    static func groupedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

enum MacBrowserBridgeWindowState: Equatable {
    case closed
    case locked
    case unlocked
    /// Unlocked with unsaved fields open; moving the selection would hide them.
    case editing
}

/// The AppKit side of the prompts; tests record these calls instead.
@MainActor
protocol MacBrowserBridgeShell: AnyObject {
    func activate()
    /// Activation is cooperative and can be refused while the user is in another app.
    var isActive: Bool { get }
    func requestAttention()
    func windowState(of databaseID: UUID) -> MacBrowserBridgeWindowState
    func showDatabaseWindow(_ databaseID: UUID)
    func showDatabasesWindow()
    func revealEntry(_ entryID: UUID, in databaseID: UUID)
    /// `answer` gets true for Allow and false for Don't Allow; a dismissed alert never calls it.
    func showPairing(_ content: MacBrowserPairingAlertContent, answer: @escaping @MainActor (Bool) -> Void)
    func dismissPairing()
    func showPairingFailure()
}

/// Shows the bridge's pairing alert and failure, and fronts windows for its
/// reveal and unlock requests. Nothing here unlocks a database or reveals a secret.
@MainActor
final class MacBrowserBridgePrompts {
    private let source: MacBrowserPairingSource
    private let shell: MacBrowserBridgeShell
    private let observation = MacObservation()
    private var shownPairingID: UUID?

    init(source: MacBrowserPairingSource, shell: MacBrowserBridgeShell) {
        self.source = source
        self.shell = shell
        observation.start(reading: { [weak source] in (source?.pendingPairing, source?.pairingFailed ?? false) },
                          onChange: { [weak self] in self?.reconcile(pending: $0.0, failed: $0.1) })
    }

    func reveal(entryID: UUID, databaseID: UUID) {
        front()
        switch shell.windowState(of: databaseID) {
        case .closed:
            shell.showDatabasesWindow()
        case .locked, .editing:
            shell.showDatabaseWindow(databaseID)
        case .unlocked:
            shell.showDatabaseWindow(databaseID)
            shell.revealEntry(entryID, in: databaseID)
        }
    }

    func unlock(databaseID: UUID?) {
        front()
        if let databaseID, shell.windowState(of: databaseID) != .closed {
            shell.showDatabaseWindow(databaseID)
        } else {
            shell.showDatabasesWindow()
        }
    }

    private func reconcile(pending: MacBrowserBridgeController.PendingPairing?, failed: Bool) {
        if let shown = shownPairingID, shown != pending?.id {
            shownPairingID = nil
            shell.dismissPairing()
        }
        if let pending, shownPairingID == nil {
            let id = pending.id
            shownPairingID = id
            front()
            shell.showPairing(MacBrowserPairingAlertContent(browserName: pending.browserName, code: pending.code)) { [weak self] allow in
                self?.answer(id, allow: allow)
            }
        }
        if failed {
            front()
            shell.showPairingFailure()
            source.clearPairingFailure()
        }
    }

    private func front() {
        shell.activate()
        if !shell.isActive { shell.requestAttention() }
    }

    private func answer(_ id: UUID, allow: Bool) {
        guard shownPairingID == id, source.pendingPairing?.id == id else { return }
        shownPairingID = nil
        source.answerPairing(id: id, allow: allow)
    }
}

/// The pairing and failure alerts as sheets on the Databases window, which
/// exists whether or not any database window is open and is never locked.
@MainActor
final class MacBrowserBridgeWindowShell: MacBrowserBridgeShell {
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    private let coordinator: MacWindowCoordinator
    private let present: MacAlertQueue.Present
    private let schedule: Schedule
    private var alerts: (queue: MacAlertQueue, window: NSWindow)?
    private var pairingAlert: NSAlert?

    init(coordinator: MacWindowCoordinator,
         present: @escaping MacAlertQueue.Present = MacWorkspaceAlerts.presentAsSheet,
         schedule: @escaping Schedule = { delay, work in
             Task { @MainActor in
                 try? await Task.sleep(for: delay)
                 work()
             }
         }) {
        self.coordinator = coordinator
        self.present = present
        self.schedule = schedule
    }

    func activate() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
    }

    var isActive: Bool { NSApp.isActive }

    func requestAttention() {
        NSApp.requestUserAttention(.criticalRequest)
    }

    func windowState(of databaseID: UUID) -> MacBrowserBridgeWindowState {
        guard let session = coordinator.databaseWindows[databaseID]?.session else { return .closed }
        guard session.state == .unlocked, !session.isLockPending else { return .locked }
        return session.hasUnsavedEditor ? .editing : .unlocked
    }

    /// A browser's request is not the user turning to a restored window, so it keeps its automatic unlock held back.
    func showDatabaseWindow(_ databaseID: UUID) {
        if !coordinator.showDatabaseWindow(databaseID, deliberate: false) { coordinator.showDatabasesWindow() }
    }

    func showDatabasesWindow() {
        coordinator.showDatabasesWindow()
    }

    func revealEntry(_ entryID: UUID, in databaseID: UUID) {
        guard windowState(of: databaseID) == .unlocked else { return }
        coordinator.databaseWindows[databaseID]?.session.revealEntry(entryID)
    }

    func showPairing(_ content: MacBrowserPairingAlertContent, answer: @escaping @MainActor (Bool) -> Void) {
        guard let queue = alertQueue() else { return }
        let alert = MacBrowserPairingAlert.make(content)
        pairingAlert = alert
        queue.enqueue(alert) { [weak self] response in
            if self?.pairingAlert === alert { self?.pairingAlert = nil }
            guard let allow = MacBrowserPairingAlert.allows(response) else { return }
            // Allow cannot be clicked before it is armed; anything claiming so refuses.
            answer(allow && MacBrowserPairingAlert.isArmed(alert))
        }
    }

    func dismissPairing() {
        guard let alert = pairingAlert else { return }
        pairingAlert = nil
        alerts?.queue.cancel(alert)
    }

    func showPairingFailure() {
        alertQueue()?.enqueue(MacBrowserPairingAlert.makeFailure()) { _ in }
    }

    private func alertQueue() -> MacAlertQueue? {
        coordinator.showDatabasesWindow()
        guard let window = coordinator.databasesWindow else { return nil }
        if let alerts, alerts.window === window { return alerts.queue }
        let queue = MacAlertQueue(window: window) { [weak self] alert, parent, completion in
            guard let self else { return }
            present(alert, parent, completion)
            if alert === pairingAlert { didPresentPairing(alert) }
        }
        alerts = (queue, window)
        return queue
    }

    /// The armed delay starts when the alert is on screen, which may be after a queued alert.
    private func didPresentPairing(_ alert: NSAlert) {
        MacBrowserPairingAlert.focusRefusal(in: alert)
        schedule(MacBrowserPairingAlert.allowDelay) { [weak self, weak alert] in
            guard let alert, self?.pairingAlert === alert else { return }
            MacBrowserPairingAlert.arm(alert)
        }
    }
}

@MainActor
enum MacBrowserPairingAlert {
    /// Allow stays disabled this long after the alert appears, so a click or key aimed at what was there misses it.
    static let allowDelay: Duration = .milliseconds(1500)

    /// Don't Allow is first so it holds Return; Escape clicks it too. Allow has no key, starts
    /// disabled, and refuses keyboard focus, so Space with Full Keyboard Access cannot allow.
    static func make(_ content: MacBrowserPairingAlertContent) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        let code = NSTextField(labelWithString: content.code)
        code.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
        code.alignment = .center
        code.setAccessibilityLabel(content.codeAccessibilityLabel)
        code.setAccessibilityIdentifier("browser-pairing.code")
        code.sizeToFit()
        code.frame.size.width = max(code.frame.width, 220)
        alert.accessoryView = code
        let refuse = alert.addButton(withTitle: String(localized: "Don’t Allow"))
        refuse.keyEquivalent = "\r"
        refuse.setAccessibilityIdentifier("browser-pairing.refuse")
        let allow = alert.addButton(withTitle: String(localized: "Allow"))
        allow.keyEquivalent = ""
        allow.setAccessibilityIdentifier("browser-pairing.allow")
        allow.isEnabled = false
        allow.refusesFirstResponder = true
        alert.window.initialFirstResponder = refuse
        MacAlertEscapeKey.install(in: alert, clicking: refuse)
        return alert
    }

    /// NSAlert lays out and picks a first responder when it is shown; this runs after that.
    static func focusRefusal(in alert: NSAlert) {
        guard let refuse = alert.buttons.first else { return }
        alert.window.initialFirstResponder = refuse
        if !alert.window.makeFirstResponder(refuse), alert.window.firstResponder === alert.buttons.last {
            alert.window.makeFirstResponder(nil)
        }
    }

    static func arm(_ alert: NSAlert) {
        guard let allow = alert.buttons.last else { return }
        allow.isEnabled = true
        allow.refusesFirstResponder = false
    }

    static func isArmed(_ alert: NSAlert) -> Bool {
        alert.buttons.count == 2 && alert.buttons[1].isEnabled
    }

    /// Nil for an alert ended without a click.
    static func allows(_ response: NSApplication.ModalResponse) -> Bool? {
        switch response {
        case .alertFirstButtonReturn: false
        case .alertSecondButtonReturn: true
        default: nil
        }
    }

    static func makeFailure() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t save the pairing. Try again from the browser.")
        alert.addButton(withTitle: String(localized: "OK"))
        return alert
    }
}
