import SwiftUI

struct CloudRecoveryView: View {
    @State private var uploads: [PendingUploadQueue.StoredMarker] = []
    @State private var references: [UUID: DatabaseReference] = [:]
    @State private var failure: String?
    @State private var busy = false
    @State private var exporting = false
    @State private var document = KDBXExportDocument(data: Data())
    @State private var filename = "KeeForge.kdbx"

    var body: some View {
        List {
            Section {
                Text("A cloud request may still be running. Keep an encrypted copy. Uncertain requests will not be sent again automatically.")
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            ForEach(uploads, id: \.id) { stored in
                Section(references[stored.marker.databaseId]?.displayName ?? String(localized: "Cloud")) {
                    Button("Export Encrypted Copy") {
                        let reference = references[stored.marker.databaseId]
                        perform {
                            let data = try PendingUploadQueue.readImmutablePayload(stored)
                            let name = reference.map { DatabaseExportService.currentCopyFilename(for: $0, date: .now) }
                                ?? "KeeForge copy \(Int(Date().timeIntervalSince1970)).kdbx"
                            return (data, name)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cloud Recovery")
        .disabled(busy)
        .task { await reload() }
        .fileExporter(isPresented: $exporting, document: document,
            contentType: DocumentPickerService.databaseContentType, defaultFilename: filename) { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
            }
    }

    private func reload() async {
        references = await Task.detached {
            Dictionary(uniqueKeysWithValues: DatabaseListStore.databases.map { ($0.id, $0) })
        }.value
        do { uploads = try await Task.detached { try PendingUploadQueue.readJournal() }.value }
        catch {
            failure = error.localizedDescription
            uploads = await Task.detached {
                PendingUploadQueue.listMarkers().filter { CloudJournalDecision.state(of: $0.marker) != .invalid }
            }.value
        }
    }

    private func perform(_ operation: @escaping @Sendable () throws -> (Data, String)) {
        busy = true
        Task {
            do {
                let result = try await Task.detached(operation: operation).value
                document = KDBXExportDocument(data: result.0)
                filename = result.1
                exporting = true
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}
