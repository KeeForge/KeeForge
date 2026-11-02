import SwiftUI

/// The `ShareLink` item for a database: the same encrypted file Export Copy
/// saves, read and staged only once a share target asks for it.
struct DatabaseShareItem: Transferable {
    let reference: DatabaseReference

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: DocumentPickerService.databaseContentType) { item in
            SentTransferredFile(try await DatabaseExportService.stageShareFile(for: item.reference))
        }
    }
}
