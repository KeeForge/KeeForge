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
///
/// `NSApplication.didBecomeActiveNotification` drives the became-active
/// callback (pending-upload drain + inactivity-timer resume).
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
    }

    static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screensaverDidStartNotification = Notification.Name("com.apple.screensaver.didstart")

    typealias LockPolicyProvider = @MainActor () -> SettingsService.MacLockPolicy

    var onLockTriggered: ((Trigger) -> Void)?
    var onDidBecomeActive: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private let lockPolicyProvider: LockPolicyProvider
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        lockPolicyProvider: @escaping LockPolicyProvider = { SettingsService.macLockPolicy }
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.lockPolicyProvider = lockPolicyProvider
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
    }

    /// Removes all observers. The app keeps one monitor alive for its whole
    /// lifetime; tests must call this in teardown.
    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
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
