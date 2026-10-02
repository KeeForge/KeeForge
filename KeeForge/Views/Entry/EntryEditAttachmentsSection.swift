import SwiftUI
import UniformTypeIdentifiers

/// The entry editor's attachment list: remove existing files, add new ones.
/// The file importer lives on `EntryEditView`, which also has to dismiss it
/// for a lock prompt, so Add only raises `isImporterPresented`.
struct EntryEditAttachmentsSection: View {
    @Bindable var formViewModel: EntryEditViewModel
    let databaseViewModel: DatabaseViewModel
    @Binding var isImporterPresented: Bool
    let isImporting: Bool

    var body: some View {
        Section("Attachments") {
            ForEach(Array(formViewModel.attachments.enumerated()), id: \.element.id) { index, attachment in
                EditableAttachmentRow(
                    attachment: attachment,
                    byteCount: byteCount(of: attachment),
                    index: index,
                    onRemove: { formViewModel.removeAttachment(id: attachment.id) }
                )
            }

            HStack {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Add Attachment", systemImage: "plus")
                }
                .disabled(isImporting)
                .accessibilityIdentifier("entry-edit.attachment.add")

                if isImporting {
                    Spacer()
                    ProgressView()
                        .accessibilityIdentifier("entry-edit.attachment.importing")
                }
            }
        }
    }

    private func byteCount(of attachment: EntryEditViewModel.Attachment) -> Int? {
        switch attachment.source {
        case .existing(let stored):
            return databaseViewModel.attachmentByteCount(for: stored)
        case .new(let data):
            return data.count
        }
    }
}

private struct EditableAttachmentRow: View {
    let attachment: EntryEditViewModel.Attachment
    let byteCount: Int?
    let index: Int
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName)
                sizeText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Borderless so a tap elsewhere in the row does not trigger it.
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier("entry-edit.attachment.remove.\(index)")
            .macHelp(String(localized: "Remove Attachment"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry-edit.attachment.row.\(index)")
    }

    private var displayName: String {
        attachment.name.isEmpty ? "?" : attachment.name
    }

    private var sizeText: Text {
        guard let byteCount else { return Text("Unavailable") }
        return Text(verbatim: Self.byteCountFormatter.string(fromByteCount: Int64(byteCount)))
    }

    private var removeLabel: Text {
        Text("Remove attachment \(attachment.name)")
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// The editor's file importer and its failure alert, kept out of
/// `EntryEditView.body`, whose modifier chain is already at the limit of what
/// the compiler type-checks in reasonable time.
struct EntryAttachmentImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var isImporting: Bool
    @Binding var errorMessage: String?
    let onLoad: (EntryAttachmentFileLoader.LoadedFile) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .alert("Couldn’t Add Attachment", isPresented: isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    errorMessage = nil
                }
            }
        )
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        let urls: [URL]
        switch result {
        case .success(let picked):
            urls = picked
        case .failure(let error):
            errorMessage = error.localizedDescription
            return
        }
        guard urls.isEmpty == false else { return }

        isImporting = true
        Task { @MainActor in
            let loaded = await EntryAttachmentFileLoader.load(urls)
            loaded.files.forEach(onLoad)
            if let error = loaded.error {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

enum EntryAttachmentFileLoader {
    struct LoadedFile: Sendable {
        let name: String
        let data: Data
    }

    /// Reads the picked files off the main actor. Stops at the first file
    /// that cannot be read and returns what was read before it with the error,
    /// so one unreadable pick does not throw away the others.
    static func load(_ urls: [URL]) async -> (files: [LoadedFile], error: Error?) {
        await Task.detached(priority: .userInitiated) {
            var files: [LoadedFile] = []
            for url in urls {
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try CoordinatedFileReader.readData(from: url)
                    files.append(LoadedFile(name: url.lastPathComponent, data: data))
                } catch {
                    return (files, error)
                }
            }
            return (files, nil)
        }.value
    }
}
