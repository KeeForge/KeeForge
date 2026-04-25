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
                    activeDatabaseViewModel?.handleSceneDidBecomeActive()
                    activeDatabaseViewModel?.refreshSharedDatabaseCacheIfPossible()
                    Task {
                        await listViewModel.drainPendingUploadsOnAppActive()
                    }
                case .inactive:
                    break
                case .background:
                    screenProtectionService.showShield()
                    activeDatabaseViewModel?.handleSceneDidEnterBackground()
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var didResolveInitialRoute = false

    var body: some View {
        Group {
            if !didResolveInitialRoute {
                LaunchRoutingView()
            } else {
                rootContent
            }
        }
        .task {
            await resolveInitialRouteIfNeeded()
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesRegularLayout {
            if let activeDatabaseViewModel, case .unlocked = activeDatabaseViewModel.state {
                RegularDatabaseWorkspaceView(viewModel: activeDatabaseViewModel)
            } else {
                NavigationSplitView {
                    DatabaseListView(
                        viewModel: listViewModel,
                        onSelectDatabase: openDatabase,
                        onCreateDatabase: openCreatedDatabase,
                        selectedDatabaseID: activeDatabaseViewModel?.databaseReference.id
                    )
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
                } detail: {
                    if let activeDatabaseViewModel {
                        RegularDatabaseScene(
                            viewModel: activeDatabaseViewModel,
                            onReturnToList: returnToDatabaseList
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Database",
                            systemImage: "externaldrive.connected.to.line.below",
                            description: Text("Choose a database from the sidebar to unlock and browse it.")
                        )
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        } else {
            if let activeDatabaseViewModel {
                CompactDatabaseHost(
                    listViewModel: listViewModel,
                    viewModel: activeDatabaseViewModel,
                    onSelectDatabase: openDatabase,
                    onCreateDatabase: openCreatedDatabase,
                    onReturnToList: returnToDatabaseList
                )
            } else {
                DatabaseListView(
                    viewModel: listViewModel,
                    onSelectDatabase: openDatabase,
                    onCreateDatabase: openCreatedDatabase
                )
            }
        }
    }

    private var usesRegularLayout: Bool {
        horizontalSizeClass == .regular
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

    private func openCreatedDatabase(_ createdDatabase: CreatedDatabase) {
        listViewModel.reload()
        activeDatabaseViewModel = DatabaseViewModel(createdDatabase: createdDatabase)
    }

    private func returnToDatabaseList() {
        activeDatabaseViewModel = nil
        listViewModel.reload()
    }

    private func handleOpenURL(_ url: URL) {
        if CloudProviderRegistry.handleOpenURL(url) {
            return
        }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            openDatabase(reference)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            if let existing = listViewModel.databases.first(where: { $0.id == existingReferenceID }) {
                openDatabase(existing)
            }
        } catch {
            if let existing = listViewModel.databases.first(where: {
                $0.filename == url.lastPathComponent
            }) {
                openDatabase(existing)
            }
        }
    }
}

private struct CompactDatabaseHost: View {
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
                    onCreateDatabase: onCreateDatabase
                )
            }
        }
        .sheet(isPresented: isUnlockPresented) {
            CompactUnlockScene(
                viewModel: viewModel,
                onReturnToList: onReturnToList
            )
            .interactiveDismissDisabled(viewModel.state == .unlocking)
            .presentationDragIndicator(.visible)
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
                onReturnToList()
            }
        }
    }
}

private struct CompactUnlockScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    @State private var autoUnlockAttemptedLockCycle: Int?

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if shouldShowAutoUnlockOpeningView {
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
                // The compact sheet dismisses as soon as unlock succeeds.
                UnlockViewBackground()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
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

private struct RegularDatabaseScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    @State private var autoUnlockAttemptedLockCycle: Int?

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if shouldShowAutoUnlockOpeningView {
                    DatabaseOpeningView(
                        databaseName: viewModel.databaseDisplayName,
                        statusMessage: viewModel.unlockStatusMessage,
                        progress: viewModel.cloudSyncProgress
                    )
                    .transition(.opacity)
                } else {
                    UnlockView(
                        viewModel: viewModel,
                        onBackToDatabaseList: onReturnToList,
                        showsChooseDifferentFileAction: false
                    )
                    .transition(.opacity)
                }
            case .error:
                UnlockView(
                    viewModel: viewModel,
                    onBackToDatabaseList: onReturnToList,
                    showsChooseDifferentFileAction: false
                )
                .transition(.opacity)
            case .unlocking:
                DatabaseOpeningView(
                    databaseName: viewModel.databaseDisplayName,
                    statusMessage: viewModel.unlockStatusMessage,
                    progress: viewModel.cloudSyncProgress
                )
                .transition(.opacity)
            case .unlocked:
                RegularDatabaseWorkspaceView(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.state)
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
                if let rootID = viewModel.visibleRootGroupID {
                    GroupListView(groupID: rootID, viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Vault Not Loaded",
                        systemImage: "lock.doc",
                        description: Text("Unlock a database to view groups and entries.")
                    )
                }
            }
            .navigationDestination(for: UUID.self) { groupID in
                GroupListView(groupID: groupID, viewModel: viewModel)
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
                }
            }
        }
        .disabled(viewModel.isSaving)
        .overlay {
            if viewModel.isSaving {
                DatabaseSavingOverlay()
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

struct DatabaseSavingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text("Saving changes...")
                    .font(.headline)

                Text("KeeForge is writing the updated database securely.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 280)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving changes")
        .accessibilityIdentifier("database.saving-overlay")
    }
}

struct UnsavedChangesBanner: View {
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("database.unsaved-indicator")
    }
}

struct CloudReauthBanner: View {
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

struct BannerLabel: View {
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
