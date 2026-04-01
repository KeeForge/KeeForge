import SwiftUI
import UniformTypeIdentifiers

struct DatabaseListView: View {
    @Bindable var viewModel: DatabaseListViewModel
    let onSelectDatabase: (DatabaseReference) -> Void

    @State private var showDatabasePicker = false
    @State private var keyFileTarget: DatabaseReference?
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var pendingRemoval: DatabaseReference?
    @State private var renameTarget: DatabaseReference?
    @State private var renameText = ""
    @State private var detailsReference: DatabaseReference?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.databases.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.databases) { reference in
                            Button {
                                onSelectDatabase(reference)
                            } label: {
                                DatabaseRowView(
                                    reference: reference,
                                    status: viewModel.status(for: reference),
                                    biometricSymbolName: viewModel.biometricIndicatorSymbolName(),
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
                        .onMove(perform: viewModel.moveDatabases)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        viewModel.refreshBookmarks()
                    }
                }
            }
            .navigationTitle("KeeForge")
            .toolbar {
                if !viewModel.databases.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settings.button")

                    Button {
                        selectionAlert = nil
                        showDatabasePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("database.add.button")
                }
            }
        }
        .onAppear {
            viewModel.reload()
        }
        .fileImporter(
            isPresented: $showDatabasePicker,
            allowedContentTypes: DocumentPickerService.databasePickerContentTypes,
            onCompletion: handleDatabaseSelection
        )
        .fileImporter(
            isPresented: Binding(
                get: { keyFileTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        keyFileTarget = nil
                    }
                }
            ),
            allowedContentTypes: DocumentPickerService.keyFilePickerContentTypes,
            onCompletion: handleKeyFileSelection
        )
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
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
                    keyFileTarget = currentReference(for: reference)
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Databases", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a KeePass .kdbx file to get started.")
        } actions: {
            Button {
                selectionAlert = nil
                showDatabasePicker = true
            } label: {
                Label("Add Database", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("database.empty.add")
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
                keyFileTarget = reference
            }

            Button("Clear Key File", role: .destructive) {
                try? viewModel.setKeyFile(url: nil, for: reference)
                refreshDetailsReferenceIfNeeded(for: reference.id)
            }
        } else {
            Button("Set Key File") {
                keyFileTarget = reference
            }
        }

        Button(reference.isQuickLaunch ? "Remove Quick Launch" : "Set Quick Launch") {
            viewModel.toggleQuickLaunch(for: reference)
            refreshDetailsReferenceIfNeeded(for: reference.id)
        }

        Button("Database Details") {
            detailsReference = currentReference(for: reference)
        }

        Button("Remove", role: .destructive) {
            pendingRemoval = reference
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

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        guard let keyFileTarget else { return }

        defer {
            self.keyFileTarget = nil
        }

        switch result {
        case .success(let url):
            do {
                try viewModel.setKeyFile(url: url, for: keyFileTarget)
                refreshDetailsReferenceIfNeeded(for: keyFileTarget.id)
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
}

private struct DatabaseDetailsView: View {
    let reference: DatabaseReference
    @Bindable var viewModel: DatabaseListViewModel
    let onSelectKeyFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var isQuickLaunch = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Nickname", text: $nickname)
                        .onSubmit(saveNickname)

                    LabeledContent("Filename", value: reference.filename)

                    Toggle("Quick Launch", isOn: $isQuickLaunch)
                        .onChange(of: isQuickLaunch) { _, _ in
                            viewModel.toggleQuickLaunch(for: reference)
                        }
                }

                Section("Key File") {
                    LabeledContent("Associated File", value: reference.keyFileFilename ?? "None")

                    Button("Select Key File") {
                        onSelectKeyFile()
                    }

                    if reference.keyFileFilename != nil {
                        Button("Clear Key File", role: .destructive) {
                            try? viewModel.setKeyFile(url: nil, for: reference)
                        }
                    }
                }

                Section("Metadata") {
                    LabeledContent("Added", value: dateText(reference.addedAt))

                    if let lastOpenedAt = reference.lastOpenedAt {
                        LabeledContent("Last Opened", value: dateText(lastOpenedAt))
                    }
                }
            }
            .navigationTitle(reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                nickname = reference.nickname ?? ""
                isQuickLaunch = reference.isQuickLaunch
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveNickname()
                        dismiss()
                    }
                }
            }
        }
    }

    private func saveNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.setNickname(trimmed.isEmpty ? nil : trimmed, for: reference)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
