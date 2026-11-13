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

/// Holds a database window's close open until the session behind it has
/// answered for its unsaved work, then locks that session once the close
/// commits.
///
/// Two states defer a lock instead of taking it: an editor holding fields the
/// draft has not seen, and a draft whose write already failed. Both prompts
/// live in views that go away with the window, so a close that committed first
/// would leave the vault decrypted with nothing on screen to resolve it.
///
/// For each window registered in `MacDatabaseWindowRegistry` the guard answers
/// `windowShouldClose(_:)` from that window's own session, and:
/// - lets it through when nothing is unsaved;
/// - hands an open editor its own prompt, because only the editor can save the
///   fields it is holding, and closes the window once that resolves into a lock;
/// - asks the standard Save / Don't Save / Cancel itself for a dirty draft,
///   whose save it can drive.
///
/// Cancel leaves the window open and the session exactly as it was. Other
/// windows and their sessions are never consulted or locked.
///
/// The prompt, the session lookup and the close itself are injected so tests
/// can drive the whole decision without showing windows or a modal alert.
@MainActor
final class MacWindowCloseGuard {
    enum Choice: Equatable {
        case save
        case discard
        case cancel
    }

    /// The session the window is showing, if any.
    typealias VaultProvider = @MainActor (NSWindow?) -> MacWindowCloseVault?
    /// `offersSave` is false on a read-only database, where saving is not a
    /// legal operation.
    typealias UnsavedWorkPrompt = @MainActor (_ window: NSWindow?, _ offersSave: Bool) async -> Choice
    typealias WindowCloser = @MainActor (NSWindow?) -> Void

    private let registry: MacDatabaseWindowRegistry
    private let vaultProvider: VaultProvider

    private let prompt: UnsavedWorkPrompt
    private let closeWindow: WindowCloser
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    /// One proxy per adopted window, held here because `NSWindow.delegate` is
    /// weak.
    private var proxies: [ObjectIdentifier: WindowCloseDelegateProxy] = [:]

    init(
        registry: MacDatabaseWindowRegistry,
        vaultProvider: VaultProvider? = nil,
        prompt: @escaping UnsavedWorkPrompt = MacWindowCloseGuard.presentUnsavedWorkAlert,
        closeWindow: @escaping WindowCloser = { $0?.close() },
        notificationCenter: NotificationCenter = .default
    ) {
        self.prompt = prompt
        self.closeWindow = closeWindow
        self.registry = registry
        self.vaultProvider = vaultProvider ?? { [weak registry] in registry?.session(for: $0) }
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard observers.isEmpty else { return }
        registry.onRegister = { [weak self] in self?.adopt($0) }

        // A window that has just become key or main is one the app is using,
        // and re-adopting is cheap, so this also recovers if SwiftUI installs a
        // fresh delegate of its own later in a window's life.
        observeWindows(NSWindow.didBecomeKeyNotification) { $0.adopt($1) }
        observeWindows(NSWindow.didBecomeMainNotification) { $0.adopt($1) }
        observeWindows(NSWindow.willCloseNotification) { $0.windowWillClose($1) }

        for window in registry.registeredWindows {
            adopt(window)
        }
    }

    /// Restores the delegates the app had before. The app keeps one guard alive
    /// for its whole lifetime; tests must call this in teardown.
    func stop() {
        generation += 1
        registry.onRegister = nil
        for window in registry.registeredWindows {
            registry.registration(for: window)?.onUnregister = nil
        }
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
        guard let registration = registry.registration(for: window), registration.window === window,
              let vault = vaultProvider(window) else { return true }
        guard vault.onWindowCloseGranted == nil else { return false }

        switch vault.requestWindowClose() {
        case .close:
            return true
        case .waitForEditorPrompt:
            // The editor is showing its own Save / Discard / Keep Editing
            // prompt; the close rides on whatever that resolves into.
            waitForGrant(from: vault, closing: window)
        case .promptForUnsavedDraft:
            waitForGrant(from: vault, closing: window)
            Task { await self.resolveUnsavedDraft(for: vault, window: window, registration: registration) }
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

    /// A committed close locks only this window's session; a lock that already
    /// granted the close, or a session that is not open, is left alone.
    func windowWillClose(_ window: NSWindow?) {
        guard let window, registry.registration(for: window)?.window === window else { return }
        let session = registry.session(for: window)
        registry.unregister(window)
        forget(window)
        if let session, session.state == .unlocked || session.state == .unlocking {
            session.lock()
        }
    }

    private func waitForGrant(from vault: MacWindowCloseVault, closing window: NSWindow?) {
        guard let registration = registry.registration(for: window) else { return }
        registration.onUnregister = { [weak self, weak vault, weak window] in
            if vault?.onWindowCloseGranted != nil { vault?.cancelWindowClose() }
            self?.forget(window)
        }
        let generation = generation
        vault.onWindowCloseGranted = { [weak self, weak vault, weak window, weak registration] in
            vault?.onWindowCloseGranted = nil
            guard let self, self.generation == generation, let registration, self.registry.isCurrent(registration),
                  let window, self.vaultProvider(window) === vault else { return }
            self.closeWindow(window)
        }
    }

    private func resolveUnsavedDraft(
        for vault: MacWindowCloseVault, window: NSWindow?,
        registration: MacDatabaseWindowRegistry.Registration
    ) async {
        let generation = generation
        func isCurrent() -> Bool {
            self.generation == generation && registry.isCurrent(registration) && vaultProvider(window) === vault
        }
        guard isCurrent() else { return vault.cancelWindowClose() }
        let choice = await prompt(window, vault.isReadOnly == false)
        guard isCurrent() else { return vault.cancelWindowClose() }
        switch choice {
        case .save:
            await vault.saveAndCloseWindow()
        case .discard:
            vault.discardAndCloseWindow()
        case .cancel:
            vault.onWindowCloseGranted = nil
            vault.cancelWindowClose()
        }
    }

    private func adopt(_ window: NSWindow?) {
        guard let window, registry.registration(for: window)?.window === window else { return }

        let key = ObjectIdentifier(window)
        if let existing = proxies[key], window.delegate === existing { return }

        let replaced = (window.delegate as? WindowCloseDelegateProxy)?.forwardingDelegate ?? window.delegate
        let proxy = WindowCloseDelegateProxy(window: window, forwardingDelegate: replaced) { [weak self] closing in
            self?.windowShouldClose(closing) ?? true
        }
        proxies[key] = proxy
        window.delegate = proxy
        // A pending close installed its own handler, which also forgets the window.
        if let registration = registry.registration(for: window), registration.onUnregister == nil {
            registration.onUnregister = { [weak self, weak window] in self?.forget(window) }
        }
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
