import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

@main
struct KeeForgeApp: App {
    @State private var listViewModel: DatabaseListViewModel
    @State private var sessionStore: DatabaseSessionStore
    @State private var routing = AppRoutingCoordinator()
    @State private var pendingUploadDrainer = PendingUploadDrainer()
    @State private var screenProtectionService = ScreenProtectionService()
    @State private var appSettingsPresentation = AppSettingsPresentation()
    @AppStorage(SettingsService.appearanceModeDefaultsKey) private var appearanceModeRaw = SettingsService.AppearanceMode.system.rawValue
    @AppStorage(SettingsService.appAccentColorDefaultsKey) private var appAccentColorRaw = ""
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AutoFillDiagnostics.migrateLegacyLogLocation()
        let sessionStore = DatabaseSessionStore()
        let listViewModel = DatabaseListViewModel()
        sessionStore.installListHooks(on: listViewModel)
        _sessionStore = State(initialValue: sessionStore)
        _listViewModel = State(initialValue: listViewModel)
    }

    var body: some Scene {
        mainWindow
    }

    private var mainWindow: some Scene {
        let windowGroup = WindowGroup {
            mainWindowContent
        }

        return windowGroup
            .commands {
                AppSettingsCommands(presentation: appSettingsPresentation)
            }
    }

    private var mainWindowContent: some View {
        rootView
        // App-owned Settings sheet (⌘, / the Mac-compat toolbar gear),
        // above the root so it survives the lock/unlock root swap.
        .environment(appSettingsPresentation)
        .background {
            let sessionStore = self.sessionStore
            IOSUserActivityObserver {
                sessionStore.resetInactivityTimers()
            }
        }
        .sheet(isPresented: $appSettingsPresentation.isPresented) {
            SettingsView(viewModel: sessionStore.activeSession, listViewModel: listViewModel)
        }
        .tint(appAccentColor)
        .preferredColorScheme(appearanceMode.preferredColorScheme)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                screenProtectionService.update(sceneIsActive: true)
                sessionStore.handleAppDidBecomeActive()
                scanDocumentsForSharedDatabases()
                Task {
                    await listViewModel.drainPendingUploadsOnAppActive()
                }
            case .inactive:
                break
            case .background:
                screenProtectionService.update(sceneIsActive: false)
                sessionStore.handleAppDidEnterBackground()
            @unknown default:
                screenProtectionService.update(sceneIsActive: false)
            }
        }
        .task {
            // A recording already running at launch sends no change notification.
            screenProtectionService.update(sceneIsActive: scenePhase != .background)
            // Plaintext preview files orphaned by a process that died
            // without locking; must run before this session writes any.
            AttachmentPreviewFileStore.purgeOrphanedFiles()
            DatabaseExportService.purgeShareFiles()
            // At launch, not on Tip Jar open, so out-of-app completions
            // (Ask to Buy, deferred SCA) are still delivered and finished.
            // The direct target compiles this path out because it has no
            // App Store receipt and must not link StoreKit.
            #if !KEEFORGE_DIRECT_DOWNLOAD
                StoreKitManager.shared.start()
            #endif
            pendingUploadDrainer.startObserving {
                Task {
                    await listViewModel.drainPendingUploadsOnAppActive()
                }
            }
        }
        .environment(sessionStore)
    }

    /// Root content for the main window. In DEBUG builds the
    /// `-autofill-store-inspector` launch argument replaces the normal database
    /// list with the AutoFill store inspector, and `-autofill-picker-harness`
    /// with the AutoFill picker (developer tooling); Release builds always
    /// show the normal root.
    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if AutoFillStoreInspectorView.isPresentationRequested {
            AutoFillStoreInspectorView()
        } else if AutoFillPickerHarnessView.isPresentationRequested {
            AutoFillPickerHarnessView()
        } else {
            AppRootView(
                listViewModel: listViewModel,
                sessionStore: sessionStore,
                routing: routing
            )
        }
        #else
        AppRootView(
            listViewModel: listViewModel,
            sessionStore: sessionStore,
            routing: routing
        )
        #endif
    }

    /// Registers KDBX files dropped into Documents via Finder/iTunes file
    /// sharing (iOS only; the Mac app has no shared Documents container).
    /// Triggered from the scenePhase `.active` branch, which also fires at
    /// cold launch.
    private func scanDocumentsForSharedDatabases() {
        let listViewModel = self.listViewModel
        Task.detached(priority: .utility) {
            guard DocumentsVaultScanner.scan() else { return }
            await MainActor.run {
                listViewModel.reload()
            }
        }
    }

    private var appearanceMode: SettingsService.AppearanceMode {
        SettingsService.AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var appAccentColor: Color {
        SettingsService.AppAccentColor(rawValue: appAccentColorRaw)?.color ?? Color("AccentColor")
    }
}

private extension SettingsService.AppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
