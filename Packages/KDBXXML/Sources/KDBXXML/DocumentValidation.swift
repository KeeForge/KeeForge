import Foundation

extension KDBXDocument {
    typealias Location = WriteError.Location

    /// Throws `WriteError.invalidXMLCharacter` for the first text the writer
    /// would emit that XML 1.0 cannot carry. Protected values are exempt
    /// because they are base64 on disk. Every fragment is checked, including
    /// one a typed child supersedes: `OpaqueXMLNodes` is public, so a caller
    /// can splice any text into it.
    func validateForWriting() throws {
        try Self.check(meta.unknownXML, owner: .meta)
        try Self.check(root.unknownXML, owner: .root)
        for entry in root.entries {
            try Self.check(entry, owner: .entry(entry.uuid))
        }
        for group in root.groups {
            try Self.check(group)
        }
    }

    private static func check(_ group: Group) throws {
        let owner = Location.Owner.group(group.uuid)
        try check(group.name, owner, .element("Name"))
        try check(group.notes ?? "", owner, .element("Notes"))
        for tag in group.tags ?? [] {
            try check(tag, owner, .element("Tags"))
        }
        try check(group.unknownXML, owner: owner)
        for entry in group.entries {
            try check(entry, owner: .entry(entry.uuid))
        }
        for subgroup in group.groups {
            try check(subgroup)
        }
    }

    private static func check(_ entry: Entry, owner: Location.Owner) throws {
        for tag in entry.tags ?? [] {
            try check(tag, owner, .element("Tags"))
        }
        for field in entry.strings {
            try check(field.key, owner, .field(key: field.key))
            try check(field.isProtected ? "" : field.value, owner, .field(key: field.key))
        }
        for attachment in entry.binaries {
            try check(attachment.key, owner, .attachment(key: attachment.key))
        }
        try check(entry.unknownXML, owner: owner)
        for version in entry.history {
            try check(version, owner: .historyEntry(version.uuid))
        }
    }

    private static func check(_ unknownXML: OpaqueXMLNodes, owner: Location.Owner) throws {
        for node in unknownXML.nodes {
            let written = XMLText.replacingProtectedValues(in: node.xml) { _ in "" }
            try check(written, owner, .element(node.elementName))
        }
    }

    private static func check(_ text: String, _ owner: Location.Owner, _ part: Location.Part) throws {
        if let scalar = XMLText.firstInvalidScalar(in: text) {
            throw WriteError.invalidXMLCharacter(scalar, at: Location(owner: owner, part: part))
        }
    }
}
