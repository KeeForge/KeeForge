import Foundation

/// State for the Import Passwords screen (`../Views/DatabaseList/PasswordImportView.swift`).
/// Adding and saving the entries lives in `DatabaseViewModel.importEntries`,
/// injected as a closure so this model tests without an unlocked session.
@MainActor @Observable
final class PasswordImportViewModel {
    typealias ImportOperation = @MainActor (
        _ drafts: [EntryDraftPayload],
        _ groupID: UUID
    ) async throws -> DatabaseViewModel.PasswordImportOutcome
    typealias FileLoader = @Sendable (URL) async throws -> PasswordImportPreview

    struct Summary: Equatable {
        let importedCount: Int
        let skippedCount: Int
        let outcome: DatabaseViewModel.PasswordImportOutcome
    }

    private(set) var preview: PasswordImportPreview?
    private(set) var fileName: String?
    private(set) var likelyDuplicateRows: Set<Int> = []
    private(set) var summary: Summary?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isImporting = false
    var skipsLikelyDuplicates = true
    var destinationGroupID: UUID

    private let duplicateCandidates: @MainActor () -> [PasswordImport.LoginIdentity]
    private let importOperation: ImportOperation
    private let fileLoader: FileLoader
    private var loadID = 0

    init(
        destinationGroupID: UUID,
        duplicateCandidates: @escaping @MainActor () -> [PasswordImport.LoginIdentity],
        importOperation: @escaping ImportOperation,
        fileLoader: @escaping FileLoader = PasswordImportViewModel.loadApplePasswordsExport
    ) {
        self.destinationGroupID = destinationGroupID
        self.duplicateCandidates = duplicateCandidates
        self.importOperation = importOperation
        self.fileLoader = fileLoader
    }

    var itemsToImport: [PasswordImportPreview.Item] {
        guard let preview else { return [] }
        guard skipsLikelyDuplicates else { return preview.items }
        return preview.items.filter { likelyDuplicateRows.contains($0.row) == false }
    }

    var canImport: Bool {
        isLoading == false && isImporting == false && summary == nil && itemsToImport.isEmpty == false
    }

    func loadFile(at url: URL) async {
        discardPreview()
        let currentLoadID = loadID
        summary = nil
        errorMessage = nil
        isLoading = true
        defer {
            if currentLoadID == loadID {
                isLoading = false
            }
        }

        do {
            let loaded = try await fileLoader(url)
            // A newer pick, or leaving the screen, supersedes this read.
            guard currentLoadID == loadID else { return }
            preview = loaded
            fileName = url.lastPathComponent
            likelyDuplicateRows = loaded.likelyDuplicateRows(existing: duplicateCandidates())
            skipsLikelyDuplicates = true
        } catch {
            guard currentLoadID == loadID else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func performImport() async {
        guard canImport, let preview else { return }
        let items = itemsToImport
        let skippedCount = preview.skippedRows.count + preview.items.count - items.count

        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let outcome = try await importOperation(items.map(\.draft), destinationGroupID)
            summary = Summary(importedCount: items.count, skippedCount: skippedCount, outcome: outcome)
            discardPreview()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Drops every plaintext value read from the export file. The screen calls
    /// it when it goes away and when the database locks.
    func discardPreview() {
        loadID += 1
        isLoading = false
        preview = nil
        fileName = nil
        likelyDuplicateRows = []
    }

    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as PasswordImportError:
            return error.localizedDescription
        case DatabaseViewModel.PasswordImportFailure.destinationUnavailable:
            return String(localized: "The selected group no longer exists. Choose another group.")
        case DatabaseViewModel.PasswordImportFailure.saveInProgress:
            return String(localized: "KeeForge is still saving this database. Try again in a moment.")
        case DatabaseViewModel.PasswordImportFailure.sessionUnavailable:
            return String(localized: "Unlock the database to import passwords.")
        default:
            return error.localizedDescription
        }
    }

    /// Reads the picked file in place — no copy is made — and parses it off
    /// the main actor.
    nonisolated static func loadApplePasswordsExport(from url: URL) async throws -> PasswordImportPreview {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= PasswordImport.maximumFileSize else {
                throw PasswordImportError.fileTooLarge
            }
            var data = try Data(contentsOf: url)
            defer { SecureWipe.wipe(&data) }
            return try ApplePasswordsCSVImporter.preview(from: data)
        }.value
    }
}
