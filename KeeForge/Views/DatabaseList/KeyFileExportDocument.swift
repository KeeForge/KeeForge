import KDBXKit
import SwiftUI
import UniformTypeIdentifiers

/// A newly generated key file for `.fileExporter`, used by database creation
/// and the master key change.
struct KeyFileExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: KDBXKeyFile.generatedFileExtension, conformingTo: .xml) ?? .xml

    static var readableContentTypes: [UTType] {
        [contentType]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    static func generate() throws -> KeyFileExportDocument {
        KeyFileExportDocument(data: try KDBXKeyFile.generate())
    }

    /// Names the key file after its database, as KeePassXC does.
    static func defaultFilename(forDatabaseFilename databaseFilename: String) -> String {
        "\((databaseFilename as NSString).deletingPathExtension).\(KDBXKeyFile.generatedFileExtension)"
    }

    static func creationFailureAlert(for error: Error) -> DocumentPickerService.SelectionAlert? {
        if DocumentPickerService.isUserCancellation(error) {
            return nil
        }

        return DocumentPickerService.SelectionAlert(
            title: String(localized: "Couldn’t Create Key File"),
            message: error.localizedDescription
        )
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
