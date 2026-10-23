#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacBiometricAutoUnlockController {
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
        return Task { @MainActor [weak self] in
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
    }

    func invalidatePendingAttempt() {
        pendingRequest += 1
    }
}

struct MacBiometricAutoUnlockObserver: NSViewRepresentable {
    static let lockRequestedNotification = Notification.Name("KeeForge.macAutoUnlockLockRequested")

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
        private var observers: [NSObjectProtocol] = []
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
            stop()
            if window != nil { start() }
        }

        private func start() {
            guard let window else { return }
            for (name, object) in [
                (NSApplication.didBecomeActiveNotification, nil),
                (NSWindow.didBecomeKeyNotification, window),
            ] as [(Notification.Name, AnyObject?)] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.controller.requestAttempt() }
                })
            }
            for name in [MacBiometricAutoUnlockObserver.lockRequestedNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller.invalidatePendingAttempt() }
                })
            }
            controller.requestAttempt()
        }

        func stop() {
            controller.invalidatePendingAttempt()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}
#endif
