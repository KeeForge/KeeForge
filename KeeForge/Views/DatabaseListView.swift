import AuthenticationServices
import SwiftUI
import UIKit
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
    var selectedDatabaseID: UUID? = nil

    @State private var pickerState = PickerPresentationState<PickerTarget>()
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var pendingRemoval: DatabaseReference?
    @State private var renameTarget: DatabaseReference?
    @State private var renameText = ""
    @State private var detailsReference: DatabaseReference?
    @State private var showSettings = false
    @State private var activeCloudProvider: CloudProviderKind?
    @State private var isDropboxWriteScopeReconnectInFlight = false

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
                                databaseRowButton(for: reference)
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
            .navigationTitle("KeeForge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !viewModel.databases.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                            .accessibilityIdentifier("database.edit.button")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("database.settings.button")

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
        .safeAreaInset(edge: .top) {
            if viewModel.shouldShowDropboxWriteScopeUpgradeBanner {
                DropboxWriteScopeUpgradeBanner(
                    isReconnectInFlight: isDropboxWriteScopeReconnectInFlight,
                    onReconnect: beginDropboxWriteScopeReconnect,
                    onNotNow: {
                        viewModel.dismissDropboxWriteScopeUpgradeBanner()
                    }
                )
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .onAppear {
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
            Button("OK") {
                viewModel.dismissPendingUploadAlert()
            }
        } message: {
            Text(viewModel.pendingUploadAlert?.message ?? "")
        }
        .confirmationDialog(
            "Remove Database?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRemoval = nil
                    }
                }
            ),
            presenting: pendingRemoval
        ) { reference in
            Button("Remove", role: .destructive) {
                viewModel.removeDatabase(reference)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { reference in
            Text("“\(reference.displayName)” will be removed from KeeForge, including its cached copy and saved biometric key.")
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
                viewModel: viewModel,
                onSelectKeyFile: {
                    pickerState.present(.keyFile(currentReference(for: reference)))
                }
            )
        }
        .sheet(
            isPresented: $showSettings,
            onDismiss: {
                viewModel.reload()
            }
        ) {
            SettingsView()
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
        }
    }

    private func databaseRowButton(for reference: DatabaseReference) -> some View {
        Button {
            onSelectDatabase(reference)
        } label: {
            DatabaseRowView(
                reference: reference,
                status: viewModel.status(for: reference),
                lastOpenedDescription: viewModel.lastOpenedDescription(for: reference),
                filenameSubtitle: viewModel.detailSubtitle(for: reference)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("database.row")
        .contextMenu {
            contextMenu(for: reference)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) {
                pendingRemoval = reference
            }
        }
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
            Text("Add a KeePass .kdbx file to get started.")
        } actions: {
            Menu {
                addDatabaseMenuContent
            } label: {
                Label("Add Database", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .menuOrder(.fixed)
            .accessibilityIdentifier("database.empty.add")
        }
    }

    @ViewBuilder
    private var addDatabaseMenuContent: some View {
        Button {
            selectionAlert = nil
            pickerState.present(.database)
        } label: {
            Label("Local Device", systemImage: "iphone")
        }
        .accessibilityIdentifier("database.add.files")

        Button {
            activeCloudProvider = .dropbox
        } label: {
            Label {
                Text("Dropbox")
            } icon: {
                CloudProviderIcon(provider: .dropbox, size: 16)
            }
        }
        .accessibilityIdentifier("database.add.dropbox")
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
            title: "Couldn’t Open \(provider.displayName)",
            message: error.localizedDescription
        )
    }

    @MainActor
    private func beginDropboxWriteScopeReconnect() {
        guard isDropboxWriteScopeReconnectInFlight == false else { return }
        guard let provider = CloudProviderRegistry.provider(for: CloudProviderKind.dropbox.rawValue) else {
            selectionAlert = makeCloudSelectionAlert(
                error: CloudProviderError.invalidConfiguration,
                provider: .dropbox
            )
            return
        }

        isDropboxWriteScopeReconnectInFlight = true
        Task { @MainActor in
            defer { isDropboxWriteScopeReconnectInFlight = false }

            do {
                _ = try await provider.authenticate(from: presentationAnchor())
                viewModel.reload()
            } catch let cloudError as CloudProviderError where cloudError == .authenticationCancelled {
                return
            } catch {
                selectionAlert = makeCloudSelectionAlert(error: error, provider: .dropbox)
            }
        }
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
    }
}

private struct DropboxWriteScopeUpgradeBanner: View {
    let isReconnectInFlight: Bool
    let onReconnect: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KeeForge can now save changes back to Dropbox.")
                .font(.headline)
            Text("Reconnect Dropbox to enable editing — your existing read access will keep working either way.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Reconnect Dropbox", action: onReconnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReconnectInFlight)

                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
                    .disabled(isReconnectInFlight)
            }
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
        .accessibilityIdentifier("dropbox.write-scope-upgrade-banner")
    }
}

private struct DatabaseDetailsView: View {
    let reference: DatabaseReference
    @Bindable var viewModel: DatabaseListViewModel
    let onSelectKeyFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var isQuickLaunch = false

    private var currentReference: DatabaseReference {
        viewModel.databases.first(where: { $0.id == reference.id }) ?? reference
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: currentDisplayName)

                    LabeledContent("Custom Name") {
                        TextField("Use filename", text: $nickname)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(saveNickname)
                            .accessibilityIdentifier("database-details.nickname-field")
                    }

                    LabeledContent("Filename", value: currentReference.filename)

                    Toggle("Quick Launch", isOn: $isQuickLaunch)
                        .onChange(of: isQuickLaunch) { _, newValue in
                            let currentValue = currentReference.isQuickLaunch
                            guard newValue != currentValue else { return }
                            viewModel.toggleQuickLaunch(for: reference)
                            isQuickLaunch = currentReference.isQuickLaunch
                        }
                        .accessibilityIdentifier("database-details.quick-launch-toggle")
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Quick Launch opens this database automatically on app launch. Auto-Unlock with Face ID controls whether KeeForge prompts for biometrics after a database is opened.")
                }

                Section {
                    Toggle(
                        "Read-only",
                        isOn: Binding(
                            get: { currentReference.isReadOnly },
                            set: { viewModel.setReadOnly($0, for: reference) }
                        )
                    )
                    .accessibilityIdentifier("database-row.read-only-toggle")
                } header: {
                    Text("Editing")
                } footer: {
                    Text("Keep this database openable but block create, edit, and delete actions until you turn editing back on.")
                }

                Section("Key File") {
                    LabeledContent("Associated File", value: currentReference.keyFileFilename ?? "None")

                    Button("Select Key File") {
                        onSelectKeyFile()
                    }
                    .accessibilityIdentifier("database-details.key-file-select")

                    if currentReference.keyFileFilename != nil {
                        Button("Clear Key File", role: .destructive) {
                            try? viewModel.setKeyFile(url: nil, for: reference)
                        }
                    }
                }

                Section("Metadata") {
                    LabeledContent("Added", value: dateText(currentReference.addedAt))

                    if let lastOpenedAt = currentReference.lastOpenedAt {
                        LabeledContent("Last Opened", value: dateText(lastOpenedAt))
                    }
                }

                if let cloudState = viewModel.cloudState(for: reference),
                   let metadata = currentReference.cloudSyncMetadata {
                    Section {
                        LabeledContent("Provider") {
                            HStack(spacing: 6) {
                                CloudProviderIcon(provider: metadata.providerKind, size: 16)
                                Text(cloudState.providerName)
                            }
                            .lineLimit(1)
                        }

                        LabeledContent("Account") {
                            Text(cloudState.accountLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Path") {
                            Text(metadata.displayPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.trailing)
                        }

                        if let remoteModifiedAt = metadata.remoteModifiedAt {
                            LabeledContent("Remote Modified", value: dateText(remoteModifiedAt))
                        }

                        if let lastSyncedAt = metadata.lastSyncedAt {
                            LabeledContent("Last Sync", value: dateText(lastSyncedAt))
                        }

                        LabeledContent("Status", value: cloudState.warningText ?? "Healthy")
                    } header: {
                        Text("Cloud Sync")
                    } footer: {
                        if cloudState.isConnected {
                            Text("Cloud databases are cached locally and refreshed whenever you open them in the main app. AutoFill uses the cached copy only.")
                        } else {
                            Text("This account is disconnected. KeeForge keeps the cached copy until you remove the database.")
                        }
                    }
                }
            }
            .navigationTitle(currentReference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                syncFormStateFromCurrentReference()
            }
            .onChange(of: currentReference.nickname) { _, _ in
                syncFormStateFromCurrentReference()
            }
            .onChange(of: currentReference.isQuickLaunch) { _, newValue in
                isQuickLaunch = newValue
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveNickname()
                        dismiss()
                    }
                    .accessibilityIdentifier("database-details.close")
                }
            }
        }
    }

    private func syncFormStateFromCurrentReference() {
        nickname = currentReference.nickname ?? ""
        isQuickLaunch = currentReference.isQuickLaunch
    }

    private func saveNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.setNickname(trimmed.isEmpty ? nil : trimmed, for: reference)
    }

    private var currentDisplayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return reference.displayName
        }
        return trimmed
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
