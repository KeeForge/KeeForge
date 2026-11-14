#if os(macOS)
import Foundation

/// What a locked Mac database window may say about its database: names and
/// the storage provider, never a path or server address.
struct MacLockedDatabaseSummary: Equatable {
    let name: String
    /// `file · storage · last opened`, under the locked page's title.
    let subline: String
    /// `file · storage`, under the opening page's title and in the Databases window.
    let fileAndStorage: String
    /// `name · file · storage`, under the recovery page's title.
    let recoverySubtitle: String
    let keyFileName: String?

    init(reference: DatabaseReference, lastOpened: String?) {
        name = reference.displayName
        fileAndStorage = Self.fileAndStorage(for: reference)
        subline = Self.joined([fileAndStorage, lastOpened].compactMap(\.self))
        recoverySubtitle = Self.joined([reference.displayName, fileAndStorage])
        keyFileName = reference.keyFileFilename
    }

    static func storageName(for reference: DatabaseReference) -> String {
        reference.cloudProviderKind?.displayName ?? String(localized: "On This Mac")
    }

    static func fileAndStorage(for reference: DatabaseReference) -> String {
        joined([reference.filename, storageName(for: reference)])
    }

    private static func joined(_ parts: [String]) -> String {
        parts.joined(separator: MacDatabaseStatus.separator)
    }
}
#endif
