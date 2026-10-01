import SwiftUI
import UniformTypeIdentifiers

/// Import logins from a password export file into the unlocked database.
/// Pushed from `DatabaseDetailsView` inside its `NavigationStack`, like
/// `MasterKeyChangeView`.
struct PasswordImportView: View {
    let sessionViewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PasswordImportViewModel
    @State private var showFileImporter = false
    @State private var showGroupPicker = false

    init(sessionViewModel: DatabaseViewModel) {
        self.sessionViewModel = sessionViewModel
        _viewModel = State(
            initialValue: PasswordImportViewModel(
                destinationGroupID: sessionViewModel.visibleRootGroupID ?? UUID(),
                duplicateCandidates: { [weak sessionViewModel] in
                    sessionViewModel?.importDuplicateCandidates ?? []
                },
                importOperation: { [weak sessionViewModel] drafts, groupID in
                    guard let sessionViewModel else {
                        throw DatabaseViewModel.PasswordImportFailure.sessionUnavailable
                    }
                    return try await sessionViewModel.importEntries(drafts, into: groupID)
                }
            )
        )
    }

    private var isSessionUnlocked: Bool {
        sessionViewModel.state == .unlocked
    }

    var body: some View {
        Form {
            if let summary = viewModel.summary {
                summarySection(summary)
            } else {
                sourceSection
                if let preview = viewModel.preview {
                    previewSection(preview)
                    if viewModel.likelyDuplicateRows.isEmpty == false {
                        duplicatesSection
                    }
                    if preview.skippedRows.isEmpty == false {
                        skippedRowsSection(preview.skippedRows)
                    }
                    destinationSection
                }
            }
        }
        .macGroupedForm()
        .disabled(viewModel.isLoading || viewModel.isImporting)
        .navigationTitle("Import Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(viewModel.isImporting)
        .interactiveDismissDisabled(viewModel.isImporting)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            if viewModel.isImporting {
                progressBadge("Importing Passwords")
            } else if viewModel.isLoading {
                progressBadge("Reading File")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if viewModel.summary == nil {
                    Button("Import") {
                        Task {
                            await viewModel.performImport()
                            if viewModel.summary != nil {
                                HapticService.success()
                            }
                        }
                    }
                    .disabled(viewModel.canImport == false || sessionViewModel.isReadOnly)
                    .accessibilityIdentifier("password-import.import")
                } else {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("password-import.done")
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.loadFile(at: url) }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showGroupPicker) {
            MoveToGroupPickerView(
                options: sessionViewModel.groupDestinationOptions(currentGroupID: viewModel.destinationGroupID),
                navigationTitle: "Select Group"
            ) { groupID in
                viewModel.destinationGroupID = groupID
            }
        }
        .onChange(of: isSessionUnlocked) { _, isUnlocked in
            if isUnlocked == false {
                viewModel.discardPreview()
            }
        }
        .onDisappear {
            viewModel.discardPreview()
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section {
            if let fileName = viewModel.fileName {
                LabeledContent("File", value: fileName)
            }
            Button {
                viewModel.clearError()
                showFileImporter = true
            } label: {
                if viewModel.preview == nil {
                    Text("Choose Export File…")
                } else {
                    Text("Choose Another File…")
                }
            }
            .accessibilityIdentifier("password-import.choose-file")
        } header: {
            Text("Apple Passwords Export")
        } footer: {
            Text("Choose the CSV file exported from the Passwords app. Files from other password managers are not supported yet. The export file is not encrypted: delete it once you have checked the imported entries.")
        }
    }

    private func previewSection(_ preview: PasswordImportPreview) -> some View {
        Section {
            LabeledContent("Entries to Import") {
                Text(viewModel.itemsToImport.count, format: .number)
                    .accessibilityIdentifier("password-import.import-count")
            }
            if preview.verificationCodeCount > 0 {
                LabeledContent("With Verification Codes") {
                    Text(preview.verificationCodeCount, format: .number)
                }
            }
            if preview.unsupportedVerificationCodeCount > 0 {
                LabeledContent("Unsupported Verification Codes") {
                    Text(preview.unsupportedVerificationCodeCount, format: .number)
                }
            }
            if preview.skippedRows.isEmpty == false {
                LabeledContent("Rows That Can't Be Imported") {
                    Text(preview.skippedRows.count, format: .number)
                        .accessibilityIdentifier("password-import.skipped-count")
                }
            }
        } header: {
            Text("Preview")
        } footer: {
            if preview.unsupportedVerificationCodeCount > 0 {
                Text("KeeForge generates only time-based verification codes. Other code setups are kept in a protected field named OTPAuth.")
            }
        }
    }

    private var duplicatesSection: some View {
        Section {
            LabeledContent("Likely Duplicates") {
                Text(viewModel.likelyDuplicateRows.count, format: .number)
                    .accessibilityIdentifier("password-import.duplicate-count")
            }
            Toggle("Skip Likely Duplicates", isOn: $viewModel.skipsLikelyDuplicates)
                .accessibilityIdentifier("password-import.skip-duplicates-toggle")
        } footer: {
            Text("These rows have the same website and user name as an entry already in this database, or as an earlier row of the file.")
        }
    }

    private func skippedRowsSection(_ skippedRows: [PasswordImportPreview.SkippedRow]) -> some View {
        Section {
            ForEach(skippedRows, id: \.row) { skippedRow in
                LabeledContent {
                    Text(Self.reasonText(skippedRow.reason))
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Row \(skippedRow.row)")
                }
                .accessibilityIdentifier("password-import.skipped-row")
            }
        } header: {
            Text("Rows That Can't Be Imported")
        } footer: {
            Text("Row numbers count the header as row 1, as a spreadsheet app shows them.")
        }
    }

    private var destinationSection: some View {
        Section {
            Button {
                showGroupPicker = true
            } label: {
                HStack {
                    Text("Import Into")

                    Spacer()

                    Label(destinationGroupName, systemImage: "folder")
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("password-import.destination")
            .macHoverHighlight()
        } header: {
            Text("Destination")
        } footer: {
            if sessionViewModel.isReadOnly {
                Text(sessionViewModel.readOnlyExplanation)
            } else {
                Text("Imported passwords are added as new entries. Existing entries are not changed.")
            }
        }
    }

    private func summarySection(_ summary: PasswordImportViewModel.Summary) -> some View {
        Section {
            LabeledContent("Imported") {
                Text(summary.importedCount, format: .number)
                    .accessibilityIdentifier("password-import.imported-count")
            }
            LabeledContent("Skipped") {
                Text(summary.skippedCount, format: .number)
                    .accessibilityIdentifier("password-import.summary-skipped-count")
            }
        } header: {
            Text("Import Finished")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch summary.outcome {
                case .saved:
                    EmptyView()
                case .awaitingConflictResolution:
                    Text("This database changed outside KeeForge, so the imported entries are not saved yet. Choose how to resolve the save conflict to finish saving them.")
                case .saveFailed(let message):
                    Text("The imported entries were added but not saved: \(message) Use Retry Save on the database to save them.")
                        .accessibilityIdentifier("password-import.save-failed")
                }
                Text("Check the imported entries, then delete the export file. It contains your passwords unencrypted.")
            }
        }
    }

    private var destinationGroupName: String {
        sessionViewModel.group(withID: viewModel.destinationGroupID)?.name ?? ""
    }

    private static func reasonText(_ reason: PasswordImportPreview.SkipReason) -> String {
        switch reason {
        case .columnCountMismatch:
            String(localized: "Wrong number of values")
        case .malformedQuoting:
            String(localized: "Damaged quotation marks")
        case .noLoginData:
            String(localized: "No login data")
        }
    }

    private func progressBadge(_ title: LocalizedStringKey) -> some View {
        ProgressView(title)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("password-import.error")
    }
}
