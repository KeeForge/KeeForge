import SwiftUI

/// The stable root of one database window: that session's unlock, opening,
/// error and unlocked content, its automatic unlock, and enrollment sheets
/// bound to this database. Mounted for the controller's whole life, so a
/// lock or unlock never drops a sheet.
struct MacDatabaseRootView: View {
    @Bindable var session: DatabaseViewModel
    let enrollment: TOTPEnrollmentCoordinator
    let onClose: () -> Void
    @Environment(MacWorkspacePresentation.self) private var presentation

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: session.state)
            // Above the state switch: mounting counts as opening and may prompt.
            .background { MacBiometricAutoUnlockObserver(viewModel: session) }
            .modifier(MacEnrollmentPresentation(session: session, enrollment: enrollment))
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .locked, .error:
            UnlockView(viewModel: session, onBackToDatabaseList: onClose, showsChooseDifferentFileAction: false)
                .transition(.opacity)
        case .unlocking:
            DatabaseOpeningView(viewModel: session, onCancel: hardwareKeyCancelAction(for: session))
                .transition(.opacity)
        case .unlocked:
            MacDatabaseWorkspaceView(viewModel: session, presentation: presentation)
                .transition(.opacity)
        }
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
                    TOTPEnrollmentDestinationView(databaseViewModel: session, uri: pending.uri) {
                        enrollment.cancelEnrollment(id: pending.id, session: routingSession)
                    }
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
