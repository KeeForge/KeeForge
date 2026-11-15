#if os(iOS)
import QuickLook
import SwiftUI

extension View {
    /// Presents a Quick Look preview of the file at `url` in a sheet when it is
    /// non-nil, and calls `onDismiss` when the preview closes so the caller can
    /// delete the plaintext temp file. The Mac uses `MacAttachmentPreviewController`.
    func attachmentQuickLookPreview(
        url: Binding<URL?>,
        onDismiss: @escaping () -> Void
    ) -> some View {
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
    }
}

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
