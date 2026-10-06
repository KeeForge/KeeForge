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
///   The app's own authentication prompt is the exception: the system shows
///   it from a separate process, so asking to reveal a password deactivates
///   the app the same way leaving it does. That deactivation is held instead
///   of locking, but only for the system's authentication UI itself
///   (`ForegroundApplication.isSystemAuthenticationPrompt`); a prompt being
///   requested does not excuse any other application coming forward
///   (`NSWorkspace.didActivateApplicationNotification`). When the prompt ends
///   the hold is settled: KeeForge is active again shortly after, or it locks.
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
    /// Whether the app has asked the system for an authentication prompt that
    /// has not ended yet. True from before the prompt appears, so on its own
    /// it does not say what a deactivation was caused by.
    typealias AuthenticationPromptProvider = @MainActor () -> Bool
    typealias FrontmostApplicationProvider = @MainActor () -> ForegroundApplication?
    /// Runs `work` on the main actor after `delay` seconds. Injected so tests
    /// can let the reactivation deadline pass without waiting for it.
    typealias DeadlineScheduler = @MainActor (
        _ delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    /// What the monitor needs to know about an application that is, or just
    /// came, in front. A value rather than an `NSRunningApplication` so it can
    /// leave the thread a notification was posted on, and so tests can stand
    /// in for applications that are not running.
    struct ForegroundApplication: Equatable, Sendable {
        var processIdentifier: pid_t
        var bundleIdentifier: String?
        var bundleURL: URL?

        init(processIdentifier: pid_t, bundleIdentifier: String?, bundleURL: URL?) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.bundleURL = bundleURL
        }

        init(_ application: NSRunningApplication) {
            self.init(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL
            )
        }

        /// `coreautha`, the agent macOS shows the Touch ID, Apple Watch and
        /// login-password prompt from.
        static let systemAuthenticationPromptBundleIdentifier = "com.apple.LocalAuthentication.UIAgent"

        /// Whether this is the system's authentication UI. The bundle
        /// identifier alone is whatever an application declares about itself,
        /// so the bundle must also sit on the signed system volume, where
        /// nothing but the system can put one.
        var isSystemAuthenticationPrompt: Bool {
            guard bundleIdentifier == Self.systemAuthenticationPromptBundleIdentifier,
                  let bundleURL, bundleURL.isFileURL else { return false }
            return bundleURL.standardizedFileURL.path.hasPrefix("/System/Library/")
        }
    }

    /// How long KeeForge may take to be active again once its prompt has
    /// ended. The system hands the foreground back within a few hundredths of
    /// a second; the reply can still arrive just before the reactivation, so
    /// locking on the reply itself would lock an answered prompt.
    nonisolated static let defaultReactivationGracePeriod: TimeInterval = 2

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
    private let isAuthenticationPromptPending: AuthenticationPromptProvider
    private let frontmostApplication: FrontmostApplicationProvider
    private let reactivationGracePeriod: TimeInterval
    private let scheduleDeadline: DeadlineScheduler
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    private let now: @MainActor () -> Date
    private let activityThrottle: TimeInterval
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var activityMonitor: Any?
    private var lastActivityForwardedAt: Date?
    /// True while the strict policy holds a deactivation behind the app's own
    /// authentication prompt instead of locking on it.
    private var isHoldingDeactivation = false
    /// Identifies the reactivation deadline that may still lock; one that was
    /// scheduled before the hold ended or a new prompt began no longer counts.
    private var reactivationDeadline = 0

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        lockPolicyProvider: @escaping LockPolicyProvider = { SettingsService.macLockPolicy },
        remainingWindowCounter: @escaping RemainingWindowCounter = MacLockMonitor.countRemainingHostWindows,
        authenticationPromptProvider: @escaping AuthenticationPromptProvider = {
            BiometricService.isBiometricAuthInProgress
        },
        frontmostApplicationProvider: @escaping FrontmostApplicationProvider = {
            NSWorkspace.shared.frontmostApplication.map { ForegroundApplication($0) }
        },
        reactivationGracePeriod: TimeInterval = MacLockMonitor.defaultReactivationGracePeriod,
        deadlineScheduler: @escaping DeadlineScheduler = MacLockMonitor.scheduleOnMainQueue,
        now: @escaping @MainActor () -> Date = { Date() },
        activityThrottle: TimeInterval = 2
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.lockPolicyProvider = lockPolicyProvider
        self.remainingWindowCounter = remainingWindowCounter
        self.isAuthenticationPromptPending = authenticationPromptProvider
        self.frontmostApplication = frontmostApplicationProvider
        self.reactivationGracePeriod = reactivationGracePeriod
        self.scheduleDeadline = deadlineScheduler
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
            monitor.endHeldDeactivation()
            monitor.onDidBecomeActive?()
        }
        observe(notificationCenter, BiometricService.authenticationInProgressDidChangeNotification) { monitor in
            monitor.handleAuthenticationPromptStateChange()
        }
        observeWindowClose()
        observeApplicationActivation()

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
        endHeldDeactivation()
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

    /// An application came to the front. Only matters while a deactivation is
    /// held: the system's authentication UI is the one application expected
    /// there, and KeeForge itself reports back through
    /// `didBecomeActiveNotification`. Anything else means the user left
    /// KeeForge, whether the prompt is still up or not. Exposed for tests,
    /// which cannot activate real applications.
    func handleApplicationDidActivate(_ application: ForegroundApplication) {
        guard isHoldingDeactivation else { return }
        guard application.processIdentifier != ownProcessIdentifier else { return }
        guard application.isSystemAuthenticationPrompt == false else { return }
        lockOnHeldDeactivation()
    }

    /// The app's request for an authentication prompt began or ended.
    /// `BiometricService` posts the change; exposed for tests, which have no
    /// system prompt to end.
    ///
    /// The end of the request settles a held deactivation, so that the hold
    /// never outlives the prompt it was made for: an application other than
    /// the prompt's in front locks at once, and otherwise KeeForge has
    /// `reactivationGracePeriod` to become active again.
    func handleAuthenticationPromptStateChange() {
        guard isHoldingDeactivation else { return }
        reactivationDeadline += 1
        // A new request while the last one is still being settled: its prompt
        // takes over the hold.
        guard isAuthenticationPromptPending() == false else { return }

        guard Self.isExpectedBehindAuthenticationPrompt(frontmostApplication(), own: ownProcessIdentifier) else {
            lockOnHeldDeactivation()
            return
        }
        let deadline = reactivationDeadline
        scheduleDeadline(reactivationGracePeriod) { [weak self] in
            guard let self, self.isHoldingDeactivation, self.reactivationDeadline == deadline else { return }
            self.lockOnHeldDeactivation()
        }
    }

    /// Whether the application in front fits a deactivation the app's own
    /// prompt caused: the system's authentication UI, or nothing else yet —
    /// the deactivation can be delivered before the workspace reports who took
    /// the foreground, and that application's activation is then judged when
    /// it arrives.
    private static func isExpectedBehindAuthenticationPrompt(
        _ frontmost: ForegroundApplication?,
        own ownProcessIdentifier: pid_t
    ) -> Bool {
        guard let frontmost, frontmost.processIdentifier != ownProcessIdentifier else { return true }
        return frontmost.isSystemAuthenticationPrompt
    }

    private func endHeldDeactivation() {
        isHoldingDeactivation = false
        reactivationDeadline += 1
    }

    /// Requests the lock a held deactivation stood for. The policy is read
    /// again: the hold was made under the strict one, and the lock must not
    /// outlast a change away from it.
    private func lockOnHeldDeactivation() {
        endHeldDeactivation()
        guard lockPolicyProvider() == .appDeactivates else { return }
        onLockTriggered?(.appResignedActive)
    }

    nonisolated static func scheduleOnMainQueue(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Registered on its own for the same reason as `observeWindowClose`: the
    /// activated application is in the notification's `userInfo`. Only a
    /// value describing it leaves the posting thread.
    private func observeApplicationActivation() {
        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let application = ForegroundApplication(running)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleApplicationDidActivate(application)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleApplicationDidActivate(application)
                }
            }
        }
        observers.append((center: workspaceNotificationCenter, token: token))
    }

    private func handleLockTrigger(_ trigger: Trigger) {
        if trigger == .appResignedActive {
            guard lockPolicyProvider() == .appDeactivates else { return }
            // A pending prompt is not enough to hold the lock: the request is
            // marked before the prompt appears, so the user can still be
            // leaving for another application. That application in front
            // locks as it always did.
            if isAuthenticationPromptPending(),
               Self.isExpectedBehindAuthenticationPrompt(frontmostApplication(), own: ownProcessIdentifier) {
                isHoldingDeactivation = true
                reactivationDeadline += 1
                return
            }
        }
        endHeldDeactivation()
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
