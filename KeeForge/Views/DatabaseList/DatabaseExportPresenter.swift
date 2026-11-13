import SwiftUI

enum DatabaseExportRequest: Identifiable, Equatable {
    case currentCopy(DatabaseReference)
    case pendingLocal(PendingLocalSaveStore.Receipt, DatabaseReference)
    case backup(DatabaseExportService.Backup, DatabaseReference)

    var id: String {
        switch self {
        case .pendingLocal(let receipt, let reference):
            "pending-local-\(reference.id)-\(receipt.id)"
        case .currentCopy(let reference):
            "current-copy-\(reference.id.uuidString)"
        case .backup(let backup, let reference):
            "backup-\(reference.id.uuidString)-\(backup.url.lastPathComponent)"
        }
    }
}

/// The current-copy action is a Files save on macOS and the share sheet on iOS.
enum DatabaseExportLabels {
    static var currentCopy: String {
        #if os(macOS)
        String(localized: "Export Copy…")
        #else
        String(localized: "Share…")
        #endif
    }

    static var failureTitle: String {
        #if os(macOS)
        String(localized: "Couldn’t Export Database")
        #else
        String(localized: "Couldn’t Share Database")
        #endif
    }
}

extension View {
    /// Loads the requested database bytes and hands them on: a Files save
    /// panel on macOS, the share sheet on iOS (which offers Save to Files).
    /// Sets `request` back to nil once that closes or loading fails.
    func databaseExporter(request: Binding<DatabaseExportRequest?>) -> some View {
        modifier(DatabaseExportPresenter(request: request))
    }
}

private struct DatabaseExportPresenter: ViewModifier {
    @Binding var request: DatabaseExportRequest?

    @State private var payload: DatabaseExportService.ExportPayload?
    @State private var isExporterPresented = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) {
                guard let request else { return }
                await load(request)
            }
            #if os(macOS)
            .fileExporter(
                isPresented: $isExporterPresented,
                document: payload.map { KDBXExportDocument(data: $0.data) },
                contentType: DocumentPickerService.databaseContentType,
                defaultFilename: payload?.suggestedFilename
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
                finish()
            }
            // Cancelling the exporter only flips `isPresented`; `onCompletion`
            // fires for success and failure alone.
            .onChange(of: isExporterPresented) { _, isPresented in
                if !isPresented {
                    finish()
                }
            }
            #else
            .background {
                DatabaseShareSheet(fileURL: shareURL) {
                    finish()
                }
            }
            #endif
            .alert(
                DatabaseExportLabels.failureTitle,
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") {
                    errorMessage = nil
                }
                .accessibilityIdentifier("database-export.error.ok")
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func load(_ request: DatabaseExportRequest) async {
        do {
            let loaded: DatabaseExportService.ExportPayload
            switch request {
            case .pendingLocal(let receipt, let reference):
                let data = try await Task.detached {
                    try PendingLocalSaveStore.export(receipt, for: reference.id)
                }.value
                loaded = DatabaseExportService.ExportPayload(
                    data: data, suggestedFilename: "\(reference.displayName)-autofill-snapshot.kdbx"
                )
            case .currentCopy(let reference):
                loaded = try await DatabaseExportService.exportCurrentCopy(for: reference)
            case .backup(let backup, let reference):
                loaded = try await DatabaseExportService.exportBackup(backup, for: reference)
            }
            guard !Task.isCancelled else { return }
            #if os(macOS)
            payload = loaded
            isExporterPresented = true
            #else
            let staged = try await Task.detached {
                try DatabaseExportService.stageShareFile(loaded)
            }.value
            guard !Task.isCancelled else {
                DatabaseExportService.removeShareFile(staged)
                return
            }
            shareURL = staged
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            finish()
        }
    }

    private func finish() {
        isExporterPresented = false
        payload = nil
        if let shareURL {
            DatabaseExportService.removeShareFile(shareURL)
        }
        shareURL = nil
        request = nil
    }
}

#if os(iOS)
/// Presents `UIActivityViewController` for `fileURL` from the view it backs,
/// so it lands in whatever sheet hosts that view. SwiftUI's `ShareLink` cannot
/// be opened programmatically, and the bytes load only after the tap.
private struct DatabaseShareSheet: UIViewControllerRepresentable {
    let fileURL: URL?
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.onComplete = onComplete
        guard let fileURL, context.coordinator.presentedURL != fileURL else { return }
        context.coordinator.presentedURL = fileURL
        guard host.view.window != nil, host.presentedViewController == nil else {
            let onComplete = onComplete
            Task { @MainActor in onComplete() }
            return
        }

        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, _ in
            coordinator.presentedURL = nil
            coordinator.onComplete()
        }
        // iPad shows it as a popover; the host spans the whole list or form,
        // so center it rather than pointing an arrow at nothing in particular.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        host.present(controller, animated: true)
    }

    @MainActor
    final class Coordinator {
        var presentedURL: URL?
        var onComplete: () -> Void = {}
    }
}
#endif
