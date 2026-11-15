import AppKit
import SwiftUI

/// The Databases window: the launcher (`MacDatabasesLauncherViewController`)
/// and the app-level launch presentations. It never shows a database's contents.
@MainActor
final class DatabasesWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("databases")
    /// The board's 780 pt width; the height fits the brand panel's column and three database rows.
    /// A taller sheet grows the window (`DatabasesWindow.frame(fitting:)`).
    static let contentSize = NSSize(width: 780, height: 440)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    var onWillClose: (@MainActor () -> Void)?
    let launcherViewController: MacDatabasesLauncherViewController
    private var databaseSettingsSheets: MacDatabaseSettingsLauncherPresenter?
    private var closeObserver: NSObjectProtocol?
    private var sheets: MacDatabasesSheets?
    private var alerts: MacDatabasesAlerts?

    init(coordinator: MacWindowCoordinator) {
        launcherViewController = MacDatabasesLauncherViewController(launcher: coordinator.launcher)
        let hosting = NSHostingController(rootView: MacDatabasesLauncherRoot(coordinator: coordinator,
            content: launcherViewController)
            .modifier(MacHostingAppearance()))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        let window = DatabasesWindow(contentViewController: hosting)
        window.styleMask = Self.styleMask
        window.title = String(localized: "Databases")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.identifier = Self.identifier
        window.setAccessibilityIdentifier(Self.identifier.rawValue)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.restorationClass = nil
        // Window > Databases already names it; AppKit's own entry would list it twice.
        window.isExcludedFromWindowsMenu = true
        window.contentMinSize = Self.contentSize
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        databaseSettingsSheets = MacDatabaseSettingsLauncherPresenter(launcher: coordinator.launcher, list: coordinator.listViewModel, window: { [weak self] in self?.window })
        databaseSettingsSheets?.start()
        sheets = MacDatabasesSheets(window: window, launcher: coordinator.launcher, list: coordinator.listViewModel)
        alerts = MacDatabasesAlerts(window: window, launcher: coordinator.launcher, list: coordinator.listViewModel)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self, weak coordinator] _ in
            MainActor.assumeIsolated {
                self?.databaseSettingsSheets?.endSettings()
                self?.sheets?.end()
                self?.alerts?.end()
                coordinator?.launcher.sheet = nil
                self?.onWillClose?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class DatabasesWindow: NSWindow {
    // Hosting resets this during layout.
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = DatabasesWindowController.contentSize }
    }

    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        growToFit(sheetWindow)
        super.beginSheet(sheetWindow, completionHandler: handler)
    }

    override func beginCriticalSheet(_ sheetWindow: NSWindow,
                                     completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        growToFit(sheetWindow)
        super.beginCriticalSheet(sheetWindow, completionHandler: handler)
    }

    /// AppKit hangs a sheet taller than the space below the titlebar past the window's bottom edge.
    private func growToFit(_ sheet: NSWindow) {
        let fitted = frame(fitting: sheet.frame.height)
        guard fitted != frame else { return }
        setFrame(screen.map { constrainFrameRect(fitted, to: $0) } ?? fitted, display: true)
    }

    /// The frame, taller and with the same top edge, that leaves room for a sheet below the titlebar.
    func frame(fitting sheetHeight: CGFloat) -> NSRect {
        let titlebarHeight = frame.height - contentLayoutRect.height
        let missing = (sheetHeight + titlebarHeight - frame.height).rounded(.up)
        guard missing > 0 else { return frame }
        var fitted = frame
        fitted.size.height += missing
        fitted.origin.y -= missing
        return fitted
    }
}

private struct MacDatabasesLauncherRoot: View {
    let coordinator: MacWindowCoordinator
    let content: MacDatabasesLauncherViewController

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
            routing: coordinator.routing, enrollment: coordinator.enrollment, content: content)
    }
}

private struct MacDatabasesLauncherContent: NSViewControllerRepresentable {
    let controller: MacDatabasesLauncherViewController

    func makeNSViewController(context: Context) -> MacDatabasesLauncherViewController { controller }
    func updateNSViewController(_ controller: MacDatabasesLauncherViewController, context: Context) {}
}

/// The launch presentations; the database management sheets sit one layer in.
struct MacDatabasesLauncherView: View {
    let coordinator: MacWindowCoordinator
    @Bindable var launcher: MacDatabasesLauncherViewModel
    let routing: MacApplicationRouting
    @Bindable var enrollment: TOTPEnrollmentCoordinator
    let content: MacDatabasesLauncherViewController

    var body: some View {
        MacDatabasesLauncherContent(controller: content)
            .ignoresSafeArea()
            .modifier(MacDatabasesManagementPresentations(launcher: launcher, list: coordinator.listViewModel))
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

/// The launcher rows' export; their sheets and alerts are native (`MacDatabasesSheets`, `MacDatabasesAlerts`).
private struct MacDatabasesManagementPresentations: ViewModifier {
    @Bindable var launcher: MacDatabasesLauncherViewModel
    @Bindable var list: DatabaseListViewModel

    func body(content: Content) -> some View {
        content
            .onAppear { list.reload() }
            .databaseExporter(request: $launcher.exportRequest)
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
