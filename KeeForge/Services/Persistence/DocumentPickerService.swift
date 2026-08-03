import Foundation
import UniformTypeIdentifiers

enum DocumentPickerService {
    struct SelectionAlert: Identifiable, Equatable {
        let title: String
        let message: String

        var id: String { "\(title)\n\(message)" }
    }

    static let kdbxTypeIdentifier = "com.keevault.kdbx"
    static let databaseContentType = UTType(importedAs: kdbxTypeIdentifier)
    static let databasePickerContentTypes: [UTType] = [databaseContentType, .item]
    static let keyFilePickerContentTypes: [UTType] = [.item]
    private static let kdbxMagic = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])

    static func saveBookmark(for url: URL) throws {
        try SharedVaultStore.saveBookmark(for: url)
    }

    static func loadBookmarkedURL() -> URL? {
        SharedVaultStore.loadBookmarkedURL()
    }

    static func clearBookmark() {
        SharedVaultStore.clearBookmark()
    }

    static func isLikelyDatabaseFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "kdbx"
    }

    static func isSupportedDatabaseFile(
        at url: URL,
        headerReader: (URL, Int) throws -> Data = { try CoordinatedFileReader.readDataPrefix(from: $0, byteCount: $1) }
    ) -> Bool {
        if isLikelyDatabaseFile(url) {
            return true
        }

        guard let header = try? headerReader(url, kdbxMagic.count) else {
            return false
        }

        return hasKDBXHeader(header)
    }

    static func hasKDBXHeader(_ data: Data) -> Bool {
        data.starts(with: kdbxMagic)
    }

    /// Strict 8-byte magic sniff, unlike `isSupportedDatabaseFile(at:)` which
    /// also accepts any `.kdbx` extension. Auto-registration paths use this so
    /// arbitrary non-database files are never claimed.
    static func hasKDBXMagic(at url: URL) -> Bool {
        guard let header = try? CoordinatedFileReader.readDataPrefix(from: url, byteCount: kdbxMagic.count) else {
            return false
        }
        return hasKDBXHeader(header)
    }

    static func invalidDatabaseSelectionAlert() -> SelectionAlert {
        SelectionAlert(
            title: String(localized: "Invalid File"),
            message: String(localized: "Please select a KeePass .kdbx database.")
        )
    }

    static func pickerFailureAlert(for error: Error) -> SelectionAlert? {
        let nsError = error as NSError
        guard nsError.code != NSUserCancelledError else { return nil }

        return SelectionAlert(
            title: String(localized: "Couldn’t Open File"),
            message: nsError.localizedDescription
        )
    }
}
