import AppKit
import SwiftUI

@MainActor
final class MacDatabaseExporter {
    typealias Load = @MainActor (DatabaseExportRequest) async throws -> DatabaseExportService.ExportPayload
    private let panels: any MacFilePanelPresenting
    private let load: Load
    private let write: @Sendable (Data, URL) async throws -> Void
    private let showError: @MainActor (String) -> Void

    init(panels: any MacFilePanelPresenting, load: @escaping Load = MacDatabaseExporter.load,
         write: @escaping @Sendable (Data, URL) async throws -> Void = { data, url in
             try await Task.detached(priority: .userInitiated) {
                 let scoped = url.startAccessingSecurityScopedResource()
                 defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                 try data.write(to: url)
             }.value
         }, showError: @escaping @MainActor (String) -> Void) {
        self.panels = panels
        self.load = load
        self.write = write
        self.showError = showError
    }

    func export(_ request: DatabaseExportRequest) async {
        do {
            let payload = try await load(request)
            let name: String
            switch request {
            case .currentCopy(let reference): name = reference.filename
            case .backup: name = payload.suggestedFilename
            }
            guard !Task.isCancelled, let url = await panels.saveDatabaseCopy(suggestedName: name), !Task.isCancelled else { return }
            try await write(payload.data, url)
        } catch {
            guard !Task.isCancelled else { return }
            showError(error.localizedDescription)
        }
    }

    static func load(_ request: DatabaseExportRequest) async throws -> DatabaseExportService.ExportPayload {
        switch request {
        case .currentCopy(let reference): try await DatabaseExportService.exportCurrentCopy(for: reference)
        case .backup(let backup, let reference): try await DatabaseExportService.exportBackup(backup, for: reference)
        }
    }

    static func showError(_ reason: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = DatabaseExportLabels.failureTitle
        alert.informativeText = reason
        alert.addButton(withTitle: String(localized: "OK")).setAccessibilityIdentifier("database-export.error.ok")
        if let window { alert.beginSheetModal(for: MacWorkspaceAlerts.topmostSheet(of: window)) }
        else { alert.runModal() }
    }
}

/// Keeps the existing Settings and launcher bindings while using their actual host window.
struct MacDatabaseExportPresenter: NSViewRepresentable {
    @Binding var request: DatabaseExportRequest?

    func makeNSView(context: Context) -> ExportView { ExportView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: ExportView, context: Context) {
        if context.coordinator.requestID != request?.id { context.coordinator.cancel() }
        view.onWindow = { [weak view] in
            guard let view, let window = view.window, let request, context.coordinator.requestID == nil else { return }
            let coordinator = context.coordinator
            coordinator.requestID = request.id
            let generation = coordinator.generation
            coordinator.panels.window = window
            coordinator.task = Task { @MainActor [weak view] in
                let exporter = MacDatabaseExporter(panels: coordinator.panels) { [weak view] in
                    MacDatabaseExporter.showError($0, on: view?.window)
                }
                await exporter.export(request)
                guard generation == coordinator.generation else { return }
                if !Task.isCancelled, self.request?.id == request.id { self.request = nil }
                coordinator.requestID = nil
                coordinator.task = nil
            }
        }
        view.onWindow?()
    }

    static func dismantleNSView(_ view: ExportView, coordinator: Coordinator) {
        view.onWindow = nil
        coordinator.cancel()
    }

    @MainActor final class ExportView: NSView {
        var onWindow: (@MainActor () -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?() }
    }

    @MainActor final class Coordinator {
        let panels = MacFilePanels()
        var requestID: String?
        var generation = UUID()
        var task: Task<Void, Never>?

        func cancel() {
            generation = UUID()
            task?.cancel()
            panels.cancel()
            requestID = nil
            task = nil
        }
    }
}
