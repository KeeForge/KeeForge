import AuthenticationServices
import StoreKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct KeeForgeApp: App {
    @State private var listViewModel = DatabaseListViewModel()
    @State private var sessionStore = DatabaseSessionStore()
    @State private var routing = AppRoutingCoordinator()
    @State private var pendingUploadDrainer = PendingUploadDrainer()
    @State private var screenProtectionService = ScreenProtectionService()
    #if os(macOS)
    @State private var macLockMonitor = MacLockMonitor()
    @State private var macWindowCloseGuard = MacWindowCloseGuard()
    @State private var macQuickAccess = MacQuickAccessController()
    @State private var macSSHAgent = MacSSHAgentController()
    #else
    @State private var appSettingsPresentation = AppSettingsPresentation()
    #endif
    @AppStorage(SettingsService.appearanceModeDefaultsKey) private var appearanceModeRaw = SettingsService.AppearanceMode.system.rawValue
    @AppStorage(SettingsService.appAccentColorDefaultsKey) private var appAccentColorRaw = ""
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
    static let mainWindowID = "main"
    #endif

    init() {
        AutoFillDiagnostics.migrateLegacyLogLocation()
    }

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            SettingsView(viewModel: sessionStore.activeSession, listViewModel: listViewModel)
                .environment(sessionStore)
                .environment(macQuickAccess)
                .environment(macSSHAgent)
                .tint(appAccentColor)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
        }
        #endif
    }

    private var mainWindow: some Scene {
        #if os(macOS)
        // An id so the menu bar quick search can reopen the window after ⌘W.
        let windowGroup = WindowGroup(id: Self.mainWindowID) {
            mainWindowContent
        }
        #else
        let windowGroup = WindowGroup {
            mainWindowContent
        }
        #endif

        #if os(macOS)
        return windowGroup
            .defaultSize(width: 1080, height: 700)
            .commands {
                KeeForgeCommands(
                    listViewModel: listViewModel,
                    sessionStore: sessionStore,
                    routing: routing
                )
                #if KEEFORGE_DIRECT_DOWNLOAD
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesCommand()
                }
                #endif
            }
        #else
        return windowGroup
            .commands {
                AppSettingsCommands(presentation: appSettingsPresentation)
            }
        #endif
    }

    private var mainWindowContent: some View {
        rootView
        #if os(macOS)
        // The height floor is the content area, so it must stay clear of
        // `MacSheetMetrics.maxHeight` — a sheet is anchored under the
        // toolbar and would otherwise sit flush with the window's bottom.
        .frame(minWidth: 900, minHeight: 620)
        .focusedSceneValue(\.databaseViewModel, sessionStore.activeSession)
        .environment(macQuickAccess)
        .environment(macSSHAgent)
        .modifier(MacQuickAccessMainWindowHookup(controller: macQuickAccess, sshAgent: macSSHAgent, activeSession: sessionStore.activeSession))
        #else
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
        #endif
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
                // macOS: the scene phase moves to .background on window
                // minimize / app hide, which must not lock under the
                // default policy. MacLockMonitor is the sole lock driver
                // on the Mac; see startMacLockMonitoringIfNeeded().
                #if os(iOS)
                sessionStore.handleAppDidEnterBackground()
                #endif
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
            startMacLockMonitoringIfNeeded()
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
        #if os(iOS)
        let listViewModel = self.listViewModel
        Task.detached(priority: .utility) {
            guard DocumentsVaultScanner.scan() else { return }
            await MainActor.run {
                listViewModel.reload()
            }
        }
        #endif
    }

    private func startMacLockMonitoringIfNeeded() {
        #if os(macOS)
        let sessionStore = self.sessionStore
        let listViewModel = self.listViewModel

        macLockMonitor.onLockTriggered = { _ in
            NotificationCenter.default.post(name: MacBiometricAutoUnlockController.lockRequestedNotification, object: nil)
            sessionStore.handleAppDidEnterBackground()
        }
        macLockMonitor.onDidBecomeActive = {
            sessionStore.handleAppDidBecomeActive()
            Task {
                await listViewModel.drainPendingUploadsOnAppActive()
            }
        }
        macLockMonitor.onUserActivity = {
            sessionStore.resetInactivityTimers()
        }
        macLockMonitor.start()

        // The monitor's window-close trigger fires after the close is
        // committed, which is too late to ask about unsaved work; the guard
        // runs before it.
        macWindowCloseGuard.vaultProvider = { sessionStore.activeSession }
        macWindowCloseGuard.start()

        macQuickAccess.start()

        macSSHAgent.sessionProvider = { sessionStore.activeSession }
        macSSHAgent.start()
        #endif
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
