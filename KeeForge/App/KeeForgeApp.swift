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
                    if !BiometricService.isBiometricAuthInProgress {
                        screenProtectionService.showShield()
                    }
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

    var body: some View {
        Group {
            if let activeDatabaseViewModel {
                ActiveDatabaseScene(
                    viewModel: activeDatabaseViewModel,
                    onReturnToList: returnToDatabaseList
                )
            } else {
                DatabaseListView(
                    viewModel: listViewModel,
                    onSelectDatabase: openDatabase
                )
            }
        }
        .onAppear {
            attemptInitialAutoOpen()
        }
    }

    private func attemptInitialAutoOpen() {
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
}

private struct ActiveDatabaseScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    @State private var hasUnlockedInThisSession = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked, .unlocking, .error:
                UnlockView(
                    viewModel: viewModel,
                    onBackToDatabaseList: onReturnToList
                )
            case .unlocked:
                DatabaseNavigationView(viewModel: viewModel)
            }
        }
        .onChange(of: viewModel.state) { _, newValue in
            if case .unlocked = newValue {
                hasUnlockedInThisSession = true
            }

            if hasUnlockedInThisSession, case .locked = newValue {
                onReturnToList()
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
        }
    }
}
