import AppKit
import SwiftUI

@MainActor
final class MacPasswordImportSheet: NSObject {
    let model: PasswordImportViewModel
    let session: DatabaseViewModel
    let panels: MacFilePanels
    private let presentation: MacWorkspacePresentation
    private let source = MacPasswordImportSource()
    private let observation = MacObservation()
    private var picker: MacFormSheetController?
    private var ended = false
    private let cycle: Int
    private(set) lazy var shell = makeShell()

    init(session: DatabaseViewModel, presentation: MacWorkspacePresentation,
         panels: MacFilePanels = MacFilePanels(),
         fileLoader: @escaping PasswordImportViewModel.FileLoader = PasswordImportViewModel.loadApplePasswordsExport) {
        self.session = session
        self.presentation = presentation
        self.panels = panels
        cycle = session.lockCycleID
        let destination = session.groupDestinationOptions(currentGroupID: nil).first { $0.id == session.workspace.selectedGroupID }?.id
        model = PasswordImportViewModel(
            destinationGroupID: destination ?? session.workspaceRootGroupID ?? UUID(),
            duplicateCandidates: { [weak session] in session?.importDuplicateCandidates ?? [] },
            importOperation: { [weak session] drafts, group in
                guard let session, MacWorkspaceCommands(session: session, presentation: presentation).canImportPasswords else {
                    throw DatabaseViewModel.PasswordImportFailure.sessionUnavailable
                }
                return try await session.importEntries(drafts, into: group)
            }, fileLoader: fileLoader)
        super.init()
        observation.start(reading: { [weak self] in
            guard let self else { return }
            _ = model.canImport
            _ = model.summary
            _ = model.isLoading
            _ = model.isImporting
            _ = session.isReadOnly
            _ = canImportIntoSession
        }, onChange: { [weak self] _ in self?.update() })
        update()
    }

    private func makeShell() -> MacFormSheetController {
        let host = NSHostingController(rootView: MacPasswordImportForm(model: model, session: session, presentation: presentation, source: source,
            choose: { [weak self] in self?.chooseFile() }, selectGroup: { [weak self] in self?.selectGroup() }))
        host.sizingOptions = []
        let shell = MacFormSheetController(title: String(localized: "Import Passwords"), content: host,
            size: NSSize(width: 600, height: 560), defaultTitle: String(localized: "Import"))
        shell.window?.setAccessibilityIdentifier("password-import.sheet")
        shell.cancelButton.setAccessibilityIdentifier("password-import.cancel")
        shell.cancellationScope.register { [weak self] in self?.discard() }
        shell.defaultButton.target = self
        shell.defaultButton.action = #selector(confirm)
        shell.defaultButton.setAccessibilityIdentifier("password-import.import")
        return shell
    }

    private var isCurrent: Bool { !ended && session.state == .unlocked && session.lockCycleID == cycle }

    private var canImportIntoSession: Bool {
        isCurrent && MacWorkspaceCommands(session: session, presentation: presentation).canImportPasswords
    }

    private func update() {
        guard isCurrent else { discard(); return }
        shell.canConfirm = model.summary != nil || (model.canImport && canImportIntoSession)
        shell.setBusy(model.isLoading || model.isImporting,
            label: model.isImporting ? String(localized: "Importing Passwords") : String(localized: "Reading File"))
        if model.summary != nil {
            shell.setTitle(String(localized: "Import Finished"))
            shell.window?.setContentSize(NSSize(width: 400, height: 260))
            shell.defaultButton.title = String(localized: "Done")
            shell.defaultButton.setAccessibilityIdentifier("password-import.done")
            shell.cancelButton.isHidden = true
        }
    }

    @objc func confirm() {
        guard isCurrent else { return }
        if model.summary != nil { shell.end(); return }
        guard model.canImport, canImportIntoSession else { return }
        Task { [weak self] in
            guard let self, isCurrent else { return }
            await model.performImport()
            guard isCurrent else { model.discardPreview(); return }
            update()
        }
    }

    func chooseFile() {
        guard canImportIntoSession else { return }
        panels.window = shell.window
        Task { [weak self] in
            guard let self, let url = await panels.chooseImportFile(), canImportIntoSession else { return }
            source.name = url.lastPathComponent
            await model.loadFile(at: url)
            if !isCurrent { model.discardPreview() }
        }
    }

    private func selectGroup() {
        guard isCurrent, picker == nil, let window = shell.window else { return }
        let groupModel = MacGroupPickerModel(purpose: .importDestination, database: session, current: model.destinationGroupID)
        let body = MacGroupPickerSheet(model: groupModel)
        let child = MacFormSheetController(title: groupModel.title, content: body, size: NSSize(width: 500, height: 460), defaultTitle: groupModel.confirmTitle)
        child.canConfirm = groupModel.canConfirm
        body.onSelectionChange = { [weak child] in child?.canConfirm = groupModel.canConfirm }
        body.onDoubleClick = { [weak child] in child?.performDefault() }
        picker = child
        child.begin(on: window) { [weak self] confirmed in
            guard let self else { return }
            if confirmed, isCurrent, groupModel.canConfirm, let id = groupModel.selection { model.destinationGroupID = id }
            picker = nil
        }
    }

    func discard() {
        guard !ended else { return }
        ended = true
        observation.cancel()
        panels.cancel()
        picker?.end()
        picker = nil
        model.discardPreview()
        source.name = nil
    }
}

@MainActor @Observable
private final class MacPasswordImportSource {
    var name: String?
}

private struct MacPasswordImportForm: View {
    @Bindable var model: PasswordImportViewModel
    let session: DatabaseViewModel
    let presentation: MacWorkspacePresentation
    let source: MacPasswordImportSource
    let choose: () -> Void
    let selectGroup: () -> Void

    var body: some View {
        ScrollView {
            if let summary = model.summary {
                MacImportFinishedSheet(summary: summary)
            } else {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("password-import.error")
                }
                Form {
                    LabeledContent("Apple Passwords Export") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if let name = source.name { Label(name, systemImage: "doc") }
                                Button(action: choose) {
                                    if source.name == nil { Text("Choose Export File…") } else { Text("Choose Another File…") }
                                }.accessibilityIdentifier("password-import.choose-file")
                            }
                            caption("Choose the CSV file exported from the Passwords app. Files from other password managers are not supported yet. The export file is not encrypted: delete it once you have checked the imported entries.")
                        }
                    }
                    if let preview = model.preview {
                        Divider()
                        LabeledContent("Entries to Import") { Text(model.itemsToImport.count, format: .number).accessibilityIdentifier("password-import.import-count") }
                        LabeledContent("With Verification Codes") { Text(preview.verificationCodeCount, format: .number) }
                        LabeledContent("Unsupported Verification Codes") {
                            VStack(alignment: .leading) {
                                Text(preview.unsupportedVerificationCodeCount, format: .number)
                                if preview.unsupportedVerificationCodeCount > 0 { caption("KeeForge generates only time-based verification codes. Other code setups are kept in a protected field named OTPAuth.") }
                            }
                        }
                        LabeledContent("Rows That Can't Be Imported") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(preview.skippedRows.count, format: .number).accessibilityIdentifier("password-import.skipped-count")
                                ForEach(preview.skippedRows, id: \.row) { row in
                                    HStack { Text("Row \(row.row)"); Text(verbatim: "·"); Text(reason(row.reason)) }
                                        .font(.caption).accessibilityIdentifier("password-import.skipped-row")
                                }
                                if !preview.skippedRows.isEmpty { caption("Row numbers count the header as row 1, as a spreadsheet app shows them.") }
                            }
                        }
                        Divider()
                        LabeledContent("Likely Duplicates") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.likelyDuplicateRows.count, format: .number).accessibilityIdentifier("password-import.duplicate-count")
                                Toggle("Skip Likely Duplicates", isOn: $model.skipsLikelyDuplicates).accessibilityIdentifier("password-import.skip-duplicates-toggle")
                                caption("These rows have the same website and user name as an entry already in this database, or as an earlier row of the file.")
                            }
                        }
                        Divider()
                        LabeledContent("Import Into") {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(session.group(withID: model.destinationGroupID)?.name ?? "", systemImage: "folder")
                                    Button("Select Group…", action: selectGroup).accessibilityIdentifier("password-import.destination")
                                }
                                caption("Imported passwords are added as new entries. Existing entries are not changed.")
                            }
                        }
                    }
                }.formStyle(.columns)
            }
        }
        .disabled(model.isLoading || model.isImporting ||
                  (model.summary == nil && !MacWorkspaceCommands(session: session, presentation: presentation).canImportPasswords))
    }

    private func caption(_ text: LocalizedStringKey) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func reason(_ reason: PasswordImportPreview.SkipReason) -> String {
        switch reason {
        case .columnCountMismatch: String(localized: "Wrong number of values")
        case .malformedQuoting: String(localized: "Damaged quotation marks")
        case .noLoginData: String(localized: "No login data")
        }
    }
}

struct MacImportFinishedSheet: View {
    let summary: PasswordImportViewModel.Summary
    var body: some View {
        Form {
            LabeledContent("Imported") { Text(summary.importedCount, format: .number).accessibilityIdentifier("password-import.imported-count") }
            LabeledContent("Skipped") { Text(summary.skippedCount, format: .number).accessibilityIdentifier("password-import.summary-skipped-count") }
            Text("Check the imported entries, then delete the export file. It contains your passwords unencrypted.")
                .font(.caption).foregroundStyle(.secondary)
            switch summary.outcome {
            case .saved: EmptyView()
            case .awaitingConflictResolution:
                Text("This database changed outside KeeForge, so the imported entries are not saved yet. Choose how to resolve the save conflict to finish saving them.")
            case .saveFailed(let message):
                Text("The imported entries were added but not saved: \(message) Use Retry Save on the database to save them.").accessibilityIdentifier("password-import.save-failed")
            }
        }.formStyle(.columns)
    }
}
