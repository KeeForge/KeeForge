#if os(macOS)
import AppKit
import Foundation

/// Observes the system notifications that make up the macOS auto-lock
/// guarantee and forwards them to the app as lock/became-active callbacks.
///
/// macOS has no single "scene entered background" moment the way iOS does, so
/// this monitor IS the lock lifecycle on the Mac:
/// - screen lock (`com.apple.screenIsLocked`, distributed)
/// - screensaver start (`com.apple.screensaver.didstart`, distributed)
/// - system sleep (`NSWorkspace.willSleepNotification`)
/// - fast-user-switch session resign (`NSWorkspace.sessionDidResignActiveNotification`)
/// - app deactivation (`NSApplication.didResignActiveNotification`) — only
///   under the strict `SettingsService.MacLockPolicy.appDeactivates` option;
///   the default policy ignores it because it fires on every window switch.
/// - the last window closing (`NSWindow.willCloseNotification`). ⌘W closes the
///   only window without quitting, and the session lives in app-level state,
///   so without this an unlocked vault would sit decrypted in memory with no
///   window to lock it from. Like the triggers above it is unconditional.
///   Unsaved work is settled before the close commits, by
///   `MacWindowCloseGuard` — this notification arrives too late to prompt in,
///   so by the time it fires nothing is left to defer.
///
/// `NSApplication.didBecomeActiveNotification` drives the became-active
/// callback (pending-upload drain + inactivity-timer resume).
///
/// It also watches deliberate user interaction so the Auto-Lock Timeout means
/// idleness rather than "time since the selection last changed". Without this
/// the timer is only reset by view-model mutations, so typing a long note —
/// which lives in `EntryEditViewModel` and touches none of them — would trip a
/// 1- or 5-minute timeout mid-edit.
///
/// Notification centers are injected so unit tests can post notifications
/// without really locking the screen.
@MainActor
final class MacLockMonitor {
    enum Trigger: String, CaseIterable, Sendable {
        case screenLocked
        case screensaverStarted
        case systemWillSleep
        case sessionResignedActive
        case appResignedActive
        case lastWindowClosed
    }

    static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screensaverDidStartNotification = Notification.Name("com.apple.screensaver.didstart")

    typealias LockPolicyProvider = @MainActor () -> SettingsService.MacLockPolicy
    /// How many windows that could still host the app's UI remain, ignoring the
    /// one that is closing. Injected so tests can drive the trigger without
    /// real windows.
    typealias RemainingWindowCounter = @MainActor (_ excluding: NSWindow?) -> Int

    var onLockTriggered: ((Trigger) -> Void)?
    var onDidBecomeActive: (() -> Void)?
    /// Deliberate interaction with this app; resets the inactivity timer only.
    /// It can never extend a vault past a lock trigger — those lock immediately
    /// regardless of how active the user is.
    var onUserActivity: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private let lockPolicyProvider: LockPolicyProvider
    private let remainingWindowCounter: RemainingWindowCounter
    private let now: @MainActor () -> Date
    private let activityThrottle: TimeInterval
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var activityMonitor: Any?
    private var lastActivityForwardedAt: Date?

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        lockPolicyProvider: @escaping LockPolicyProvider = { SettingsService.macLockPolicy },
        remainingWindowCounter: @escaping RemainingWindowCounter = MacLockMonitor.countRemainingHostWindows,
        now: @escaping @MainActor () -> Date = { Date() },
        activityThrottle: TimeInterval = 2
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.lockPolicyProvider = lockPolicyProvider
        self.remainingWindowCounter = remainingWindowCounter
        self.now = now
        self.activityThrottle = activityThrottle
    }

    func start() {
        guard observers.isEmpty else { return }

        observe(distributedNotificationCenter, Self.screenIsLockedNotification) { monitor in
            monitor.handleLockTrigger(.screenLocked)
        }
        observe(distributedNotificationCenter, Self.screensaverDidStartNotification) { monitor in
            monitor.handleLockTrigger(.screensaverStarted)
        }
        observe(workspaceNotificationCenter, NSWorkspace.willSleepNotification) { monitor in
            monitor.handleLockTrigger(.systemWillSleep)
        }
        observe(workspaceNotificationCenter, NSWorkspace.sessionDidResignActiveNotification) { monitor in
            monitor.handleLockTrigger(.sessionResignedActive)
        }
        observe(notificationCenter, NSApplication.didResignActiveNotification) { monitor in
            monitor.handleLockTrigger(.appResignedActive)
        }
        observe(notificationCenter, NSApplication.didBecomeActiveNotification) { monitor in
            monitor.onDidBecomeActive?()
        }
        observeWindowClose()

        startActivityMonitor()
    }

    /// Deliberate interaction only: keys, clicks and scrolls. Cursor movement is
    /// excluded on purpose — a drifting or jiggled mouse is not a reason to keep
    /// a vault unlocked, and `.mouseMoved` is not even delivered unless a window
    /// opts in. A *local* monitor sees only events routed to this app, so
    /// working in another app correctly counts as idle here.
    private func startActivityMonitor() {
        guard activityMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleUserActivity()
            }
            // Never consume the event; the app still has to receive it.
            return event
        }
    }

    /// Throttled so a scroll or key-repeat burst resets the timer once rather
    /// than rescheduling it hundreds of times. Exposed for tests, which cannot
    /// synthesize real `NSEvent`s.
    func handleUserActivity() {
        let timestamp = now()
        if let lastActivityForwardedAt,
           timestamp.timeIntervalSince(lastActivityForwardedAt) < activityThrottle {
            return
        }
        lastActivityForwardedAt = timestamp
        onUserActivity?()
    }

    /// Removes all observers. The app keeps one monitor alive for its whole
    /// lifetime; tests must call this in teardown.
    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
        }
        activityMonitor = nil
        lastActivityForwardedAt = nil
    }

    /// Sheets, panels (the About panel, open/save panels) and closed-but-alive
    /// windows cannot host the app's UI, so they never keep a vault unlocked.
    /// `MacWindowCloseGuard` shares this count, so both halves of the
    /// window-close trigger agree on what a host window is.
    /// A *minimized* window does — it is one Dock click from being on screen —
    /// and so does Settings, which the user is still working in; closing that
    /// one later runs this check again.
    static func countRemainingHostWindows(excluding closingWindow: NSWindow?) -> Int {
        NSApplication.shared.windows.filter { window in
            window !== closingWindow
                && (window.isVisible || window.isMiniaturized)
                && window.canBecomeMain
                && window.isSheet == false
        }.count
    }

    /// Exposed for tests, which cannot close a real window.
    func handleWindowWillClose(_ closingWindow: NSWindow?) {
        guard remainingWindowCounter(closingWindow) == 0 else { return }
        onLockTriggered?(.lastWindowClosed)
    }

    /// Registered on its own rather than through `observe`, which drops the
    /// notification: this is the one observer that needs the posting object,
    /// and `Notification` is not `Sendable`, so the object is read on the
    /// posting thread — always the main thread for a window notification.
    private func observeWindowClose() {
        let token = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard Thread.isMainThread else { return }
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(window)
            }
        }
        observers.append((center: notificationCenter, token: token))
    }

    private func handleLockTrigger(_ trigger: Trigger) {
        if trigger == .appResignedActive {
            guard lockPolicyProvider() == .appDeactivates else { return }
        }
        onLockTriggered?(trigger)
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor (MacLockMonitor) -> Void
    ) {
        // queue: nil delivers synchronously on the posting thread, and every
        // observed notification is posted on the main thread, so
        // `assumeIsolated` re-asserts the main-actor guarantee without a hop.
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            } else {
                // Defensive: should not happen for the observed notifications,
                // but never crash on an off-main delivery.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    handler(self)
                }
            }
        }
        observers.append((center: center, token: token))
    }
}
#endif
