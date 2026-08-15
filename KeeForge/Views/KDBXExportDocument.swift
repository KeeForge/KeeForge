import SwiftUI
import UniformTypeIdentifiers

/// Wraps raw KDBX bytes for `.fileExporter`, used by database creation and
/// the export-copy / export-backup flows.
struct KDBXExportDocument: FileDocument {
    let data: Data

    static var readableContentTypes: [UTType] {
        [DocumentPickerService.databaseContentType]
    }

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
