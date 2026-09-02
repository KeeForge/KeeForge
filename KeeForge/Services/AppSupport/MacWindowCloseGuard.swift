#if os(macOS)
import AppKit
import Foundation

/// The vault side of a window close. `DatabaseViewModel` is the only real
/// conformer; tests substitute a fake so the guard can be driven without a
/// session.
@MainActor
protocol MacWindowCloseVault: AnyObject {
    var isReadOnly: Bool { get }
    var onWindowCloseGranted: (() -> Void)? { get set }
    func requestWindowClose() -> DatabaseViewModel.WindowCloseDecision
    func saveAndCloseWindow() async
    func discardAndCloseWindow()
    func cancelWindowClose()
}

extension DatabaseViewModel: MacWindowCloseVault {}

/// Holds a window close open until the vault behind it has answered for its
/// unsaved work.
///
/// `MacLockMonitor` locks on `NSWindow.willCloseNotification`, which arrives
/// once the close is already committed. That is late enough for a lock that
/// takes effect immediately, and too late for the two states that defer one
/// instead: an editor holding fields the draft has not seen, and a draft whose
/// write already failed. Both prompts live in views that go away with the
/// window, so ⌘W used to leave the vault decrypted in memory with nothing on
/// screen to resolve it and no timer that would ever fire.
///
/// This guard is the seam that runs *before* the close commits. It answers
/// `windowShouldClose(_:)` for the close that would leave no window behind,
/// and:
/// - lets it through when nothing is unsaved;
/// - hands an open editor its own prompt, because only the editor can save the
///   fields it is holding, and closes the window once that resolves into a lock;
/// - asks the standard Save / Don't Save / Cancel itself for a dirty draft,
///   whose save it can drive.
///
/// Cancel leaves the window open and the session exactly as it was.
///
/// The prompt, the counter and the close itself are injected so tests can drive
/// the whole decision without real windows or a modal alert.
@MainActor
final class MacWindowCloseGuard {
    enum Choice: Equatable {
        case save
        case discard
        case cancel
    }

    /// The session the window is showing, if any.
    typealias VaultProvider = @MainActor () -> MacWindowCloseVault?
    /// `offersSave` is false on a read-only database, where saving is not a
    /// legal operation.
    typealias UnsavedWorkPrompt = @MainActor (_ window: NSWindow?, _ offersSave: Bool) async -> Choice
    typealias WindowCloser = @MainActor (NSWindow?) -> Void

    var vaultProvider: VaultProvider?

    private let prompt: UnsavedWorkPrompt
    private let closeWindow: WindowCloser
    private let remainingWindowCounter: MacLockMonitor.RemainingWindowCounter
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// One proxy per adopted window, held here because `NSWindow.delegate` is
    /// weak.
    private var proxies: [ObjectIdentifier: WindowCloseDelegateProxy] = [:]

    init(
        prompt: @escaping UnsavedWorkPrompt = MacWindowCloseGuard.presentUnsavedWorkAlert,
        closeWindow: @escaping WindowCloser = { $0?.close() },
        remainingWindowCounter: @escaping MacLockMonitor.RemainingWindowCounter
            = MacLockMonitor.countRemainingHostWindows,
        notificationCenter: NotificationCenter = .default
    ) {
        self.prompt = prompt
        self.closeWindow = closeWindow
        self.remainingWindowCounter = remainingWindowCounter
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard observers.isEmpty else { return }

        // A window that has just become key or main is one the app is using,
        // and re-adopting is cheap, so this also recovers if SwiftUI installs a
        // fresh delegate of its own later in a window's life.
        observeWindows(NSWindow.didBecomeKeyNotification) { $0.adopt($1) }
        observeWindows(NSWindow.didBecomeMainNotification) { $0.adopt($1) }
        observeWindows(NSWindow.willCloseNotification) { $0.forget($1) }

        for window in NSApplication.shared.windows {
            adopt(window)
        }
    }

    /// Restores the delegates the app had before. The app keeps one guard alive
    /// for its whole lifetime; tests must call this in teardown.
    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        for (_, proxy) in proxies {
            proxy.restoreDelegate()
        }
        proxies.removeAll()
    }

    /// Exposed for tests, which cannot close a real window.
    func windowShouldClose(_ window: NSWindow?) -> Bool {
        // Only the close that leaves the app with no window to lock from is a
        // lock trigger, so only that one has to be answered for. Closing the
        // Settings window while the vault's window stays open is not one.
        guard remainingWindowCounter(window) == 0 else { return true }
        guard let vault = vaultProvider?() else { return true }

        switch vault.requestWindowClose() {
        case .close:
            return true
        case .waitForEditorPrompt:
            // The editor is showing its own Save / Discard / Keep Editing
            // prompt; the close rides on whatever that resolves into.
            waitForGrant(from: vault, closing: window)
        case .promptForUnsavedDraft:
            waitForGrant(from: vault, closing: window)
            Task { await self.resolveUnsavedDraft(for: vault, window: window) }
        }

        return false
    }

    /// The standard AppKit unsaved-work choice, as a sheet on the window that
    /// is trying to close.
    static func presentUnsavedWorkAlert(_ window: NSWindow?, offersSave: Bool) async -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = offersSave
            ? String(localized: "Save your changes before closing?")
            : String(localized: "Discard changes?")
        alert.informativeText = String(
            localized: "Your changes haven’t been saved to this database yet. Closing this window locks the database and discards them."
        )

        // Added right to left, so this reads Don't Save · Cancel · Save.
        var choices: [Choice] = []
        if offersSave {
            alert.addButton(withTitle: String(localized: "Save"))
            choices.append(.save)
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        choices.append(.cancel)
        let discardButton = alert.addButton(withTitle: String(localized: "Don’t Save"))
        discardButton.keyEquivalent = "d"
        discardButton.keyEquivalentModifierMask = .command
        choices.append(.discard)

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return .cancel }
        return choices[index]
    }

    private func waitForGrant(from vault: MacWindowCloseVault, closing window: NSWindow?) {
        vault.onWindowCloseGranted = { [weak self, weak vault, weak window] in
            vault?.onWindowCloseGranted = nil
            self?.closeWindow(window)
        }
    }

    private func resolveUnsavedDraft(for vault: MacWindowCloseVault, window: NSWindow?) async {
        switch await prompt(window, vault.isReadOnly == false) {
        case .save:
            // A retry that fails again re-defers to the workspace prompt with
            // the close still waiting on it.
            await vault.saveAndCloseWindow()
        case .discard:
            vault.discardAndCloseWindow()
        case .cancel:
            vault.onWindowCloseGranted = nil
            vault.cancelWindowClose()
        }
    }

    private func adopt(_ window: NSWindow?) {
        // Deliberately not filtered down to windows that could host the app's
        // UI: which close matters is decided by the window counter at close
        // time, and adopting one window too many costs a proxy that always
        // answers true. Sheets are skipped only because they cannot be the
        // last window standing.
        guard let window, window.isSheet == false else { return }

        let key = ObjectIdentifier(window)
        if let existing = proxies[key], window.delegate === existing { return }

        let replaced = (window.delegate as? WindowCloseDelegateProxy)?.forwardingDelegate ?? window.delegate
        let proxy = WindowCloseDelegateProxy(window: window, forwardingDelegate: replaced) { [weak self] closing in
            self?.windowShouldClose(closing) ?? true
        }
        proxies[key] = proxy
        window.delegate = proxy
    }

    private func forget(_ window: NSWindow?) {
        guard let window, let proxy = proxies.removeValue(forKey: ObjectIdentifier(window)) else { return }
        proxy.restoreDelegate()
    }

    private func observeWindows(
        _ name: Notification.Name,
        handler: @escaping @MainActor (MacWindowCloseGuard, NSWindow?) -> Void
    ) {
        // `Notification` is not `Sendable` and the posting object is what this
        // needs, so the window is read on the posting thread — always the main
        // thread for a window notification.
        let token = notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            guard Thread.isMainThread else { return }
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, window)
            }
        }
        observers.append(token)
    }
}

/// Stands in as a window's delegate so the guard can answer
/// `windowShouldClose(_:)`, and forwards everything else to the delegate
/// SwiftUI installed — which it also keeps alive, since `NSWindow.delegate` is
/// weak and nothing else may be holding it.
private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    let forwardingDelegate: NSWindowDelegate?

    private weak var window: NSWindow?
    private let shouldClose: @MainActor (NSWindow) -> Bool

    init(window: NSWindow, forwardingDelegate: NSWindowDelegate?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        self.window = window
        self.forwardingDelegate = forwardingDelegate
        self.shouldClose = shouldClose
    }

    @MainActor
    func restoreDelegate() {
        guard let window, window.delegate === self else { return }
        window.delegate = forwardingDelegate
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardingDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardingDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            let forwarded = forwardingDelegate?.windowShouldClose?(sender) ?? true
            guard forwarded else { return false }
            return shouldClose(sender)
        }
    }
}
#endif
