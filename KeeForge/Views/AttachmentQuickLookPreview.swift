import QuickLook
import SwiftUI

#if os(iOS)
/// `UIViewControllerRepresentable` wrapper around `QLPreviewController` that
/// previews a single file at `url`. The presenter owns the temp file's
/// lifecycle; this view only displays it.
struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#else
/// Interim macOS stub — the native Mac Quick Look preview (QLPreviewPanel /
/// `.quickLookPreview`) lands in slice 06 of the macOS port. Until then the
/// sheet names the attachment and points at the share/export action.
struct AttachmentQuickLookPreview: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text(url.lastPathComponent)
                .font(.headline)

            Text("Attachment preview isn't available on Mac yet. Use the share button to export the file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 220)
    }
}
#endif
