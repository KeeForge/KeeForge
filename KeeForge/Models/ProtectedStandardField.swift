import Foundation

/// A standard text field the database can mark protected. A protected one is gated like a protected
/// custom field on every app surface. Title is not one: it names the entry on every list and screen.
enum ProtectedStandardField: CaseIterable, Sendable {
    case username, url, notes

    /// The KDBX `<String>` key.
    var key: String {
        switch self {
        case .username: "UserName"
        case .url: "URL"
        case .notes: "Notes"
        }
    }

    func value(in entry: KPEntry) -> String {
        switch self {
        case .username: entry.username
        case .url: entry.url
        case .notes: entry.notes
        }
    }
}

extension KPEntry {
    func isProtected(_ field: ProtectedStandardField) -> Bool {
        protectedStringKeys.contains(field.key)
    }
}
