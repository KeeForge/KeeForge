import QuickLook
import SwiftUI

// MARK: - Cross-platform Quick Look presentation

extension View {
    /// Presents a Quick Look preview of the file at `url` when it is non-nil,
    /// and calls `onDismiss` when the preview closes so the caller can delete
    /// the plaintext temp file.
    ///
    /// Platform split, kept behind one call site:
    /// - **macOS** uses SwiftUI's native `.quickLookPreview(_:)` (macOS 12+).
    ///   The system sets the binding back to `nil` when the panel closes; the
    ///   wrapper binding turns that into an `onDismiss` call.
    /// - **iOS** keeps the `QLPreviewController` representable presented in a
    ///   sheet. The iOS `.quickLookPreview(_:)` modifier does not offer the
    ///   same full-screen, navigable, shareable preview UX, and the existing
    ///   presentation is what `EntryAttachmentsSmokeUITests` drives, so iOS is
    ///   intentionally left on the representable (no iOS behavior change).
    @ViewBuilder
    func attachmentQuickLookPreview(
        url: Binding<URL?>,
        onDismiss: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        quickLookPreview(
            Binding(
                get: { url.wrappedValue },
                set: { newValue in
                    if newValue == nil {
                        // `onDismiss` (temp-file cleanup) is responsible for
                        // clearing the source binding, matching the iOS sheet
                        // path — so it must run while the URL is still set.
                        onDismiss()
                    } else {
                        url.wrappedValue = newValue
                    }
                }
            )
        )
        #else
        sheet(
            isPresented: Binding(
                get: { url.wrappedValue != nil },
                set: { isPresented in
                    if isPresented == false { onDismiss() }
                }
            )
        ) {
            if let previewURL = url.wrappedValue {
                AttachmentQuickLookPreview(url: previewURL)
                    .ignoresSafeArea()
            }
        }
        #endif
    }
}

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
#endif
