import AppKit
import SwiftUI

/// The Databases window: the launcher (`MacDatabasesLauncherViewController`)
/// and the app-level launch presentations. It never shows a database's contents.
@MainActor
final class DatabasesWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("databases")
    /// The board's 780 pt width; the height keeps a `MacSheetMetrics.maxHeight` sheet clear of the titlebar.
    static let contentSize = NSSize(width: 780, height: 620)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    var onWillClose: (@MainActor () -> Void)?
    let launcherViewController: MacDatabasesLauncherViewController
    private var closeObserver: NSObjectProtocol?

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
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillClose?() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class DatabasesWindow: NSWindow {
    // Hosting resets this during layout; reused sheets need the full height.
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = DatabasesWindowController.contentSize }
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
        .alert("Can’t Remove Database", isPresented: refusedRemoval, presenting: launcher.refusedRemoval) { _ in
            Button("OK", role: .cancel) {}
        } message: { reference in
            Text("“\(reference.displayName)” has unsaved changes. Save them or close its window, then remove it.")
        }
    }

    private var refusedRemoval: Binding<Bool> {
        Binding(
            get: { launcher.refusedRemoval != nil },
            set: { if !$0 { launcher.refusedRemoval = nil } }
        )
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

/// What the launcher's rows and add actions ask for: creating, connecting,
/// details, rename, key file, export, removal and the pending-upload alerts.
private struct MacDatabasesManagementPresentations: ViewModifier {
    @Bindable var launcher: MacDatabasesLauncherViewModel
    @Bindable var list: DatabaseListViewModel
    @State private var renameText = ""
    @State private var keyFilePicker = PickerPresentationState<DatabaseReference>()

    func body(content: Content) -> some View {
        content
            .onAppear { list.reload() }
            .sheet(item: $launcher.sheet, onDismiss: cancelPendingCloudAuthentication) { sheet in
                sheetContent(sheet)
                    .macSheetFrame()
            }
            .confirmationDialog("Connect to Server", isPresented: $launcher.isChoosingServer) {
                ForEach(launcher.connectProviders) { provider in
                    Button(provider.displayName) { launcher.requestConnect(provider) }
                        .accessibilityIdentifier("database.add.\(provider.rawValue)")
                }
            }
            .onChange(of: launcher.keyFileTarget) { _, target in
                guard let target else { return }
                launcher.keyFileTarget = nil
                keyFilePicker.present(target)
            }
            .fileImporter(isPresented: isChoosingKeyFile, allowedContentTypes: DocumentPickerService.keyFilePickerContentTypes,
                onCompletion: handleKeyFileSelection)
            .alert(item: $launcher.selectionAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            .alert("Rename Database", isPresented: isRenaming, presenting: launcher.renameTarget) { reference in
                TextField("Nickname", text: $renameText)
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    list.setNickname(trimmed.isEmpty ? nil : trimmed, for: reference)
                    launcher.renameTarget = nil
                }
                Button("Cancel", role: .cancel) { launcher.renameTarget = nil }
            } message: { reference in
                Text("Use a custom name for \(reference.filename).")
            }
            .onChange(of: launcher.renameTarget) { _, target in renameText = target?.nickname ?? "" }
            .alert(list.pendingUploadAlert?.title ?? "", isPresented: isShowingPendingUploadAlert) {
                pendingUploadAlertButtons
            } message: {
                Text(list.pendingUploadAlert?.message ?? "")
            }
            .confirmationDialog("Remove Database?", isPresented: isConfirmingRemoval, presenting: launcher.pendingRemoval) { _ in
                Button("Remove", role: .destructive) { launcher.confirmRemoval() }
                    .accessibilityIdentifier("databases.remove.confirm")
                Button("Cancel", role: .cancel) { launcher.pendingRemoval = nil }
            } message: { target in
                Text("“\(target.displayName)” will be removed from KeeForge, including its cached copy and saved biometric key.")
            }
            .confirmationDialog("Discard Pending Upload?", isPresented: isConfirmingDiscard,
                presenting: launcher.pendingUploadDiscardTarget) { target in
                Button("Discard Upload", role: .destructive) {
                    launcher.pendingUploadDiscardTarget = nil
                    Task { await list.discardConflictedPendingUploads(for: target) }
                }
                Button("Cancel", role: .cancel) { launcher.pendingUploadDiscardTarget = nil }
            } message: { target in
                Text("The pending change for “\(target.displayName)” could not be uploaded because the copy in the cloud changed. KeeForge keeps a timestamped backup on this device before discarding it.")
            }
            .databaseExporter(request: $launcher.exportRequest)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: MacDatabasesLauncherViewModel.Sheet) -> some View {
        switch sheet {
        case .newDatabase:
            DatabaseCreationView(viewModel: DatabaseCreationViewModel()) { created in
                list.reload()
                launcher.didCreate(created)
            }
        case .connect(let provider):
            CloudFileBrowserView(
                providerID: provider.rawValue,
                onSelect: { selection in
                    let reference = list.addCloudDatabase(selection: selection)
                    launcher.sheet = nil
                    launcher.open(reference)
                },
                onFailure: { error in
                    launcher.selectionAlert = DocumentPickerService.SelectionAlert(
                        title: String(localized: "Couldn’t Open \(provider.displayName)"),
                        message: error.localizedDescription)
                }
            )
        case .details(let databaseID):
            if let reference = list.databases.first(where: { $0.id == databaseID }) {
                DatabaseDetailsView(reference: reference, listViewModel: list, onSelectKeyFile: {
                    launcher.keyFileTarget = list.databases.first { $0.id == databaseID }
                })
            }
        }
    }

    @ViewBuilder
    private var pendingUploadAlertButtons: some View {
        if let alert = list.pendingUploadAlert, alert.kind == .conflict,
           let reference = list.databases.first(where: { $0.id == alert.databaseId }) {
            // Both follow-ups present something else; started while this alert
            // is still dismissing they are dropped silently, so wait it out.
            Button(DatabaseExportLabels.currentCopy) {
                list.dismissPendingUploadAlert()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    launcher.exportRequest = .currentCopy(reference)
                }
            }
            .accessibilityIdentifier("pending-upload-conflict.export")
            Button("Discard Pending Upload…", role: .destructive) {
                list.dismissPendingUploadAlert()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    launcher.pendingUploadDiscardTarget = reference
                }
            }
            .accessibilityIdentifier("pending-upload-conflict.discard")
            Button("Cancel", role: .cancel) { list.dismissPendingUploadAlert() }
                .accessibilityIdentifier("pending-upload-conflict.cancel")
        } else {
            Button("OK") { list.dismissPendingUploadAlert() }
        }
    }

    private var isChoosingKeyFile: Binding<Bool> {
        Binding(get: { keyFilePicker.isPresented }, set: { keyFilePicker.updatePresentation($0) })
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { launcher.renameTarget != nil }, set: { if !$0 { launcher.renameTarget = nil } })
    }

    private var isShowingPendingUploadAlert: Binding<Bool> {
        Binding(get: { list.pendingUploadAlert != nil }, set: { if !$0 { list.dismissPendingUploadAlert() } })
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { launcher.pendingRemoval != nil }, set: { if !$0 { launcher.pendingRemoval = nil } })
    }

    private var isConfirmingDiscard: Binding<Bool> {
        Binding(get: { launcher.pendingUploadDiscardTarget != nil },
                set: { if !$0 { launcher.pendingUploadDiscardTarget = nil } })
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        guard let target = keyFilePicker.consumeActiveTarget() else { return }
        switch result {
        case .success(let url):
            do {
                try list.setKeyFile(url: url, for: target)
            } catch {
                launcher.selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
            }
        case .failure(let error):
            launcher.selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private func cancelPendingCloudAuthentication() {
        for provider in CloudProviderRegistry.availableProviders {
            CloudProviderRegistry.provider(for: provider.rawValue)?.cancelPendingAuthentication()
        }
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
