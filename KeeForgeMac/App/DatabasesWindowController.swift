import AppKit
import SwiftUI

/// The Databases window: the list of known databases and the app-level launch
/// presentations. It never shows a database's contents.
@MainActor
final class DatabasesWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("databases")
    static let contentSize = NSSize(width: 600, height: 620)

    init(coordinator: MacWindowCoordinator) {
        let hosting = NSHostingController(rootView: MacDatabasesLauncherRoot(coordinator: coordinator)
            .modifier(MacHostingAppearance()))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = DatabasesWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Databases")
        window.identifier = Self.identifier
        window.setAccessibilityIdentifier(Self.identifier.rawValue)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = Self.contentSize
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class DatabasesWindow: NSWindow {
    // Hosting resets this during layout; reused sheets need the full 560-point height.
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = DatabasesWindowController.contentSize }
    }
}

private struct MacDatabasesLauncherRoot: View {
    let coordinator: MacWindowCoordinator

    var body: some View {
        #if DEBUG
        if AutoFillStoreInspectorView.isPresentationRequested {
            AutoFillStoreInspectorView()
        } else if AutoFillPickerHarnessView.isPresentationRequested {
            AutoFillPickerHarnessView()
        } else {
            launcher
        }
        #else
        launcher
        #endif
    }

    private var launcher: some View {
        MacDatabasesLauncherView(coordinator: coordinator, launcher: coordinator.launcher,
            routing: coordinator.routing, enrollment: coordinator.enrollment)
    }
}

struct MacDatabasesLauncherView: View {
    let coordinator: MacWindowCoordinator
    @Bindable var launcher: MacDatabasesLauncherViewModel
    let routing: MacApplicationRouting
    @Bindable var enrollment: TOTPEnrollmentCoordinator

    var body: some View {
        DatabaseListView(
            viewModel: coordinator.listViewModel,
            onSelectDatabase: launcher.open,
            onCreateDatabase: launcher.didCreate,
            launcher: launcher
        )
        .sheet(isPresented: launchPresentation(.transitionNotice)) {
            MacTransitionNoticeView()
                .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 500, maxHeight: MacSheetMetrics.maxHeight)
        }
        .sheet(isPresented: launchPresentation(.whatsNew)) {
            if let release = launcher.whatsNewRelease {
                WhatsNewView(release: release)
                    .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 500, maxHeight: MacSheetMetrics.maxHeight)
            }
        }
        .sheet(isPresented: choosingEnrollmentDestination) {
            MacEnrollmentDestinationChooser(launcher: launcher)
        }
        .alert(item: enrollmentAlert) { $0.alertContent }
    }

    private func launchPresentation(_ presentation: MacApplicationRouting.LaunchPresentation) -> Binding<Bool> {
        Binding(
            get: { routing.launchPresentation == presentation },
            set: { if !$0 { coordinator.finishLaunchPresentation(presentation) } }
        )
    }

    /// Waits for the launch presentations, so two sheets never compete.
    private var choosingEnrollmentDestination: Binding<Bool> {
        Binding(
            get: { launcher.isChoosingEnrollmentDestination && routing.launchPresentation == nil },
            set: { if !$0 { launcher.cancelEnrollmentDestination() } }
        )
    }

    private var enrollmentAlert: Binding<TOTPEnrollmentAlert?> {
        Binding(
            get: { coordinator.launcherHostsEnrollmentAlert ? enrollment.enrollmentAlert : nil },
            set: { if $0 == nil, coordinator.launcherHostsEnrollmentAlert { enrollment.enrollmentAlert = nil } }
        )
    }
}

/// Asks which database a verification-code link without a target window belongs to.
private struct MacEnrollmentDestinationChooser: View {
    let launcher: MacDatabasesLauncherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Verification Code")
                .font(.headline)
            Text("Choose the database to add the verification code to.")
                .foregroundStyle(.secondary)
            List(launcher.enrollmentCandidates) { reference in
                Button {
                    launcher.chooseEnrollmentDestination(reference.id)
                } label: {
                    Text(reference.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("databases.enrollment-destination.row")
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    launcher.cancelEnrollmentDestination()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("databases.enrollment-destination.cancel")
            }
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }
}
