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

    @State private var pickerState = PickerPresentationState<PickerTarget>()
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
                            .accessibilityIdentifier("database.edit.button")
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
                        pickerState.present(.database)
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
                pickerState.present(.database)
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
                Section {
                    LabeledContent("Name", value: currentDisplayName)

                    LabeledContent("Custom Name") {
                        TextField("Use filename", text: $nickname)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(saveNickname)
                    }

                    LabeledContent("Filename", value: reference.filename)

                    Toggle("Quick Launch", isOn: $isQuickLaunch)
                        .onChange(of: isQuickLaunch) { _, _ in
                            viewModel.toggleQuickLaunch(for: reference)
                        }
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Quick Launch opens this database automatically on app launch. Auto-Unlock with Face ID controls whether KeeForge prompts for biometrics after a database is opened.")
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
