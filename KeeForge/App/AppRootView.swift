#if os(iOS)
import StoreKit
import SwiftUI

struct AppRootView: View {
    @Bindable var listViewModel: DatabaseListViewModel
    let sessionStore: DatabaseSessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let routing: AppRoutingCoordinator
    /// The layout on screen. It trails the size class by one update so the
    /// workspace is carried over before the other layout is built.
    @State private var appliedRegularLayout: Bool?

    var body: some View {
        @Bindable var routing = routing
        @Bindable var enrollmentCoordinator = routing.enrollment
        Group {
            if !routing.didResolveInitialRoute {
                LaunchRoutingView()
            } else {
                rootContent
            }
        }
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
        .task {
            await resolveInitialExperienceIfNeeded()
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .sheet(item: $routing.whatsNewRelease, onDismiss: finishWhatsNewPresentation) { release in
            WhatsNewView(release: release)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: enrollmentPresentation) { enrollment in
            // The session is re-read at presentation time; when it vanished in
            // between (locked or closed), the `onChange` below re-parks.
            if let activeSession = sessionStore.activeSession,
               let enrollmentSession = routingSession,
               routing.enrollment.canApplyEnrollment(id: enrollment.id, session: enrollmentSession) {
                TOTPEnrollmentDestinationView(
                    databaseViewModel: activeSession,
                    uri: enrollment.uri
                ) {
                    routing.enrollment.updateSession(routingSession)
                    routing.enrollment.cancelEnrollment(
                        id: enrollment.id,
                        session: enrollmentSession
                    )
                }
                // The parked copy is only released once the sheet is actually
                // on screen; until then it is the retry path.
                .onAppear {
                    routing.enrollment.updateSession(routingSession)
                    routing.enrollment.enrollmentDidAppear(
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: routingSession, initial: true) { _, session in
            routing.enrollment.updateSession(session)
        }
        .onChange(of: routing.databaseTransition?.id, initial: true) { _, _ in
            finishDatabaseTransitionIfReady()
        }
        .onChange(of: databaseTransitionState) { _, _ in
            finishDatabaseTransitionIfReady()
        }
        .task(id: routing.enrollment.deferredPresentation?.id) {
            guard let requestID = routing.enrollment.deferredPresentation?.id else { return }
            // SwiftUI drops presentations raised during another sheet's dismissal.
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            routing.enrollment.completeDeferredPresentation(id: requestID)
        }
        .onChange(of: scenePhase) { _, _ in
            routing.enrollment.discardExpiredEnrollment()
        }
        .alert(item: $enrollmentCoordinator.enrollmentAlert) { $0.alertContent }
    }

    private var routingSession: TOTPEnrollmentCoordinator.Session? {
        sessionStore.activeSession.map {
            TOTPEnrollmentCoordinator.Session(
                databaseID: $0.databaseReference.id, identity: ObjectIdentifier($0), lockCycleID: $0.lockCycleID, isUnlocked: $0.state == .unlocked
            )
        }
    }

    private var databaseTransitionState: AppRoutingCoordinator.DatabaseTransitionState? {
        sessionStore.activeSession.map(AppRoutingCoordinator.DatabaseTransitionState.init)
    }

    private var enrollmentPresentation: Binding<PendingTOTPEnrollment?> {
        let enrollmentID = routing.enrollment.presentedEnrollment?.id
        let session = routingSession
        return Binding(
            get: { routing.enrollment.presentedEnrollment },
            set: { enrollment in
                guard enrollment == nil, let enrollmentID else { return }
                routing.enrollment.updateSession(routingSession)
                routing.enrollment.cancelEnrollment(id: enrollmentID, session: session)
            }
        )
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesRegularLayout {
            if let activeSession = sessionStore.activeSession, case .unlocked = activeSession.state {
                RegularDatabaseWorkspaceView(viewModel: activeSession)
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
                    .appSettingsToolbarButton()
                }
                .navigationSplitViewStyle(.balanced)
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
        appliedRegularLayout ?? (horizontalSizeClass == .regular)
    }

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

    private func resolveInitialExperienceIfNeeded() async {
        guard !routing.didResolveInitialRoute else { return }
        let mayAutoOpen = sessionStore.activeSession == nil
        if let reference = routing.resolveInitialRoute(
            hasActiveSession: sessionStore.activeSession != nil,
            showsTransitionNotice: false,
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
        routing.enrollment.updateSession(routingSession)
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
        routing.enrollment.updateSession(routingSession)
        routing.enrollment.resumeEnrollmentAfterLaunchPresentation()
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

    private func handleOpenURL(_ url: URL) {
        if CloudProviderRegistry.handleOpenURL(url) {
            return
        }

        routing.enrollment.updateSession(routingSession)
        switch AppRoutingCoordinator.classify(url) {
        case .enrollment(let uri):
            routing.enrollment.receiveEnrollment(uri, destination: routingSession)
            return
        case .invalidEnrollment(let alert):
            routing.enrollment.enrollmentAlert = alert
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
#endif
