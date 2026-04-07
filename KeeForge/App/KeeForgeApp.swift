import SwiftUI

@main
struct KeeForgeApp: App {
    @State private var listViewModel = DatabaseListViewModel()
    @State private var activeDatabaseViewModel: DatabaseViewModel?
    @State private var screenProtectionService = ScreenProtectionService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView(
                listViewModel: listViewModel,
                activeDatabaseViewModel: $activeDatabaseViewModel
            )
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    screenProtectionService.hideShield()
                    activeDatabaseViewModel?.didManuallyLock = false
                    activeDatabaseViewModel?.resetInactivityTimer()
                    activeDatabaseViewModel?.refreshSharedDatabaseCacheIfPossible()
                case .inactive:
                    break
                case .background:
                    screenProtectionService.showShield()
                    activeDatabaseViewModel?.lock()
                @unknown default:
                    screenProtectionService.showShield()
                }
            }
        }
    }
}

private struct AppRootView: View {
    @Bindable var listViewModel: DatabaseListViewModel
    @Binding var activeDatabaseViewModel: DatabaseViewModel?
    @State private var didResolveInitialRoute = false

    private var isPresented: Binding<Bool> {
        Binding(
            get: { activeDatabaseViewModel != nil },
            set: { isPresented in
                if !isPresented {
                    returnToDatabaseList()
                }
            }
        )
    }

    var body: some View {
        Group {
            if !didResolveInitialRoute {
                LaunchRoutingView()
            } else {
                DatabaseListView(
                    viewModel: listViewModel,
                    onSelectDatabase: openDatabase
                )
            }
        }
        .task {
            await resolveInitialRouteIfNeeded()
        }
        .sheet(isPresented: isPresented) {
            if let activeDatabaseViewModel {
                ActiveDatabaseScene(
                    viewModel: activeDatabaseViewModel,
                    onReturnToList: returnToDatabaseList
                )
                .interactiveDismissDisabled(activeDatabaseViewModel.state == .unlocking)
                .presentationDragIndicator(.visible)
            }
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
    }

    private func resolveInitialRouteIfNeeded() async {
        guard didResolveInitialRoute == false else { return }
        defer { didResolveInitialRoute = true }

        guard activeDatabaseViewModel == nil else { return }
        guard let databaseReference = listViewModel.databaseToAutoOpenOnLaunch() else { return }
        openDatabase(databaseReference)
    }

    private func openDatabase(_ reference: DatabaseReference) {
        activeDatabaseViewModel = DatabaseViewModel(databaseReference: reference)
    }

    private func returnToDatabaseList() {
        activeDatabaseViewModel = nil
        listViewModel.reload()
    }

    private func handleOpenURL(_ url: URL) {
        if CloudProviderRegistry.handleOpenURL(url) {
            return
        }

        // If already viewing a database, dismiss it first
        if activeDatabaseViewModel != nil {
            activeDatabaseViewModel = nil
        }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            openDatabase(reference)
        } catch {
            // Database may already exist in the list — find and open it
            if let existing = listViewModel.databases.first(where: {
                $0.filename == url.lastPathComponent
            }) {
                openDatabase(existing)
            }
        }
    }
}

private struct ActiveDatabaseScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    @State private var hasUnlockedInThisSession = false
    @State private var autoUnlockAttemptedLockCycle: Int?

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if hasUnlockedInThisSession {
                    // About to dismiss sheet — show background only to avoid
                    // flashing UnlockView for one frame before onDismiss fires.
                    UnlockViewBackground()
                } else if shouldShowAutoUnlockOpeningView {
                    DatabaseOpeningView(
                        databaseName: viewModel.databaseDisplayName,
                        statusMessage: viewModel.unlockStatusMessage,
                        progress: viewModel.cloudSyncProgress
                    )
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
                DatabaseOpeningView(
                    databaseName: viewModel.databaseDisplayName,
                    statusMessage: viewModel.unlockStatusMessage,
                    progress: viewModel.cloudSyncProgress
                )
                    .transition(.opacity)
            case .unlocked:
                DatabaseNavigationView(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
        .onChange(of: viewModel.state) { _, newValue in
            if case .unlocked = newValue {
                hasUnlockedInThisSession = true
            }

            if hasUnlockedInThisSession, case .locked = newValue {
                onReturnToList()
            }
        }
        .onAppear {
            attemptAutoUnlockIfNeeded()
        }
        .onChange(of: viewModel.lockCycleID) { _, _ in
            attemptAutoUnlockIfNeeded()
        }
        .onChange(of: viewModel.canUseBiometrics) { _, _ in
            attemptAutoUnlockIfNeeded()
        }
    }

    private var shouldShowAutoUnlockOpeningView: Bool {
        guard SettingsService.autoUnlockWithFaceID else { return false }
        guard viewModel.hasSavedFile else { return false }
        guard viewModel.canUseBiometrics else { return false }
        guard !viewModel.didManuallyLock else { return false }
        guard case .locked = viewModel.state else { return false }
        return true
    }

    private func attemptAutoUnlockIfNeeded() {
        guard shouldShowAutoUnlockOpeningView else { return }
        guard autoUnlockAttemptedLockCycle != viewModel.lockCycleID else { return }

        autoUnlockAttemptedLockCycle = viewModel.lockCycleID

        Task {
            await viewModel.unlockWithBiometrics()
        }
    }
}

private struct LaunchRoutingView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                Text("KeeForge")
                    .font(.title2.weight(.semibold))

                ProgressView()
                    .controlSize(.regular)
            }
        }
    }
}

struct DatabaseNavigationView: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        NavigationStack(path: $viewModel.navigationPath) {
            Group {
                if let root = viewModel.rootGroup {
                    GroupListView(group: root, viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Vault Not Loaded",
                        systemImage: "lock.doc",
                        description: Text("Unlock a database to view groups and entries.")
                    )
                }
            }
            .navigationDestination(for: KPGroup.self) { group in
                GroupListView(group: group, viewModel: viewModel)
            }
            .navigationDestination(for: KPEntry.self) { entry in
                EntryDetailView(entry: entry, sessionKey: viewModel.sessionKey!)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let bannerText = viewModel.cloudSyncBannerText {
                    Label(bannerText, systemImage: "icloud")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.12))
                }
            }
        }
    }
}
