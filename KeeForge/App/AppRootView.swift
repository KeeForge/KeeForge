import StoreKit
import SwiftUI

#if os(macOS)
/// Keeps the menu bar quick search on the app's active session, and lets it
/// hand off changes to the SSH agent. AppDelegate owns window reopening.
struct MacQuickAccessMainWindowHookup: ViewModifier {
    let controller: MacQuickAccessController
    let sshAgent: MacSSHAgentController
    let activeSession: DatabaseViewModel?

    func body(content: Content) -> some View {
        content
            .background(MacWindowReader { window in
                if let window { controller.mainWindow = window }
            })
            .onChange(of: activeSession.map(ObjectIdentifier.init), initial: true) {
                controller.activeSession = activeSession
                sshAgent.activeSessionDidChange()
            }
    }
}
#endif

struct AppRootView: View {
    @Bindable var listViewModel: DatabaseListViewModel
    let sessionStore: DatabaseSessionStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    #endif
    let routing: AppRoutingCoordinator
    var onReadyForURLs: (() -> Void)? = nil
    #if os(macOS)
    @State private var showsMacTransitionNotice = false
    #else
    /// The layout on screen. It trails the size class by one update so the
    /// workspace is carried over before the other layout is built.
    @State private var appliedRegularLayout: Bool?
    #endif

    var body: some View {
        @Bindable var routing = routing
        Group {
            if !routing.didResolveInitialRoute {
                LaunchRoutingView()
            } else {
                rootContent
            }
        }
        #if os(iOS)
        .environment(\.horizontalSizeClass, usesRegularLayout ? .regular : .compact)
        .onAppear {
            appliedRegularLayout = horizontalSizeClass == .regular
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            applyLayout(regular: newValue == .regular)
        }
        .overlay(alignment: .top) {
            if Self.showsLayoutSwitchForUITests {
                Button { applyLayout(regular: !usesRegularLayout) } label: {
                    Text(verbatim: "Switch Layout").font(.caption2)
                }
                .accessibilityIdentifier("ui-testing.switch-layout")
            }
        }
        #endif
        .task {
            let sessionStore = self.sessionStore
            listViewModel.autoFillEnabledRefreshHandler = { databaseID in
                sessionStore.session(for: databaseID)?.populateCredentialStoreIfUnlocked()
            }
            await resolveInitialExperienceIfNeeded()
            onReadyForURLs?()
        }
        #if os(iOS)
        .onOpenURL { url in
            handleOpenURL(url)
        }
        #endif
        #if os(macOS)
        // Above the locked/unlocked switch: a lock must not remount it, since
        // mounting counts as opening the session and prompts.
        .background {
            if let activeSession = sessionStore.activeSession {
                MacBiometricAutoUnlockObserver(viewModel: activeSession)
                    .id(ObjectIdentifier(activeSession))
            }
        }
        .sheet(isPresented: $showsMacTransitionNotice) {
            MacTransitionNoticeView()
                .frame(
                    minWidth: 520,
                    idealWidth: 560,
                    maxWidth: 640,
                    minHeight: 500,
                    maxHeight: MacSheetMetrics.maxHeight
                )
        }
        #endif
        .sheet(item: $routing.whatsNewRelease, onDismiss: finishWhatsNewPresentation) { release in
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
        .sheet(item: enrollmentPresentation) { enrollment in
            // The session is re-read at presentation time; when it vanished in
            // between (locked or closed), the `onChange` below re-parks.
            if let activeSession = sessionStore.activeSession {
                let enrollmentSession = AppRoutingCoordinator.Session(
                    identity: ObjectIdentifier(activeSession),
                    lockCycleID: activeSession.lockCycleID,
                    isUnlocked: activeSession.state == .unlocked
                )
                TOTPEnrollmentDestinationView(
                    databaseViewModel: activeSession,
                    uri: enrollment.uri
                ) {
                    routing.updateSession(routingSession)
                    routing.cancelEnrollment(
                        id: enrollment.id,
                        session: enrollmentSession
                    )
                }
                // The parked copy is only released once the sheet is actually
                // on screen; until then it is the retry path.
                .onAppear {
                    routing.updateSession(routingSession)
                    routing.enrollmentDidAppear(
                        id: enrollment.id,
                        session: enrollmentSession
                    )
                }
                // Rebuild the content when either the enrollment or the
                // session changes under the open sheet (a second otpauth URL,
                // or a swap to another unlocked database): the content
                // snapshots its view model in @State at init and would
                // otherwise keep enrolling the old secret into the old
                // database.
                .id("\(enrollment.id)-\(enrollmentSession.identity)-\(enrollmentSession.lockCycleID)")
                #if os(macOS)
                .macSheetFrame()
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
        .onChange(of: routingSession, initial: true) { _, session in
            routing.updateSession(session)
        }
        .onChange(of: routing.databaseTransition?.id, initial: true) { _, _ in
            finishDatabaseTransitionIfReady()
        }
        .onChange(of: databaseTransitionState) { _, _ in
            finishDatabaseTransitionIfReady()
        }
        .task(id: routing.deferredPresentation?.id) {
            guard let requestID = routing.deferredPresentation?.id else { return }
            // SwiftUI drops presentations raised during another sheet's dismissal.
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            routing.completeDeferredPresentation(id: requestID)
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, _ in
            routing.discardExpiredEnrollment()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            routing.discardExpiredEnrollment()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            routing.discardExpiredEnrollment()
        }
        #endif
        .onChange(of: listViewModel.databases.map(\.id)) { _, identifiers in
            sessionStore.retireSessionsMissingFromDatabaseList(identifiers)
        }
        .alert(item: $routing.enrollmentAlert, content: totpEnrollmentAlertContent)
    }

    private var routingSession: AppRoutingCoordinator.Session? {
        sessionStore.activeSession.map {
            AppRoutingCoordinator.Session(
                identity: ObjectIdentifier($0), lockCycleID: $0.lockCycleID, isUnlocked: $0.state == .unlocked
            )
        }
    }

    private var databaseTransitionState: AppRoutingCoordinator.DatabaseTransitionState? {
        sessionStore.activeSession.map(AppRoutingCoordinator.DatabaseTransitionState.init)
    }

    private var enrollmentPresentation: Binding<PendingTOTPEnrollment?> {
        let enrollmentID = routing.presentedEnrollment?.id
        let session = routingSession
        return Binding(
            get: { routing.presentedEnrollment },
            set: { enrollment in
                guard enrollment == nil, let enrollmentID else { return }
                routing.updateSession(routingSession)
                routing.cancelEnrollment(id: enrollmentID, session: session)
            }
        )
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
            if let activeSession = sessionStore.activeSession, case .unlocked = activeSession.state {
                RegularDatabaseWorkspaceView(viewModel: activeSession)
                    #if os(macOS)
                    .id(ObjectIdentifier(activeSession))
                    #endif
            } else {
                NavigationSplitView {
                    DatabaseListView(
                        viewModel: listViewModel,
                        onSelectDatabase: openDatabase,
                        onCreateDatabase: openCreatedDatabase,
                        selectedDatabaseID: sessionStore.activeSession?.databaseReference.id,
                        isSidebarColumn: true
                    )
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
                } detail: {
                    Group {
                        if let activeSession = sessionStore.activeSession {
                            RegularDatabaseScene(
                                viewModel: activeSession,
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
            if let activeSession = sessionStore.activeSession {
                CompactDatabaseHost(
                    listViewModel: listViewModel,
                    viewModel: activeSession,
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
        appliedRegularLayout ?? (horizontalSizeClass == .regular)
        #else
        true
        #endif
    }

    #if os(iOS)
    /// iPhone Duo opening or closing, or an iPad window resizing.
    private func applyLayout(regular: Bool) {
        guard regular != usesRegularLayout else { return }
        sessionStore.activeSession?.workspace.adaptNavigation(toRegularLayout: regular)
        appliedRegularLayout = regular
    }

    /// UI tests switch layouts with this control: no simulator can open or
    /// close an iPhone Duo from a test.
    private static let showsLayoutSwitchForUITests: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing") && arguments.contains("-ui-testing-layout-switch")
    }()
    #endif

    private func resolveInitialExperienceIfNeeded() async {
        guard !routing.didResolveInitialRoute else { return }
        var showsTransitionNotice = false
        #if os(macOS)
        if sessionStore.activeSession == nil {
            showsTransitionNotice = MacTransitionNoticeService.claimPresentation()
            showsMacTransitionNotice = showsTransitionNotice
        }
        #endif
        let mayAutoOpen = sessionStore.activeSession == nil && !showsTransitionNotice
        if let reference = routing.resolveInitialRoute(
            hasActiveSession: sessionStore.activeSession != nil,
            showsTransitionNotice: showsTransitionNotice,
            release: mayAutoOpen ? WhatsNewPresentationService.releaseToPresent() : nil,
            autoOpenReference: mayAutoOpen ? listViewModel.databaseToAutoOpenOnLaunch() : nil
        ) {
            openDatabase(reference)
        }
    }

    private func openDatabase(_ reference: DatabaseReference) {
        routing.requestDatabaseTransition(to: .open(reference), from: sessionStore.activeSession)
    }

    private func finishDatabaseTransitionIfReady() {
        guard let destination = routing.completeDatabaseTransition(from: sessionStore.activeSession) else { return }
        switch destination {
        case .open(let reference):
            if let id = sessionStore.activeSessionID {
                guard sessionStore.retire(id) else { return }
            }
            let session = sessionStore.open(reference)
            sessionStore.activeSessionID = session.databaseReference.id
        case .close:
            returnToDatabaseList()
        }
        routing.updateSession(routingSession)
    }

    private func openDatabaseAfterLaunchPresentation(_ reference: DatabaseReference) {
        if let reference = routing.requestDatabase(reference) {
            openDatabase(reference)
        }
    }

    private func finishWhatsNewPresentation() {
        if let reference = routing.finishLaunchPresentation() {
            openDatabase(reference)
        }
        routing.updateSession(routingSession)
        routing.resumeEnrollmentAfterLaunchPresentation()
    }

    private func openCreatedDatabase(_ createdDatabase: CreatedDatabase) {
        listViewModel.reload()
        if let id = sessionStore.activeSessionID {
            sessionStore.retire(id, force: true)
        }
        let session = sessionStore.adopt(DatabaseViewModel(createdDatabase: createdDatabase))
        sessionStore.activeSessionID = session.databaseReference.id
    }

    private func returnToDatabaseList() {
        if let id = sessionStore.activeSessionID {
            sessionStore.retire(id, force: true)
        }
        listViewModel.reload()
    }

    // Also called by the AppKit delegate; URL routing uses only the shared owners.
    func handleOpenURL(_ url: URL) {
        if CloudProviderRegistry.handleOpenURL(url) {
            return
        }

        routing.updateSession(routingSession)
        switch AppRoutingCoordinator.classify(url) {
        case .enrollment(let uri):
            routing.receiveEnrollment(uri)
            return
        case .invalidEnrollment(let alert):
            routing.enrollmentAlert = alert
            return
        case .database:
            break
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

