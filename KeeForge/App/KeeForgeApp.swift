import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct KeeForgeApp: App {
    @State private var listViewModel = DatabaseListViewModel()
    @State private var activeDatabaseViewModel: DatabaseViewModel?
    @State private var pendingUploadDrainer = PendingUploadDrainer()
    @State private var screenProtectionService = ScreenProtectionService()
    #if os(macOS)
    @State private var macLockMonitor = MacLockMonitor()
    #else
    @State private var isShowingAppSettings = false
    #endif
    @AppStorage(SettingsService.appearanceModeDefaultsKey) private var appearanceModeRaw = SettingsService.AppearanceMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AutoFillDiagnostics.migrateLegacyLogLocation()
    }

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            SettingsView(viewModel: activeDatabaseViewModel, listViewModel: listViewModel)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
        }
        #endif
    }

    private var mainWindow: some Scene {
        let windowGroup = WindowGroup {
            rootView
            #if os(macOS)
            // The height floor is the content area, so it must stay clear of
            // `MacSheetMetrics.maxHeight` — a sheet is anchored under the
            // toolbar and would otherwise sit flush with the window's bottom.
            .frame(minWidth: 900, minHeight: 620)
            .focusedSceneValue(\.databaseViewModel, activeDatabaseViewModel)
            #else
            // App-owned Settings sheet (⌘, / the Mac-compat toolbar gear),
            // above the root so it survives the lock/unlock root swap.
            .environment(\.presentAppSettings, { isShowingAppSettings = true })
            .sheet(isPresented: $isShowingAppSettings) {
                SettingsView(viewModel: activeDatabaseViewModel, listViewModel: listViewModel)
            }
            #endif
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    screenProtectionService.hideShield()
                    activeDatabaseViewModel?.didManuallyLock = false
                    activeDatabaseViewModel?.handleSceneDidBecomeActive()
                    activeDatabaseViewModel?.refreshSharedDatabaseCacheIfPossible()
                    scanDocumentsForSharedDatabases()
                    Task {
                        await listViewModel.drainPendingUploadsOnAppActive()
                    }
                case .inactive:
                    break
                case .background:
                    screenProtectionService.showShield()
                    // macOS: the scene phase moves to .background on window
                    // minimize / app hide, which must not lock under the
                    // default policy. MacLockMonitor is the sole lock driver
                    // on the Mac; see startMacLockMonitoringIfNeeded().
                    #if os(iOS)
                    activeDatabaseViewModel?.handleSceneDidEnterBackground()
                    #endif
                @unknown default:
                    screenProtectionService.showShield()
                }
            }
            .task {
                // Plaintext preview files orphaned by a process that died
                // without locking; must run before this session writes any.
                AttachmentPreviewFileStore.purgeOrphanedFiles()
                // At launch, not on Tip Jar open, so out-of-app completions
                // (Ask to Buy, deferred SCA) are still delivered and finished.
                // A direct-download build has no App Store receipt, so it never
                // touches StoreKit at all.
                if DistributionChannel.supportsStoreKit {
                    StoreKitManager.shared.start()
                }
                pendingUploadDrainer.startObserving {
                    Task {
                        await listViewModel.drainPendingUploadsOnAppActive()
                    }
                }
                startMacLockMonitoringIfNeeded()
            }
        }

        #if os(macOS)
        return windowGroup
            .defaultSize(width: 1080, height: 700)
            .commands {
                KeeForgeCommands(
                    listViewModel: listViewModel,
                    activeDatabaseViewModel: $activeDatabaseViewModel
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
                AppSettingsCommands(isPresented: $isShowingAppSettings)
            }
        #endif
    }

    /// Root content for the main window. In DEBUG builds the
    /// `-autofill-store-inspector` launch argument replaces the normal database
    /// list with the AutoFill store inspector (developer tooling); Release
    /// builds always show the normal root.
    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if AutoFillStoreInspectorView.isPresentationRequested {
            AutoFillStoreInspectorView()
        } else {
            AppRootView(
                listViewModel: listViewModel,
                activeDatabaseViewModel: $activeDatabaseViewModel
            )
        }
        #else
        AppRootView(
            listViewModel: listViewModel,
            activeDatabaseViewModel: $activeDatabaseViewModel
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
        // Bindings read live @State storage, so these closures always see the
        // currently active database session.
        let activeViewModel = $activeDatabaseViewModel
        let listViewModel = self.listViewModel

        macLockMonitor.onLockTriggered = { _ in
            activeViewModel.wrappedValue?.handleSceneDidEnterBackground()
        }
        macLockMonitor.onDidBecomeActive = {
            activeViewModel.wrappedValue?.didManuallyLock = false
            activeViewModel.wrappedValue?.handleSceneDidBecomeActive()
            activeViewModel.wrappedValue?.refreshSharedDatabaseCacheIfPossible()
            Task {
                await listViewModel.drainPendingUploadsOnAppActive()
            }
        }
        macLockMonitor.onUserActivity = {
            // Only meaningful while a vault is open; resetInactivityTimer()
            // already no-ops in every other state.
            activeViewModel.wrappedValue?.resetInactivityTimer()
        }
        macLockMonitor.start()
        #endif
    }

    private var appearanceMode: SettingsService.AppearanceMode {
        SettingsService.AppearanceMode(rawValue: appearanceModeRaw) ?? .system
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

/// An incoming `otpauth://` enrollment waiting for its destination sheet.
/// A wrapper rather than a bare `OTPAuthURI` so `sheet(item:)` has an
/// `Identifiable` to key on.
private struct PendingTOTPEnrollment: Identifiable {
    /// A parked plaintext secret must not outlive the moment the user still
    /// remembers asking for it: after this window it is discarded instead of
    /// auto-presenting against whatever database unlocks much later.
    static let lifetime: TimeInterval = 5 * 60

    let id = UUID()
    let uri: OTPAuthURI
    let createdAt = Date()

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.lifetime
    }
}

private enum TOTPEnrollmentAlert: String, Identifiable {
    case unsupportedLink
    case invalidLink
    case unlockNeeded
    case linkExpired

    var id: String { rawValue }
}

private struct AppRootView: View {
    @Bindable var listViewModel: DatabaseListViewModel
    @Binding var activeDatabaseViewModel: DatabaseViewModel?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @Environment(\.requestReview) private var requestReview
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var didResolveInitialRoute = false
    @State private var whatsNewRelease: WhatsNewRelease?
    @State private var pendingAutoOpenReference: DatabaseReference?
    /// SwiftUI drops a sheet or an alert raised in the same update that
    /// dismisses another presentation — the compact unlock sheet closing on
    /// `.unlocked`, or the What's New sheet's own `onDismiss`. Anything the
    /// enrollment flow raises from those moments waits out the outgoing
    /// dismissal first.
    private static let enrollmentPresentationDelay = Duration.milliseconds(450)

    /// Enrollment parked until a session unlocks (or the What's New sheet
    /// closes); promoted to `presentedTOTPEnrollment` by the state `onChange`
    /// below, or discarded once it expires. It stays parked until the sheet
    /// reports itself on screen, so a dropped presentation still has something
    /// to resume from.
    @State private var pendingTOTPEnrollment: PendingTOTPEnrollment?
    @State private var presentedTOTPEnrollment: PendingTOTPEnrollment?
    @State private var totpEnrollmentAlert: TOTPEnrollmentAlert?

    var body: some View {
        Group {
            if !didResolveInitialRoute {
                LaunchRoutingView()
            } else {
                rootContent
            }
        }
        .task {
            // The list view model owns the AutoFill toggle but only this root
            // knows the active session, so it installs the bridge. The binding
            // reads live @State, so the closure always sees the current
            // session (same pattern as startMacLockMonitoringIfNeeded).
            let activeViewModel = $activeDatabaseViewModel
            listViewModel.autoFillEnabledRefreshHandler = { databaseID in
                guard let databaseViewModel = activeViewModel.wrappedValue,
                      databaseViewModel.databaseReference.id == databaseID else { return }
                databaseViewModel.populateCredentialStoreIfUnlocked()
            }
            #if os(macOS)
            // macOS has no scene-based StoreKit review entry point; inject the
            // SwiftUI RequestReviewAction so ReviewPromptService can present the
            // modern prompt without a view dependency.
            ReviewPromptService.requestReviewHandler = { requestReview() }
            #endif
            await resolveInitialExperienceIfNeeded()
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .sheet(item: $whatsNewRelease, onDismiss: finishWhatsNewPresentation) { release in
            WhatsNewView(release: release)
                #if os(macOS)
                .frame(
                    minWidth: 520,
                    idealWidth: 560,
                    maxWidth: 640,
                    minHeight: 500,
                    maxHeight: MacSheetMetrics.maxHeight
                )
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(item: $presentedTOTPEnrollment) { enrollment in
            // The session is re-read at presentation time; when it vanished in
            // between (locked or closed), the `onChange` below re-parks.
            if let activeDatabaseViewModel {
                TOTPEnrollmentDestinationView(
                    databaseViewModel: activeDatabaseViewModel,
                    uri: enrollment.uri
                ) {
                    presentedTOTPEnrollment = nil
                    pendingTOTPEnrollment = nil
                }
                // The parked copy is only released once the sheet is actually
                // on screen; until then it is the retry path.
                .onAppear { pendingTOTPEnrollment = nil }
                // Rebuild the content when either the enrollment or the
                // session changes under the open sheet (a second otpauth URL,
                // or a swap to another unlocked database): the content
                // snapshots its view model in @State at init and would
                // otherwise keep enrolling the old secret into the old
                // database.
                .id("\(enrollment.id)-\(activeDatabaseViewModel.databaseReference.id)")
                #if os(macOS)
                .macSheetFrame()
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
        .onChange(of: activeDatabaseViewModel?.state) { _, newState in
            if newState == .unlocked {
                promoteParkedTOTPEnrollment()
            } else if let presentedTOTPEnrollment {
                // Locking or closing the database mid-flow tears the sheet's
                // data out from under it; park the enrollment again (original
                // creation date intact) so re-unlocking within its lifetime
                // resumes the flow instead of losing the code.
                pendingTOTPEnrollment = presentedTOTPEnrollment
                self.presentedTOTPEnrollment = nil
            }
        }
        .onChange(of: scenePhase) { _, _ in
            discardExpiredTOTPEnrollment()
        }
        .onChange(of: listViewModel.databases.map(\.id)) { _, identifiers in
            // The split layout keeps the sidebar list live next to the detail
            // column, so a database can be removed while its own session is
            // the one on screen. Drop the session with it.
            guard let activeID = activeDatabaseViewModel?.databaseReference.id,
                  identifiers.contains(activeID) == false else { return }
            activeDatabaseViewModel = nil
        }
        .alert(item: $totpEnrollmentAlert, content: totpEnrollmentAlertContent)
    }

    /// Moves a parked enrollment onto the destination sheet once a session is
    /// unlocked. The presentation is handed to a later turn because the same
    /// `.unlocked` transition dismisses `CompactDatabaseHost`'s unlock sheet,
    /// and the parked copy is left in place so a dropped presentation is not
    /// the end of the incoming code.
    private func promoteParkedTOTPEnrollment() {
        guard discardExpiredTOTPEnrollment() == false, pendingTOTPEnrollment != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.enrollmentPresentationDelay)
            guard let enrollment = pendingTOTPEnrollment,
                  enrollment.isExpired == false,
                  activeDatabaseViewModel?.state == .unlocked else { return }
            presentedTOTPEnrollment = enrollment
        }
    }

    /// Drops a parked enrollment that outlived `PendingTOTPEnrollment.lifetime`
    /// and says so. Vanishing silently after telling the user to unlock a
    /// database reads as the app losing their code.
    @discardableResult
    private func discardExpiredTOTPEnrollment() -> Bool {
        guard pendingTOTPEnrollment?.isExpired == true else { return false }
        pendingTOTPEnrollment = nil
        requestTOTPEnrollmentAlert(.linkExpired)
        return true
    }

    private func requestTOTPEnrollmentAlert(_ alert: TOTPEnrollmentAlert) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.enrollmentPresentationDelay)
            totpEnrollmentAlert = alert
        }
    }

    private func totpEnrollmentAlertContent(for alert: TOTPEnrollmentAlert) -> Alert {
        switch alert {
        case .unsupportedLink:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("This setup link uses an unsupported code type. Only time-based (TOTP) codes are supported."),
                dismissButton: .default(Text("OK"))
            )
        case .invalidLink:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("The verification code setup link is invalid or incomplete."),
                dismissButton: .default(Text("OK"))
            )
        case .unlockNeeded:
            Alert(
                title: Text("Unlock a Database"),
                message: Text("Open and unlock a database, and KeeForge will then add the verification code."),
                dismissButton: .default(Text("OK"))
            )
        case .linkExpired:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("This setup link expired. Open it again from the service to add the verification code."),
                dismissButton: .default(Text("OK"))
            )
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
                        selectedDatabaseID: activeDatabaseViewModel?.databaseReference.id,
                        isSidebarColumn: true
                    )
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
                } detail: {
                    Group {
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
                    #if os(iOS)
                    .appSettingsToolbarButton()
                    #endif
                }
                .navigationSplitViewStyle(.balanced)
                #if os(macOS)
                // Window title stays "KeeForge" until a database is unlocked;
                // the unlocked workspace sets the title to the database name.
                .navigationTitle("KeeForge")
                #endif
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
        // `\.horizontalSizeClass` does not exist on macOS; the Mac app always
        // uses the regular (split-view) layout.
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    private func resolveInitialExperienceIfNeeded() async {
        guard didResolveInitialRoute == false else { return }
        defer { didResolveInitialRoute = true }

        guard activeDatabaseViewModel == nil else { return }

        let release = WhatsNewPresentationService.releaseToPresent()
        let databaseReference = listViewModel.databaseToAutoOpenOnLaunch()

        if let release {
            // Keep the database list behind the release notes. In particular,
            // defer Quick Launch so its unlock sheet cannot compete with the
            // app-level What's New sheet.
            pendingAutoOpenReference = databaseReference
            whatsNewRelease = release
        } else if let databaseReference {
            openDatabase(databaseReference)
        }
    }

    private func openDatabase(_ reference: DatabaseReference) {
        activeDatabaseViewModel = DatabaseViewModel(databaseReference: reference)
    }

    private func openDatabaseAfterLaunchPresentation(_ reference: DatabaseReference) {
        if whatsNewRelease == nil {
            openDatabase(reference)
        } else {
            // An explicit deep link takes precedence over any Quick Launch
            // route that was waiting for the sheet to close.
            pendingAutoOpenReference = reference
        }
    }

    private func finishWhatsNewPresentation() {
        if let pendingAutoOpenReference {
            self.pendingAutoOpenReference = nil
            openDatabase(pendingAutoOpenReference)
        }

        // Everything below runs from the sheet's `onDismiss`, so both the
        // enrollment sheet and the alert are deferred past that dismissal.
        guard discardExpiredTOTPEnrollment() == false, pendingTOTPEnrollment != nil else { return }
        if activeDatabaseViewModel?.state == .unlocked {
            promoteParkedTOTPEnrollment()
        } else {
            // Stays parked; the state `onChange` promotes it on unlock.
            requestTOTPEnrollmentAlert(.unlockNeeded)
        }
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

        if OTPAuthURI.isOTPAuthURL(url) {
            handleOTPAuthURL(url)
            return
        }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            openDatabaseAfterLaunchPresentation(reference)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            if let existing = listViewModel.databases.first(where: { $0.id == existingReferenceID }) {
                openDatabaseAfterLaunchPresentation(existing)
            }
        } catch {
            if let existing = listViewModel.databases.first(where: {
                $0.filename == url.lastPathComponent
            }) {
                openDatabaseAfterLaunchPresentation(existing)
            }
        }
    }

    private func handleOTPAuthURL(_ url: URL) {
        let enrollment: PendingTOTPEnrollment
        do {
            enrollment = PendingTOTPEnrollment(uri: try OTPAuthURI(string: url.absoluteString))
        } catch OTPAuthURIError.unsupportedType {
            totpEnrollmentAlert = .unsupportedLink
            return
        } catch {
            totpEnrollmentAlert = .invalidLink
            return
        }

        if whatsNewRelease != nil {
            // The What's New sheet is up (post-update cold launch); a
            // competing presentation would be silently dropped by SwiftUI.
            // Park the enrollment — no alert either — and let
            // finishWhatsNewPresentation promote it (the same deferred
            // deep-link pattern as openDatabaseAfterLaunchPresentation).
            pendingTOTPEnrollment = enrollment
        } else if let activeDatabaseViewModel, activeDatabaseViewModel.state == .unlocked {
            presentedTOTPEnrollment = enrollment
        } else {
            pendingTOTPEnrollment = enrollment
            totpEnrollmentAlert = .unlockNeeded
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
                #if os(iOS)
                // Manual locks only. An automatic lock can fire as the app is
                // being backgrounded, and a snapshot added at that moment is
                // exactly what iOS would capture for the app switcher — the
                // one place vault content must never survive. Those locks keep
                // the instant cut and `ScreenProtectionService`'s shield.
                if viewModel.didManuallyLock {
                    VaultCloseTransition.coverCurrentFrame()
                }
                #endif
                onReturnToList()
            }
        }
    }
}

private struct CompactUnlockScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if viewModel.isEligibleForBiometricAutoUnlock {
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
        .biometricAutoUnlock(viewModel)
    }
}

private struct RegularDatabaseScene: View {
    @Bindable var viewModel: DatabaseViewModel
    let onReturnToList: () -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .locked:
                if viewModel.isEligibleForBiometricAutoUnlock {
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
        .biometricAutoUnlock(viewModel)
    }
}

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
    @State private var attemptedLockCycle: Int?

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
        guard attemptedLockCycle != viewModel.lockCycleID else { return }

        attemptedLockCycle = viewModel.lockCycleID

        Task {
            if await viewModel.unlockWithBiometrics() == .promptUnavailable {
                // Nothing was presented, so this lock cycle keeps its attempt.
                attemptedLockCycle = nil
            }
        }
    }
}

private extension View {
    func biometricAutoUnlock(_ viewModel: DatabaseViewModel) -> some View {
        modifier(BiometricAutoUnlockModifier(viewModel: viewModel))
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
    @State private var isCloudReconnectInFlight = false

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
            .navigationDestination(for: TagDestination.self) { destination in
                switch destination {
                case .allTags:
                    TagListView(viewModel: viewModel)
                case .entries(let tag):
                    TagEntriesView(tag: tag, viewModel: viewModel)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if viewModel.saveError?.isWriteScopeRequired == true {
                        CloudReauthBanner(
                            providerName: viewModel.databaseReference.cloudProviderKind?.displayName ?? "cloud",
                            isReconnectInFlight: isCloudReconnectInFlight,
                            onReconnect: beginCloudReconnect
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
                get: { viewModel.pendingLockRequest?.reason == .draft },
                set: { _ in }
            )
        ) {
            if viewModel.isReadOnly == false {
                Button("Retry Save and Lock") {
                    Task { await viewModel.saveAndLockAfterLockRequest() }
                }
            }
            Button("Lock and Discard", role: .destructive) {
                let manuallyTriggered = viewModel.pendingLockRequest?.manuallyTriggered ?? false
                viewModel.lockRequest(force: true, manuallyTriggered: manuallyTriggered)
            }
            Button("Keep Editing", role: .cancel) {
                Task {
                    await viewModel.continueEditingAfterLockRequest()
                }
            }
        } message: {
            Text("Your unsaved entry changes will be lost.")
        }
    }

    @MainActor
    private func beginCloudReconnect() {
        guard isCloudReconnectInFlight == false else { return }
        guard let providerID = viewModel.databaseReference.cloudSyncMetadata?.provider,
              let provider = CloudProviderRegistry.provider(for: providerID) else {
            viewModel.presentSaveError(CloudProviderError.invalidConfiguration)
            return
        }

        isCloudReconnectInFlight = true
        Task { @MainActor in
            defer { isCloudReconnectInFlight = false }

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
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
        #else
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #endif
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
    let providerName: String
    let isReconnectInFlight: Bool
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reconnect \(providerName) to save changes.")
                .font(.subheadline.weight(.semibold))
            Button("Reconnect \(providerName)", action: onReconnect)
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

struct CloudSyncWarningButton: View {
    let message: String
    @State private var isShowingDetails = false

    private var explanation: String {
        String(localized: "\(message)\n\nKeeForge opened the cached copy for now. Cloud sync needs attention before this database can be refreshed from its provider.")
    }

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.yellow)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cloud sync warning")
        .accessibilityValue(message)
        .accessibilityHint("Shows why this database needs attention")
        .accessibilityIdentifier("database.cloud-sync-warning")
        .alert("Cloud Sync Needs Attention", isPresented: $isShowingDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(explanation)
        }
    }
}
