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
                AttachmentQuickLookPreview(url: previewURL, onDone: onDismiss)
                    .ignoresSafeArea()
                    .presentationSizing(.page)
            }
        }
        #endif
    }
}

#if os(iOS)
/// `UIViewControllerRepresentable` wrapper around `QLPreviewController` that
/// previews a single file at `url`. The presenter owns the temp file's
/// lifecycle; this view only displays it. Embedded in a navigation controller
/// so Quick Look draws its title and share item — as a bare child it shows
/// nothing but the file — with a Done item because a sheet child gets none.
struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [coordinator = context.coordinator] _ in coordinator.onDone() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ navigationController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onDone = onDone
        (navigationController.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDone: onDone)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var onDone: () -> Void

        init(url: URL, onDone: @escaping () -> Void) {
            self.url = url
            self.onDone = onDone
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
