import AppKit

/// One window's alerts, shown one at a time. An alert raised while another is
/// up or still detaching waits its turn instead of being dropped, and an answer
/// runs only once its sheet has detached, so a follow-up sheet can attach.
@MainActor
final class MacAlertQueue {
    typealias Present = @MainActor (NSAlert, NSWindow?, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void
    private struct Request {
        let alert: NSAlert
        let completion: @MainActor (NSApplication.ModalResponse) -> Void
    }

    /// Shows the alert and reports the button; tests answer without showing anything.
    var present: Present
    private weak var window: NSWindow?
    private var requests: [Request] = []
    private var active: Request?
    private var answer: NSApplication.ModalResponse?
    /// An alert ended without an answer, until AppKit detaches it.
    private var detaching: NSWindow?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, present: @escaping Present = MacWorkspaceAlerts.presentAsSheet) {
        self.window = window
        self.present = present
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drain() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        end()
    }

    /// The shown alert, if any.
    var presentedAlert: NSAlert? { active?.alert }
    var queuedCount: Int { requests.count }

    func enqueue(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        requests.append(Request(alert: alert, completion: completion))
        drain()
    }

    /// Withdraws one alert, shown or waiting, without an answer.
    func cancel(_ alert: NSAlert) {
        requests.removeAll { $0.alert === alert }
        guard active?.alert === alert else { return }
        active = nil
        answer = nil
        dismiss(alert)
        drain()
    }

    private func drain() {
        if let active {
            guard let answer, active.alert.window.sheetParent == nil else { return }
            self.active = nil
            self.answer = nil
            active.completion(answer)
        }
        if let detaching, detaching.sheetParent != nil { return }
        detaching = nil
        guard active == nil, !requests.isEmpty, let window else { return }
        let request = requests.removeFirst()
        active = request
        let token = generation
        present(request.alert, MacWorkspaceAlerts.topmostSheet(of: window)) { [weak self] response in
            guard let self, token == generation, active?.alert === request.alert else { return }
            answer = response
            drain()
        }
    }

    /// Ends the shown alert unanswered and drops the queue; late answers do nothing.
    func end() {
        generation = UUID()
        requests.removeAll()
        answer = nil
        if let alert = active?.alert { dismiss(alert) }
        active = nil
    }

    private func dismiss(_ alert: NSAlert) {
        let sheet = alert.window
        guard let parent = sheet.sheetParent else { return }
        detaching = sheet
        parent.endSheet(sheet, returnCode: .cancel)
    }
}
