import SwiftUI

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
                row(for: attachment, index: index)
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

    private func row(for attachment: EntryEditViewModel.Attachment, index: Int) -> some View {
        let byteCount: Int? = switch attachment.source {
        case .existing(let stored):
            databaseViewModel.attachmentByteCount(for: stored)
        case .new(let data):
            data.count
        }

        return HStack {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attachment.name.isEmpty ? "?" : attachment.name)
                Group {
                    if let byteCount {
                        Text(Self.byteCountFormatter.string(fromByteCount: Int64(byteCount)))
                    } else {
                        Text("Unavailable")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Borderless so a tap elsewhere in the row does not trigger it.
            Button(role: .destructive) {
                formViewModel.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove attachment \(attachment.name)"))
            .accessibilityIdentifier("entry-edit.attachment.remove.\(index)")
            .macHelp(String(localized: "Remove Attachment"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry-edit.attachment.row.\(index)")
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
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
