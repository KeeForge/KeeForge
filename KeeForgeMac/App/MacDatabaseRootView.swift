import SwiftUI

/// What the locked pages ask their window for.
struct MacLockedWindowActions {
    /// Escape on the unlock form: closes the window and shows the Databases window.
    var close: @MainActor () -> Void = {}
    var reconnect: @MainActor () -> Void = {}
    var removeFromList: @MainActor () -> Void = {}
}

/// The stable root of one database window: that session's unlock, opening,
/// recovery and unlocked content, its automatic unlock, and enrollment sheets
/// bound to this database. Mounted for the controller's whole life, so a
/// lock or unlock never drops a sheet.
struct MacDatabaseRootView: View {
    @Bindable var session: DatabaseViewModel
    let enrollment: TOTPEnrollmentCoordinator
    let unlockForm: MacUnlockFormModel
    let actions: MacLockedWindowActions
    @Environment(MacWorkspacePresentation.self) private var presentation

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: session.state)
            // Above the state switch: mounting counts as opening and may prompt.
            .background { MacBiometricAutoUnlockObserver(viewModel: session) }
            .modifier(MacEnrollmentPresentation(session: session, enrollment: enrollment))
            .modifier(MacServerCredentialSheet(prompt: presentation.serverCredentialPrompt))
    }

    @ViewBuilder private var content: some View {
        if let page = MacDatabaseOpenPage.make(for: session) {
            lockedPage(page)
                .transition(.opacity)
        } else {
            MacDatabaseWorkspaceView(viewModel: session, presentation: presentation)
                .transition(.opacity)
        }
    }

    @ViewBuilder private func lockedPage(_ page: MacDatabaseOpenPage) -> some View {
        let summary = MacLockedDatabaseSummary(reference: session.databaseReference,
            lastOpened: DatabaseListViewModel.lastOpenedDescription(for: session.databaseReference))
        switch page {
        case .form(let card, let footer):
            MacUnlockView(session: session, form: unlockForm, summary: summary, card: card, footer: footer,
                          onClose: actions.close)
        case .opening(let opening):
            MacDatabaseOpeningView(summary: summary, opening: opening, onCancel: { _ = session.cancelUnlockAttempt() })
        case .recovery(let recovery):
            MacDatabaseRecoveryView(session: session, form: unlockForm, page: recovery,
                                    onReconnect: actions.reconnect, onRemoveFromList: actions.removeFromList)
        case .unavailable:
            MacDatabaseUnavailableView(summary: summary)
        }
    }
}

/// Reconnect's Connect to Server form as a sheet on this database's window.
private struct MacServerCredentialSheet: ViewModifier {
    @Bindable var prompt: MacServerCredentialPrompt

    func body(content: Content) -> some View {
        content.sheet(item: request) { request in
            switch request.form {
            case .webDAV(let form):
                WebDAVConnectView(viewModel: form, onConnected: { _ in prompt.finish(connected: true) },
                                  onCancel: { prompt.finish(connected: false) })
            case .ftp(let form):
                FTPConnectView(viewModel: form, onConnected: { _ in prompt.finish(connected: true) },
                               onCancel: { prompt.finish(connected: false) })
            }
        }
    }

    private var request: Binding<MacServerCredentialPrompt.Request?> {
        Binding(get: { prompt.request }, set: { if $0 == nil { prompt.finish(connected: false) } })
    }
}

/// Presents a verification-code enrollment only in the window of the database
/// it was bound to; focus changes never retarget it.
private struct MacEnrollmentPresentation: ViewModifier {
    let session: DatabaseViewModel
    @Bindable var enrollment: TOTPEnrollmentCoordinator

    private var routingSession: TOTPEnrollmentCoordinator.Session {
        MacWindowCoordinator.enrollmentSession(for: session)
    }

    private var isDestination: Bool {
        enrollment.destinationDatabaseID == session.databaseReference.id
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: presentedEnrollment) { pending in
                if enrollment.canApplyEnrollment(id: pending.id, session: routingSession) {
                    TOTPEnrollmentDestinationView(
                        databaseViewModel: session, uri: pending.uri,
                        onFinished: { enrollment.cancelEnrollment(id: pending.id, session: routingSession) },
                        onEditorOpened: { enrollment.handOffToEditor(id: pending.id, session: routingSession) },
                        onEditorFinished: {
                            enrollment.editorFinished(id: pending.id, completion: $0, session: routingSession)
                        }
                    )
                    .onAppear { enrollment.enrollmentDidAppear(id: pending.id, session: routingSession) }
                    .id("\(pending.id)-\(session.lockCycleID)")
                    .macSheetFrame()
                }
            }
            .onChange(of: routingSession, initial: true) { _, newSession in
                guard isDestination else { return }
                enrollment.updateSession(newSession)
            }
            .alert(item: alert) { $0.alertContent }
    }

    private var presentedEnrollment: Binding<PendingTOTPEnrollment?> {
        Binding(
            get: { isDestination ? enrollment.presentedEnrollment : nil },
            set: { newValue in
                guard newValue == nil, isDestination, let id = enrollment.presentedEnrollment?.id else { return }
                enrollment.cancelEnrollment(id: id, session: routingSession)
            }
        )
    }

    private var alert: Binding<TOTPEnrollmentAlert?> {
        Binding(
            get: { isDestination ? enrollment.enrollmentAlert : nil },
            set: { if $0 == nil, isDestination { enrollment.enrollmentAlert = nil } }
        )
    }
}
