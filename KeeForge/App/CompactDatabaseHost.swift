import SwiftUI

#if os(iOS)

struct CompactDatabaseHost: View {
    @Bindable var listViewModel: DatabaseListViewModel
    @Bindable var viewModel: DatabaseViewModel
    let onSelectDatabase: (DatabaseReference) -> Void
    let onCreateDatabase: (CreatedDatabase) -> Void
    let onReturnToList: () -> Void

    @State private var hasUnlockedInThisSession = false

    private var isUnlockPresented: Binding<Bool> {
        Binding(
            get: {
                guard hasUnlockedInThisSession == false else { return false }
                if case .unlocked = viewModel.state {
                    return false
                }
                return true
            },
            set: { isPresented in
                if isPresented == false,
                   hasUnlockedInThisSession == false,
                   !isVaultOpen {
                    onReturnToList()
                }
            }
        )
    }

    private var isVaultOpen: Bool {
        if case .unlocked = viewModel.state {
            return true
        }
        return false
    }

    var body: some View {
        Group {
            if case .unlocked = viewModel.state {
                DatabaseNavigationView(viewModel: viewModel)
            } else {
                DatabaseListView(
                    viewModel: listViewModel,
                    onSelectDatabase: onSelectDatabase,
                    onCreateDatabase: onCreateDatabase,
                    unlockPage: DatabaseListView.UnlockPage(isPresented: isUnlockPresented) {
                        AnyView(
                            CompactUnlockScene(
                                viewModel: viewModel,
                                onReturnToList: onReturnToList
                            )
                            .navigationBarBackButtonHidden(viewModel.state == .unlocking)
                        )
                    }
                )
            }
        }
        .onAppear {
            if case .unlocked = viewModel.state {
                hasUnlockedInThisSession = true
            }
        }
        .onChange(of: viewModel.state) { _, newValue in
            if case .unlocked = newValue {
                hasUnlockedInThisSession = true
                return
            }

            if hasUnlockedInThisSession, case .locked = newValue {
                // Manual locks only. An automatic lock can fire as the app is
                // being backgrounded, and a snapshot added at that moment is
                // exactly what iOS would capture for the app switcher — the
                // one place vault content must never survive. Those locks keep
                // the instant cut and `ScreenProtectionService`'s shield.
                if viewModel.didManuallyLock {
                    VaultCloseTransition.coverCurrentFrame()
                }
                onReturnToList()
            }
        }
    }
}

#endif

/// Offered by the opening screen only while a YubiKey challenge is outstanding.
@MainActor
private func hardwareKeyCancelAction(for viewModel: DatabaseViewModel) -> (() -> Void)? {
    guard viewModel.isAwaitingHardwareKey else { return nil }
    return { viewModel.cancelHardwareKeyRequest() }
}

#if os(iOS)
private struct CompactUnlockScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if viewModel.isAwaitingBiometricAutoUnlock {
                    DatabaseOpeningView(viewModel: viewModel)
                        .transition(.opacity)
                } else {
                    UnlockView(
                        viewModel: viewModel,
                        onBackToDatabaseList: onReturnToList
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .error:
                UnlockView(
                    viewModel: viewModel,
                    onBackToDatabaseList: onReturnToList
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case .unlocking:
                DatabaseOpeningView(viewModel: viewModel, onCancel: hardwareKeyCancelAction(for: viewModel))
                    .transition(.opacity)
            case .unlocked:
                // The compact sheet dismisses as soon as unlock succeeds.
                UnlockViewBackground()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
        .biometricAutoUnlock(viewModel)
    }
}

#endif

struct RegularDatabaseScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                #if os(macOS)
                unlockView
                #else
                if viewModel.isAwaitingBiometricAutoUnlock {
                    DatabaseOpeningView(viewModel: viewModel)
                    .transition(.opacity)
                } else {
                    unlockView
                }
                #endif
            case .error:
                unlockView
            case .unlocking:
                DatabaseOpeningView(viewModel: viewModel, onCancel: hardwareKeyCancelAction(for: viewModel))
                .transition(.opacity)
            case .unlocked:
                RegularDatabaseWorkspaceView(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.state)
        #if os(iOS)
        .biometricAutoUnlock(viewModel)
        #endif
    }

    private var unlockView: some View {
        UnlockView(
            viewModel: viewModel,
            onBackToDatabaseList: onReturnToList,
            showsChooseDifferentFileAction: false
        )
        .transition(.opacity)
    }
}

#if os(iOS)
/// Runs the opt-in biometric auto-unlock at most once per lock cycle, and only
/// while the scene is foreground-active. Platform exclusions live in
/// `BiometricAutoUnlockPolicy`, folded into the view model's eligibility.
///
/// LocalAuthentication refuses to present its prompt to a caller that is not
/// running in the foreground and fails the evaluation with
/// `LAError.notInteractive` instead (#60). Both lock-on-background — which
/// starts a new lock cycle while the app is on its way out — and Quick Launch,
/// which opens the database before the scene activates, used to reach the
/// prompt in exactly that state, burning the cycle's one attempt on an error
/// screen that a manual retry then cleared.
private struct BiometricAutoUnlockModifier: ViewModifier {
    let viewModel: DatabaseViewModel

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                attemptIfNeeded()
            }
            .onChange(of: scenePhase) { _, _ in
                attemptIfNeeded()
            }
            .onChange(of: viewModel.lockCycleID) { _, _ in
                attemptIfNeeded()
            }
            .onChange(of: viewModel.canUseBiometrics) { _, _ in
                attemptIfNeeded()
            }
            .onChange(of: viewModel.didManuallyLock) { _, _ in
                attemptIfNeeded()
            }
    }

    private func attemptIfNeeded() {
        guard scenePhase == .active else { return }
        guard viewModel.isEligibleForBiometricAutoUnlock else { return }
        guard viewModel.claimBiometricAutoUnlockAttempt() else { return }

        Task {
            if await viewModel.unlockWithBiometrics() == .promptUnavailable {
                // Nothing was presented, so this lock cycle keeps its attempt.
                viewModel.releaseBiometricAutoUnlockAttempt()
            }
        }
    }
}

private extension View {
    func biometricAutoUnlock(_ viewModel: DatabaseViewModel) -> some View {
        modifier(BiometricAutoUnlockModifier(viewModel: viewModel))
    }
}
#endif

