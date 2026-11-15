import Foundation

extension KDBXDocument {
    typealias Location = WriteError.Location

    /// Throws `WriteError.invalidXMLCharacter` for the first text the writer
    /// would emit that XML 1.0 cannot carry. Protected values are exempt
    /// because they are base64 on disk. Every fragment is checked, including
    /// one a typed child supersedes: `OpaqueXMLNodes` is public, so a caller
    /// can splice any text into it.
    func validateForWriting() throws {
        try validateNesting()
        try Self.check(unknownXML, owner: .document)
        try Self.check(meta.unknownXML, owner: .meta)
        try Self.check(root.unknownXML, owner: .root)
        for entry in root.entries {
            try Self.check(entry, owner: .entry(entry.uuid))
        }
        for group in root.groups {
            try Self.check(group)
        }
    }

    /// Throws `WriteError.nestingTooDeep` when the output would nest deeper
    /// than a read accepts. It stops at the first owner past the limit, so
    /// the check itself recurses no deeper than the limit. A typed owner is
    /// held to its deepest possible child, two levels below it.
    private func validateNesting() throws {
        try Self.checkNesting(unknownXML, ownerDepth: 1, owner: .document)
        try Self.checkNesting(meta.unknownXML, ownerDepth: 2, owner: .meta)
        try Self.checkNesting(root.unknownXML, ownerDepth: 2, owner: .root)
        for entry in root.entries {
            try Self.checkNesting(entry, depth: 3, owner: .entry(entry.uuid))
        }
        for group in root.groups {
            try Self.checkNesting(group, depth: 3)
        }
    }

    private static func checkNesting(_ group: Group, depth: Int) throws {
        let owner = Location.Owner.group(group.uuid)
        try requireDepth(depth + 2, owner)
        try checkNesting(group.unknownXML, ownerDepth: depth, owner: owner)
        for entry in group.entries {
            try checkNesting(entry, depth: depth + 1, owner: .entry(entry.uuid))
        }
        for subgroup in group.groups {
            try checkNesting(subgroup, depth: depth + 1)
        }
    }

    private static func checkNesting(_ entry: Entry, depth: Int, owner: Location.Owner) throws {
        try requireDepth(depth + 2, owner)
        try checkNesting(entry.unknownXML, ownerDepth: depth, owner: owner)
        for version in entry.history {
            try checkNesting(version, depth: depth + 2, owner: .historyEntry(version.uuid))
        }
    }

    /// A fragment's root sits one level below its owner, or below the
    /// `Times` or `History` element its path names.
    private static func checkNesting(_ fragments: OpaqueXMLNodes, ownerDepth: Int, owner: Location.Owner) throws {
        for node in fragments.nodes {
            try requireDepth(ownerDepth + node.path.count + XMLText.elementDepth(of: node.xml), owner)
        }
    }

    private static func requireDepth(_ depth: Int, _ owner: Location.Owner) throws {
        if depth > KDBXDocument.maxElementDepth {
            throw WriteError.nestingTooDeep(at: owner)
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
