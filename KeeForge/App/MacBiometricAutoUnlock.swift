#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacBiometricAutoUnlockController {
    struct NotificationCenters {
        var app: NotificationCenter = .default
        var workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
        var distributed: NotificationCenter = DistributedNotificationCenter.default()
    }

    static let lockRequestedNotification = Notification.Name("KeeForge.macAutoUnlockLockRequested")
    static let screenIsUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private(set) var latestAttempt: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let isEligible: () -> Bool
    private let lockCycleID: () -> Int
    private let isForeground: () -> Bool
    private let unlock: () async -> DatabaseViewModel.BiometricUnlockOutcome
    private var attemptedLockCycle: Int?
    private var pendingRequest = 0
    private var isUnlocking = false

    init(
        isEligible: @escaping () -> Bool,
        lockCycleID: @escaping () -> Int,
        isForeground: @escaping () -> Bool,
        unlock: @escaping () async -> DatabaseViewModel.BiometricUnlockOutcome
    ) {
        self.isEligible = isEligible
        self.lockCycleID = lockCycleID
        self.isForeground = isForeground
        self.unlock = unlock
    }

    @discardableResult
    func requestAttempt() -> Task<Void, Never> {
        let cycle = lockCycleID()
        pendingRequest += 1
        let request = pendingRequest
        // Activation observers must finish applying the lock policy first.
        let attempt = Task { @MainActor [weak self] in
            guard let self, self.pendingRequest == request,
                  self.lockCycleID() == cycle, self.isForeground(), self.isEligible(),
                  self.attemptedLockCycle != cycle, !self.isUnlocking else { return }
            self.attemptedLockCycle = cycle
            self.isUnlocking = true
            let outcome = await self.unlock()
            self.isUnlocking = false
            if outcome == .promptUnavailable, self.attemptedLockCycle == cycle {
                self.attemptedLockCycle = nil
            }
        }
        latestAttempt = attempt
        return attempt
    }

    func invalidatePendingAttempt() {
        pendingRequest += 1
    }

    /// Prompts on opening and on each return to the window: app activation,
    /// the window becoming key, or the screen unlocking or the login session
    /// returning while KeeForge stays the active app, which post neither.
    func startObserving(window: AnyObject?, centers: NotificationCenters = NotificationCenters()) {
        stopObserving()
        let attemptTriggers: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (centers.app, NSApplication.didBecomeActiveNotification, nil),
            (centers.app, NSWindow.didBecomeKeyNotification, window),
            (centers.distributed, Self.screenIsUnlockedNotification, nil),
            (centers.workspace, NSWorkspace.sessionDidBecomeActiveNotification, nil),
        ]
        for (center, name, object) in attemptTriggers {
            observe(center, name, object: object) { $0.requestAttempt() }
        }
        for name in [Self.lockRequestedNotification, NSApplication.didResignActiveNotification] {
            observe(centers.app, name, object: nil) { $0.invalidatePendingAttempt() }
        }
        requestAttempt()
    }

    func stopObserving() {
        invalidatePendingAttempt()
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        object: AnyObject?,
        action: @escaping @MainActor (MacBiometricAutoUnlockController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

struct MacBiometricAutoUnlockObserver: NSViewRepresentable {
    let viewModel: DatabaseViewModel

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(viewModel: viewModel)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stop()
    }

    final class ObserverView: NSView {
        private let viewModel: DatabaseViewModel
        private lazy var controller = MacBiometricAutoUnlockController(
            isEligible: { [weak self] in self?.viewModel.isEligibleForBiometricAutoUnlock == true },
            lockCycleID: { [weak self] in self?.viewModel.lockCycleID ?? -1 },
            isForeground: { [weak self] in
                guard let window = self?.window else { return false }
                return NSApp.isActive && window.isKeyWindow && window.isVisible
                    && !window.isMiniaturized && window.attachedSheet == nil
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == ProcessInfo.processInfo.processIdentifier
            },
            unlock: { [weak self] in
                guard let self else { return .failed }
                return await self.viewModel.unlockWithBiometrics()
            }
        )

        init(viewModel: DatabaseViewModel) {
            self.viewModel = viewModel
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                controller.startObserving(window: window)
            } else {
                controller.stopObserving()
            }
        }

        func stop() {
            controller.stopObserving()
        }
    }
}
#endif
