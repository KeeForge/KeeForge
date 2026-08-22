import SwiftUI
import UniformTypeIdentifiers

struct PickerPresentationState<T> {
    private(set) var activeTarget: T?
    private(set) var isPresented = false

    mutating func present(_ target: T) {
        activeTarget = target
        isPresented = true
    }

    mutating func updatePresentation(_ isPresented: Bool) {
        self.isPresented = isPresented
    }

    mutating func consumeActiveTarget() -> T? {
        defer {
            activeTarget = nil
            isPresented = false
        }

        return activeTarget
    }
}

struct DatabaseListView: View {
    private enum PickerTarget {
        case database
        case keyFile(DatabaseReference)
    }

    @Bindable var viewModel: DatabaseListViewModel
    let onSelectDatabase: (DatabaseReference) -> Void
    let onCreateDatabase: (CreatedDatabase) -> Void
    var selectedDatabaseID: UUID? = nil

    @State private var pickerState = PickerPresentationState<PickerTarget>()
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var pendingRemoval: DatabaseReference?
    @State private var pendingUploadDiscardTarget: DatabaseReference?
    @State private var renameTarget: DatabaseReference?
    @State private var renameText = ""
    @State private var detailsReference: DatabaseReference?
    @State private var showSettings = false
    @State private var showDatabaseUsageStats = SettingsService.showDatabaseUsageStats
    @State private var activeCloudProvider: CloudProviderKind?
    @State private var isDatabaseCreationPresented = false
    @State private var exportRequest: DatabaseExportRequest?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.databases.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.databases) { reference in
                            if reference.id == selectedDatabaseID {
                                databaseRowButton(for: reference)
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.16))
                                    )
                            } else {
                                // Hover only on the unselected branch: both this
                                // and the selection highlight above drive
                                // `.listRowBackground`, so applying it to a
                                // selected row would replace the selection fill.
                                databaseRowButton(for: reference)
                                    .macHoverHighlight()
                            }
                        }
                        .onMove(perform: viewModel.moveDatabases)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        viewModel.refreshBookmarks()
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.shouldShowAutoFillTip {
                    AutoFillTipBanner(
                        onEnable: { Task { await viewModel.requestEnableAutoFill() } },
                        onDismiss: { viewModel.dismissAutoFillTip() }
                    )
                }
            }
            .navigationTitle("KeeForge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // `EditButton` does not exist on macOS; list rows reorder via
                // drag and delete via context menus / swipe actions there.
                #if os(iOS)
                if !viewModel.databases.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                            .accessibilityIdentifier("database.edit.button")
                    }
                }
                #endif

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // macOS uses the standard Settings window (⌘,) instead of
                    // a sheet, which on the Mac would have no close affordance.
                    #if os(macOS)
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("database.settings.button")
                    #else
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("database.settings.button")
                    #endif

                    Menu {
                        addDatabaseMenuContent
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuOrder(.fixed)
                    .accessibilityIdentifier("database.add.button")
                }
            }
        }
        .onAppear {
            refreshUsageStatsVisibility()
            viewModel.reload()
        }
        .task {
            await viewModel.refreshAutoFillStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refreshAutoFillStatus() }
            }
        }
        .onChange(of: showDatabaseUsageStats) { _, _ in
            viewModel.reload()
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickerState.isPresented },
                set: { isPresented in
                    pickerState.updatePresentation(isPresented)
                }
            ),
            allowedContentTypes: pickerContentTypes,
            onCompletion: handlePickerSelection
        )
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            viewModel.pendingUploadAlert?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingUploadAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissPendingUploadAlert()
                    }
                }
            )
        ) {
            pendingUploadAlertButtons
        } message: {
            Text(viewModel.pendingUploadAlert?.message ?? "")
        }
        .alert(
            "Rename Database",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        renameTarget = nil
                        renameText = ""
                    }
                }
            ),
            presenting: renameTarget
        ) { reference in
            TextField("Nickname", text: $renameText)
            Button("Save") {
                let trimmedText = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setNickname(trimmedText.isEmpty ? nil : trimmedText, for: reference)
                if detailsReference?.id == reference.id {
                    detailsReference = viewModel.databases.first(where: { $0.id == reference.id })
                }
                renameTarget = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameText = ""
            }
        } message: { reference in
            Text("Use a custom name for \(reference.filename).")
        }
        .sheet(item: $detailsReference) { reference in
            DatabaseDetailsView(
                reference: currentReference(for: reference),
                listViewModel: viewModel,
                onSelectKeyFile: {
                    pickerState.present(.keyFile(currentReference(for: reference)))
                }
            )
            .macSheetFrame()
        }
        .sheet(
            isPresented: $showSettings,
            onDismiss: {
                refreshUsageStatsVisibility()
                viewModel.reload()
            }
        ) {
            SettingsView(listViewModel: viewModel)
                .macSheetFrame()
        }
        .sheet(
            item: $activeCloudProvider,
            onDismiss: cancelPendingCloudAuthentication
        ) { provider in
            CloudFileBrowserView(
                providerID: provider.rawValue,
                onSelect: { selection in
                    let reference = viewModel.addCloudDatabase(selection: selection)
                    activeCloudProvider = nil
                    onSelectDatabase(reference)
                },
                onFailure: { error in
                    selectionAlert = makeCloudSelectionAlert(error: error, provider: provider)
                }
            )
            .macSheetFrame()
        }
        .sheet(isPresented: $isDatabaseCreationPresented) {
            DatabaseCreationView(
                viewModel: DatabaseCreationViewModel(),
                onCreated: { createdDatabase in
                    viewModel.reload()
                    onCreateDatabase(createdDatabase)
                }
            )
            .macSheetFrame()
        }
        .databaseExporter(request: $exportRequest)
    }

    @ViewBuilder
    private var pendingUploadAlertButtons: some View {
        if let alert = viewModel.pendingUploadAlert,
           alert.kind == .conflict,
           let reference = viewModel.databases.first(where: { $0.id == alert.databaseId }) {
            // Both follow-ups present something else; started while this alert
            // is still dismissing they are dropped silently, so wait it out.
            Button("Export Copy…") {
                viewModel.dismissPendingUploadAlert()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    exportRequest = .currentCopy(reference)
                }
            }
            .accessibilityIdentifier("pending-upload-conflict.export")

            Button("Discard Pending Upload…", role: .destructive) {
                viewModel.dismissPendingUploadAlert()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    pendingUploadDiscardTarget = reference
                }
            }
            .accessibilityIdentifier("pending-upload-conflict.discard")

            Button("Cancel", role: .cancel) {
                viewModel.dismissPendingUploadAlert()
            }
            .accessibilityIdentifier("pending-upload-conflict.cancel")
        } else {
            Button("OK") {
                viewModel.dismissPendingUploadAlert()
            }
        }
    }

    private func databaseRowButton(for reference: DatabaseReference) -> some View {
        Button {
            onSelectDatabase(reference)
        } label: {
            DatabaseRowView(
                reference: reference,
                status: viewModel.status(for: reference),
                lastOpenedDescription: viewModel.lastOpenedDescription(
                    for: reference,
                    showsUsageStats: showDatabaseUsageStats
                ),
                filenameSubtitle: viewModel.detailSubtitle(for: reference)
            )
        }
        .id("\(reference.id.uuidString)-\(showDatabaseUsageStats)")
        .buttonStyle(.plain)
        .accessibilityIdentifier("database.row")
        .contextMenu {
            contextMenu(for: reference)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) {
                // Defer until the swipe cell has closed: the confirmation
                // dialog below is anchored to this row, and presenting it
                // while the row is still translated by the open swipe
                // actions fails silently on iOS 26.
                let target = reference
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    pendingRemoval = target
                }
            }
        }
        // Both dialogs are attached to the row (not the List) so iOS anchors
        // them to the database they act on instead of an arbitrary popover in
        // the middle of the screen. Each dialog only presents on the row whose
        // reference is pending.
        .confirmationDialog(
            "Remove Database?",
            isPresented: Binding(
                get: { pendingRemoval?.id == reference.id },
                set: { isPresented in
                    if !isPresented {
                        pendingRemoval = nil
                    }
                }
            ),
            presenting: pendingRemoval
        ) { target in
            Button("Remove", role: .destructive) {
                viewModel.removeDatabase(target)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { target in
            Text("“\(target.displayName)” will be removed from KeeForge, including its cached copy and saved biometric key.")
        }
        .confirmationDialog(
            "Discard Pending Upload?",
            isPresented: Binding(
                get: { pendingUploadDiscardTarget?.id == reference.id },
                set: { isPresented in
                    if !isPresented {
                        pendingUploadDiscardTarget = nil
                    }
                }
            ),
            presenting: pendingUploadDiscardTarget
        ) { target in
            Button("Discard Upload", role: .destructive) {
                Task {
                    await viewModel.discardConflictedPendingUploads(for: target)
                    refreshDetailsReferenceIfNeeded(for: target.id)
                }
                pendingUploadDiscardTarget = nil
            }
            Button("Cancel", role: .cancel) {
                pendingUploadDiscardTarget = nil
            }
        } message: { target in
            Text("The pending change for “\(target.displayName)” could not be uploaded because the copy in the cloud changed. KeeForge keeps a timestamped backup on this device before discarding it.")
        }
    }

    private func refreshUsageStatsVisibility() {
        showDatabaseUsageStats = SettingsService.showDatabaseUsageStats
    }

    @MainActor
    private func cancelPendingCloudAuthentication() {
        for providerKind in CloudProviderRegistry.availableProviders {
            CloudProviderRegistry.provider(for: providerKind.rawValue)?.cancelPendingAuthentication()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Databases", systemImage: "folder.badge.plus")
        } description: {
            Text("Create a new KeePass database or import an existing .kdbx file.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    isDatabaseCreationPresented = true
                } label: {
                    Label("Create New Database", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("database.empty.create")

                Menu {
                    importDatabaseMenuContent
                } label: {
                    Label("Import Existing Database", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .menuOrder(.fixed)
                .accessibilityIdentifier("database.empty.add")
            }
        }
    }

    @ViewBuilder
    private var addDatabaseMenuContent: some View {
        Button {
            isDatabaseCreationPresented = true
        } label: {
            Label("New Database", systemImage: "doc.badge.plus")
        }
        .accessibilityIdentifier("database.add.new")

        Section("Import Existing Database") {
            importDatabaseMenuContent
        }
    }

    @ViewBuilder
    private var importDatabaseMenuContent: some View {
        Button {
            selectionAlert = nil
            pickerState.present(.database)
        } label: {
            Label("Files", systemImage: "iphone")
        }
        .accessibilityIdentifier("database.add.files")

        ForEach(CloudProviderRegistry.availableProviders) { providerKind in
            Button {
                activeCloudProvider = providerKind
            } label: {
                Label {
                    Text(providerKind.displayName)
                } icon: {
                    CloudProviderIcon(provider: providerKind)
                }
            }
            .accessibilityIdentifier("database.add.\(providerKind.rawValue)")
        }
    }

    @ViewBuilder
    private func contextMenu(for reference: DatabaseReference) -> some View {
        Button("Rename") {
            renameTarget = reference
            renameText = reference.nickname ?? ""
        }

        if reference.keyFileFilename != nil {
            Button("Change Key File") {
                pickerState.present(.keyFile(reference))
            }

            Button("Clear Key File", role: .destructive) {
                try? viewModel.setKeyFile(url: nil, for: reference)
                refreshDetailsReferenceIfNeeded(for: reference.id)
            }
        } else {
            Button("Set Key File") {
                pickerState.present(.keyFile(reference))
            }
        }

        Toggle(
            "Quick Launch",
            isOn: Binding(
                get: { currentReference(for: reference).isQuickLaunch },
                set: { _ in
                    viewModel.toggleQuickLaunch(for: reference)
                    refreshDetailsReferenceIfNeeded(for: reference.id)
                }
            )
        )
        .accessibilityIdentifier("database-row.quick-launch-toggle")

        if viewModel.hasPendingUploads(for: reference) {
            Button("Push pending changes") {
                Task {
                    await viewModel.pushPendingChanges(for: currentReference(for: reference))
                    refreshDetailsReferenceIfNeeded(for: reference.id)
                }
            }
            .accessibilityIdentifier("database-row.push-pending-action")
        }

        if viewModel.hasPendingUploadConflicts(for: reference) {
            Button("Discard pending upload", role: .destructive) {
                pendingUploadDiscardTarget = currentReference(for: reference)
            }
            .accessibilityIdentifier("database-row.discard-pending-action")
        }

        Toggle(
            "Read-only",
            isOn: Binding(
                get: { currentReference(for: reference).isReadOnly },
                set: { newValue in
                    viewModel.setReadOnly(newValue, for: reference)
                    refreshDetailsReferenceIfNeeded(for: reference.id)
                }
            )
        )
        .accessibilityIdentifier("database-row.read-only-toggle")

        Button("Export Copy…") {
            exportRequest = .currentCopy(currentReference(for: reference))
        }
        .accessibilityIdentifier("database-row.export-copy-action")

        Button("Database Details") {
            detailsReference = currentReference(for: reference)
        }
        .accessibilityIdentifier("database-row.details")

        Button("Remove", role: .destructive) {
            pendingRemoval = reference
        }
    }

    private var pickerContentTypes: [UTType] {
        switch pickerState.activeTarget {
        case .keyFile:
            DocumentPickerService.keyFilePickerContentTypes
        case .database, .none:
            DocumentPickerService.databasePickerContentTypes
        }
    }

    private func handlePickerSelection(_ result: Result<URL, Error>) {
        let activePicker = pickerState.consumeActiveTarget()

        switch activePicker {
        case .database:
            handleDatabaseSelection(result)
        case .keyFile(let reference):
            handleKeyFileSelection(result, for: reference)
        case .none:
            break
        }
    }

    private func handleDatabaseSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard isSupportedDatabaseSelection(url) else {
                selectionAlert = DocumentPickerService.invalidDatabaseSelectionAlert()
                return
            }

            do {
                let reference = try viewModel.addDatabase(from: url)
                onSelectDatabase(reference)
                selectionAlert = nil
            } catch {
                selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
            }

        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>, for reference: DatabaseReference) {
        switch result {
        case .success(let url):
            do {
                try viewModel.setKeyFile(url: url, for: reference)
                refreshDetailsReferenceIfNeeded(for: reference.id)
                selectionAlert = nil
            } catch {
                selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
            }

        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private func currentReference(for reference: DatabaseReference) -> DatabaseReference {
        viewModel.databases.first(where: { $0.id == reference.id }) ?? reference
    }

    private func refreshDetailsReferenceIfNeeded(for id: UUID) {
        if detailsReference?.id == id {
            detailsReference = viewModel.databases.first(where: { $0.id == id })
        }
    }

    private func isSupportedDatabaseSelection(_ url: URL) -> Bool {
        if DocumentPickerService.isLikelyDatabaseFile(url) {
            return true
        }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return DocumentPickerService.isSupportedDatabaseFile(at: url)
    }

    private func makeCloudSelectionAlert(
        error: Error,
        provider: CloudProviderKind
    ) -> DocumentPickerService.SelectionAlert {
        DocumentPickerService.SelectionAlert(
            title: String(localized: "Couldn’t Open \(provider.displayName)"),
            message: error.localizedDescription
        )
    }

}
