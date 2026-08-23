import SwiftUI

enum DatabaseExportRequest: Identifiable, Equatable {
    case currentCopy(DatabaseReference)
    case backup(DatabaseExportService.Backup, DatabaseReference)

    var id: String {
        switch self {
        case .currentCopy(let reference):
            "current-copy-\(reference.id.uuidString)"
        case .backup(let backup, let reference):
            "backup-\(reference.id.uuidString)-\(backup.url.lastPathComponent)"
        }
    }
}

extension View {
    /// Loads the requested database bytes and hands them to a Files export.
    /// Sets `request` back to nil once the exporter closes or loading fails.
    func databaseExporter(request: Binding<DatabaseExportRequest?>) -> some View {
        modifier(DatabaseExportPresenter(request: request))
    }
}

private struct DatabaseExportPresenter: ViewModifier {
    @Binding var request: DatabaseExportRequest?

    @State private var payload: DatabaseExportService.ExportPayload?
    @State private var isExporterPresented = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) {
                guard let request else { return }
                await load(request)
            }
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
            .alert(
                "Couldn’t Export Database",
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
            case .currentCopy(let reference):
                loaded = try await DatabaseExportService.exportCurrentCopy(for: reference)
            case .backup(let backup, let reference):
                loaded = try await DatabaseExportService.exportBackup(backup, for: reference)
            }
            guard !Task.isCancelled else { return }
            payload = loaded
            isExporterPresented = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            finish()
        }
    }

    private func finish() {
        isExporterPresented = false
        payload = nil
        request = nil
    }
}
