import AuthenticationServices
import SwiftUI
import UIKit

@main
struct KeeForgeApp: App {
    @State private var listViewModel = DatabaseListViewModel()
    @State private var activeDatabaseViewModel: DatabaseViewModel?
    @State private var pendingUploadDrainer = PendingUploadDrainer()
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
                    Task {
                        await listViewModel.drainPendingUploadsOnAppActive()
                    }
                case .inactive:
                    break
                case .background:
                    screenProtectionService.showShield()
                    activeDatabaseViewModel?.lockRequest()
                @unknown default:
                    screenProtectionService.showShield()
                }
            }
            .task {
                pendingUploadDrainer.startObserving {
                    Task {
                        await listViewModel.drainPendingUploadsOnAppActive()
                    }
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
    @State private var presentedSaveError: DatabaseSaveError?
    @State private var isDropboxReconnectInFlight = false

    var body: some View {
        NavigationStack(path: $viewModel.navigationPath) {
            Group {
                if let root = viewModel.currentRootGroup {
                    GroupListView(groupID: root.id, viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Vault Not Loaded",
                        systemImage: "lock.doc",
                        description: Text("Unlock a database to view groups and entries.")
                    )
                }
            }
            .navigationDestination(for: KPGroup.self) { group in
                GroupListView(groupID: group.id, viewModel: viewModel)
            }
            .navigationDestination(for: KPEntry.self) { entry in
                EntryDetailView(entryID: entry.id, viewModel: viewModel)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if let bannerText = viewModel.cloudSyncBannerText {
                        BannerLabel(
                            text: bannerText,
                            systemImage: "icloud",
                            foregroundStyle: .orange,
                            backgroundColor: Color.orange.opacity(0.12)
                        )
                    }

                    if viewModel.saveError?.isWriteScopeRequired == true {
                        CloudReauthBanner(
                            isReconnectInFlight: isDropboxReconnectInFlight,
                            onReconnect: beginDropboxReconnect
                        )
                    }

                    if viewModel.isDirty && viewModel.isSaving == false {
                        UnsavedChangesBanner(viewModel: viewModel)
                    }

                    if viewModel.isReadOnly {
                        ReadOnlyRibbon()
                    }
                }
            }
        }
        .saveConflictAlert(viewModel: viewModel)
        .onChange(of: viewModel.saveError) { _, newValue in
            if let newValue {
                presentedSaveError = newValue
            }
        }
        .alert(item: $presentedSaveError) { error in
            Alert(
                title: Text("Couldn't Save Database"),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "Lock and discard unsaved changes?",
            isPresented: Binding(
                get: { viewModel.pendingLockRequest != nil },
                set: { isPresented in
                    if isPresented == false {
                        viewModel.cancelLockRequest()
                    }
                }
            )
        ) {
            Button("Lock and Discard", role: .destructive) {
                let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
            }
            Button("Keep Editing", role: .cancel) {
                viewModel.cancelLockRequest()
            }
        } message: {
            Text("Your unsaved entry changes will be lost.")
        }
    }

    @MainActor
    private func beginDropboxReconnect() {
        guard isDropboxReconnectInFlight == false else { return }
        guard let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isDropboxReconnectInFlight = true
        Task { @MainActor in
            defer { isDropboxReconnectInFlight = false }

            do {
                _ = try await provider.authenticate(from: presentationAnchor())
                viewModel.clearSaveError()
            } catch let error as CloudProviderError where error == .authenticationCancelled {
                return
            } catch {
                viewModel.presentSaveError(error)
            }
        }
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
    }
}

private struct ReadOnlyRibbon: View {
    var body: some View {
        Text("Read-only mode — toggle in the database list to enable editing.")
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.18))
            .accessibilityIdentifier("database.read-only-ribbon")
    }
}

private struct UnsavedChangesBanner: View {
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
            Text("Changes not saved")
                .font(.caption.weight(.medium))

            Spacer(minLength: 12)

            Button("Retry Save") {
                Task {
                    await viewModel.saveHandlingError()
                }
            }
            .font(.caption.weight(.semibold))
            .disabled(viewModel.isSaving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("database.unsaved-indicator")
    }
}

private struct CloudReauthBanner: View {
    let isReconnectInFlight: Bool
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reconnect Dropbox to save changes.")
                .font(.subheadline.weight(.semibold))
            Button("Reconnect Dropbox", action: onReconnect)
                .buttonStyle(.borderedProminent)
                .disabled(isReconnectInFlight)
                .accessibilityIdentifier("cloud-reauth-banner.reconnect")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .accessibilityIdentifier("cloud-reauth-banner")
    }
}

private struct BannerLabel: View {
    let text: String
    let systemImage: String
    let foregroundStyle: Color
    let backgroundColor: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(backgroundColor)
    }
}
