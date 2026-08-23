import SwiftUI

/// Shows an entry's read-only attachment list. Rows resolve their bytes
/// lazily against the database's binary pool via `DatabaseViewModel`, write
/// a short-lived plaintext temp file for QuickLook preview / sharing, and
/// clean that temp file up as soon as the row's preview/share flow ends.
struct AttachmentsSection: View {
    let attachments: [KPAttachment]
    @Bindable var viewModel: DatabaseViewModel

    var body: some View {
        Section("Attachments") {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                AttachmentRow(attachment: attachment, index: index, viewModel: viewModel)
            }
        }
    }
}

private struct AttachmentRow: View {
    let attachment: KPAttachment
    let index: Int
    @Bindable var viewModel: DatabaseViewModel

    @State private var isResolving = false
    @State private var isDangling = false
    @State private var previewURL: URL?
    @State private var byteCount: Int?

    private var displayName: String {
        attachment.name.isEmpty ? "?" : attachment.name
    }

    var body: some View {
        Button(action: preparePreview) {
            HStack {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .foregroundStyle(isDangling ? .secondary : .primary)
                    if let byteCount {
                        Text(Self.byteCountFormatter.string(fromByteCount: Int64(byteCount)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isDangling {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isResolving {
                    ProgressView()
                } else if let previewURL {
                    ShareLink(item: previewURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("entry.attachment.share")
                }
            }
        }
        .disabled(isDangling)
        // Each row carries a stable per-index identifier (`entry.attachment.0`,
        // `entry.attachment.1`, ...). Because SwiftUI collapses the button into a
        // single accessibility element, an additional `entry.attachment.row`
        // identifier on the same element would be shadowed by this one, so tests
        // enumerate rows via the `entry.attachment.<index>` prefix instead.
        .accessibilityIdentifier("entry.attachment.\(index)")
        .attachmentQuickLookPreview(url: $previewURL, onDismiss: cleanUpTempFile)
        .onDisappear(perform: cleanUpTempFile)
    }

    private func preparePreview() {
        guard isResolving == false, previewURL == nil else { return }
        isResolving = true

        Task {
            guard let data = await viewModel.attachmentData(for: attachment) else {
                await MainActor.run {
                    isDangling = true
                    isResolving = false
                }
                return
            }

            let url = try? AttachmentPreviewFileStore.write(data, suggestedName: displayName)

            await MainActor.run {
                byteCount = data.count
                previewURL = url
                isResolving = false
            }
        }
    }

    private func cleanUpTempFile() {
        guard let previewURL else { return }
        AttachmentPreviewFileStore.remove(previewURL)
        self.previewURL = nil
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
