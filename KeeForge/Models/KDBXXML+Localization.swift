import Foundation
import KDBXXML

// KDBXXML throws plain errors; KeeForge owns their user-facing text.

extension KDBXDocument.ReadError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML, .unexpectedRootElement:
            String(localized: "Failed to parse database XML")
        case .invalidProtectedValue:
            String(localized: "The database contains a protected value that could not be decoded.")
        }
    }
}

extension KDBXDocument.TextError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidXMLCharacter(let scalar):
            String(
                format: String(localized: "The database contains an unsupported character (%@). Remove it from your text before saving."),
                scalar.codePointText
            )
        }
    }
}

/// A `WriteError` with the title or name of the entry or group it points at,
/// which the error itself carries only as a UUID.
struct DocumentWriteFailure: LocalizedError, Equatable {
    let error: KDBXDocument.WriteError
    /// `nil` when the owner is not an entry or group, or has no visible name.
    let ownerName: String?

    var errorDescription: String? {
        let (scalar, location): (Unicode.Scalar, KDBXDocument.WriteError.Location) = switch error {
        case .invalidXMLCharacter(let scalar, let location): (scalar, location)
        }
        let character = scalar.codePointText
        guard let part = location.part.displayName else {
            return KDBXDocument.TextError.invalidXMLCharacter(scalar).errorDescription
        }
        switch (location.owner, ownerName) {
        case (.entry, let name?):
            return String(
                format: String(localized: "The entry “%1$@” contains an unsupported character (%2$@) in “%3$@”. Remove it before saving."),
                name, character, part
            )
        case (.historyEntry, let name?):
            return String(
                format: String(localized: "An earlier version of the entry “%1$@” contains an unsupported character (%2$@) in “%3$@”, so the database can’t be saved."),
                name, character, part
            )
        case (.group, let name?):
            return String(
                format: String(localized: "The group “%1$@” contains an unsupported character (%2$@) in “%3$@”. Remove it before saving."),
                name, character, part
            )
        default:
            return String(
                format: String(localized: "The database contains an unsupported character (%1$@) in “%2$@”, so it can’t be saved."),
                character, part
            )
        }
    }
}

extension DocumentWriteFailure {
    init(_ error: KDBXDocument.WriteError, in document: KDBXDocument) {
        self.error = error
        let location = switch error {
        case .invalidXMLCharacter(_, let location): location
        }
        let name: String? = switch location.owner {
        case .document, .meta, .root: nil
        case .group(let uuid): document.root.allGroups.last { $0.uuid == uuid }?.name
        case .entry(let uuid), .historyEntry(let uuid):
            document.root.allEntries.last { $0.uuid == uuid }?.strings.last { $0.key == "Title" }?.value
        }
        ownerName = name.map(\.displayableXMLText).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension KDBXDocument.WriteError: @retroactive LocalizedError {
    /// Without a document to name the owner; `KDBXWriter` throws
    /// `DocumentWriteFailure` instead.
    public var errorDescription: String? {
        DocumentWriteFailure(self, in: KDBXDocument()).errorDescription
    }
}

private extension KDBXDocument.WriteError.Location.Part {
    var displayName: String? {
        switch self {
        case .field(let key):
            switch key {
            case "Title": String(localized: "Title")
            case "UserName": String(localized: "Username")
            case "Password": String(localized: "Password")
            case "URL": String(localized: "URL")
            case "Notes": String(localized: "Notes")
            default: key.displayableXMLText
            }
        case .attachment(let key): key.displayableXMLText
        case .element("Name"): String(localized: "Name")
        case .element("Notes"): String(localized: "Notes")
        case .element("Tags"): String(localized: "Tags")
        case .element(let name?): name
        case .element(nil): nil
        }
    }
}

private extension KDBXDocument.Root {
    var allGroups: [KDBXDocument.Group] {
        groups.flatMap { [$0] + $0.allGroups }
    }

    var allEntries: [KDBXDocument.Entry] {
        entries + allGroups.flatMap(\.entries)
    }
}

private extension KDBXDocument.Group {
    var allGroups: [KDBXDocument.Group] {
        groups.flatMap { [$0] + $0.allGroups }
    }
}

private extension Unicode.Scalar {
    var codePointText: String {
        String(format: "U+%04X", value)
    }
}

private extension String {
    /// The text without the characters a save rejects, which would otherwise
    /// render as nothing or as a box.
    var displayableXMLText: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { (try? KDBXDocument.validate(text: String($0))) != nil }))
    }
}
