import Foundation

/// Edits individual icons inside the preserved `Meta/CustomIcons` fragment.
/// Neighboring icons, image bytes, and vendor fields stay byte-identical.
enum CustomIconXML {
    static let elementName = "CustomIcons"

    static func renaming(uuid: UUID, to name: String, at date: Date, in xml: OpaqueXMLNodes) -> OpaqueXMLNodes? {
        editing(uuid: uuid, in: xml) { icon in
            guard let children = children(in: icon, root: "Icon") else { return nil }
            var updated = icon
            for child in children.reversed() where ["Name", "LastModificationTime"].contains(child.name) {
                updated.removeSubrange(child.range)
            }
            guard let closing = updated.range(of: "</Icon>", options: .backwards) else { return nil }
            let escaped = name.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r", with: "&#xD;")
            updated.insert(contentsOf: "<Name>\(escaped)</Name><LastModificationTime>\(date.kdbxBase64String)</LastModificationTime>", at: closing.lowerBound)
            return updated
        }
    }

    static func deleting(uuid: UUID, from xml: OpaqueXMLNodes) -> OpaqueXMLNodes? {
        editing(uuid: uuid, in: xml) { _ in "" }
    }

    static func entryRemovingReferences(to icons: Set<UUID>, from source: KPEntry) -> KPEntry {
        guard let uuid = source.customIconUUID, icons.contains(uuid) else { return source }
        var entry = source
        entry.customIconUUID = nil
        entry.iconID = 0
        entry.unknownXML.removeDirectChildren(named: "CustomIconUUID")
        return entry
    }

    /// The caller owns this tree. History loses only the deleted icon, keeping
    /// its content, timestamps and order, as in KeePassXC maintenance.
    static func removeReferences(to icons: [UUID: Date], in root: KPGroup) {
        let identifiers = Set(icons.keys)
        func entryWithoutIcon(_ source: KPEntry, isHistory: Bool) -> KPEntry {
            var entry = entryRemovingReferences(to: identifiers, from: source)
            if !isHistory, let uuid = source.customIconUUID, let deletedAt = icons[uuid] {
                entry.lastModificationTime = max(entry.lastModificationTime ?? deletedAt, deletedAt)
            }
            entry.history = entry.history.map { entryWithoutIcon($0, isHistory: true) }
            return entry
        }
        if let uuid = root.customIconUUID, let deletedAt = icons[uuid] {
            root.customIconUUID = nil
            root.iconID = 48
            root.lastModificationTime = max(root.lastModificationTime ?? deletedAt, deletedAt)
            root.unknownXML.removeDirectChildren(named: "CustomIconUUID")
        }
        root.entries = root.entries.map { entryWithoutIcon($0, isHistory: false) }
        for group in root.groups { removeReferences(to: icons, in: group) }
    }

    private static func editing(
        uuid: UUID,
        in xml: OpaqueXMLNodes,
        transform: (String) -> String?
    ) -> OpaqueXMLNodes? {
        guard let (index, match) = location(of: uuid, in: xml) else { return nil }
        let node = xml.nodes[index]
        guard let replacement = transform(String(node.xml[match.range])) else { return nil }
        var result = xml
        result.nodes[index] = .init(path: node.path, insertionIndex: node.insertionIndex,
                                   xml: node.xml.replacingCharacters(in: match.range, with: replacement))
        return result
    }

    static func copying(uuid: UUID, from source: OpaqueXMLNodes, to destination: OpaqueXMLNodes) -> OpaqueXMLNodes? {
        guard let (index, match) = location(of: uuid, in: source) else { return nil }
        return addingElement(String(source.nodes[index].xml[match.range]), to: destination)
    }

    private static func location(of uuid: UUID, in xml: OpaqueXMLNodes) -> (Int, Span)? {
        let containers = xml.nodes.indices.filter { xml.nodes[$0].path.isEmpty && xml.nodes[$0].elementName == elementName }
        var matches: [(Int, Span)] = []
        for index in containers {
            let node = xml.nodes[index]
            guard let icons = children(in: node.xml, root: elementName) else { return nil }
            for icon in icons where icon.name == "Icon" {
                let fragment = String(node.xml[icon.range])
                guard let fields = children(in: fragment, root: "Icon") else { return nil }
                let ids = fields.filter { $0.name == "UUID" }
                guard ids.count == 1, let id = ids.first else { return nil }
                if fragment[id.content].trimmingCharacters(in: .whitespacesAndNewlines) == uuid.kdbxBase64String {
                    matches.append((index, icon))
                }
            }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    static func requiresVersion41(_ xml: OpaqueXMLNodes) -> Bool {
        for node in xml.nodes where node.path.isEmpty && node.elementName == elementName {
            guard let icons = children(in: node.xml, root: elementName) else { continue }
            for icon in icons where icon.name == "Icon" {
                guard let fields = children(in: String(node.xml[icon.range]), root: "Icon") else { continue }
                if fields.contains(where: { $0.name == "Name" || $0.name == "LastModificationTime" }) { return true }
            }
        }
        return false
    }

    private struct Span {
        let name: String
        let range: Range<String.Index>
        let content: Range<String.Index>
    }

    // KDBXParser's capture renders paired tags and escapes angle brackets in
    // text and attributes. Only that canonical form is editable here.
    private static func children(in xml: String, root: String) -> [Span]? {
        var stack: [(name: String, start: String.Index, content: String.Index)] = []
        var result: [Span] = []
        var cursor = xml.startIndex
        var closedRoot = false
        while let start = xml[cursor...].firstIndex(of: "<") {
            guard !closedRoot, let end = xml[start...].firstIndex(of: ">") else { return nil }
            let after = xml.index(after: end)
            let tag = xml[xml.index(after: start)..<end]
            if tag.hasPrefix("/") {
                guard let open = stack.popLast(), tag.dropFirst() == open.name else { return nil }
                if stack.count == 1 {
                    result.append(Span(name: open.name, range: open.start..<after, content: open.content..<start))
                }
                if stack.isEmpty { closedRoot = true }
            } else {
                guard let name = OpaqueXMLNodes.Node(insertionIndex: 0, xml: String(xml[start..<after])).elementName,
                      !tag.hasSuffix("/"), !tag.contains("<") else { return nil }
                if stack.isEmpty {
                    guard name == root, xml[..<start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                }
                stack.append((name, start, after))
            }
            cursor = after
        }
        guard closedRoot, stack.isEmpty, xml[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    /// A minimal `<Icon>`: the UUID and the image, nothing else.
    ///
    /// `<Name>` and `<LastModificationTime>` are KDBX 4.1 additions. Writing one
    /// would oblige `KDBXWriter.requiredMinorVersion(for:)` to raise the file's
    /// minor version, so an icon download would quietly upgrade the format —
    /// a much larger promise than the user made by tapping a button. Both are
    /// optional, and KeePass and KeePassXC read an icon without them.
    static func iconElement(uuid: UUID, imageData: Data) -> String {
        "<Icon><UUID>\(uuid.kdbxBase64String)</UUID><Data>\(imageData.base64EncodedString())</Data></Icon>"
    }

    /// Returns `unknownXML` with the icon added to its `<CustomIcons>` fragment,
    /// creating that element when the database has none, or `nil` when the
    /// fragment offers no place to splice into.
    ///
    /// Base64 cannot contain `<` or `>`, so searching the fragment's text for
    /// its own closing tag is unambiguous: the last occurrence is the element's
    /// own, whatever the icons inside it look like.
    ///
    /// `nil` rather than a rebuilt element: a fragment this cannot splice is a
    /// fragment it does not understand, and rebuilding one from the decoded
    /// dictionary would drop every icon whose bytes this app does not model —
    /// the loss the whole type exists to prevent. Refusing the edit costs the
    /// user an icon; guessing would cost them the ones they already had.
    static func adding(
        uuid: UUID,
        imageData: Data,
        to unknownXML: OpaqueXMLNodes
    ) -> OpaqueXMLNodes? {
        addingElement(iconElement(uuid: uuid, imageData: imageData), to: unknownXML)
    }

    private static func addingElement(_ icon: String, to unknownXML: OpaqueXMLNodes) -> OpaqueXMLNodes? {
        guard let index = unknownXML.nodes.firstIndex(where: {
            $0.path.isEmpty && $0.elementName == elementName
        }) else {
            var created = unknownXML
            created.append(
                xml: "<\(elementName)>\(icon)</\(elementName)>",
                insertionIndex: unknownXML.maxInsertionIndex()
            )
            return created
        }

        let existing = unknownXML.nodes[index]
        guard let spliced = inserting(icon, into: existing.xml) else { return nil }
        var updated = unknownXML
        updated.nodes[index] = OpaqueXMLNodes.Node(
            path: existing.path,
            insertionIndex: existing.insertionIndex,
            xml: spliced
        )
        return updated
    }

    /// The parser renders every preserved fragment through a start/end tag pair,
    /// so a captured `<CustomIcons>` always closes explicitly — a source
    /// `<CustomIcons/>` reaches this type as `<CustomIcons></CustomIcons>`.
    /// Anything else did not come from the parser.
    private static func inserting(_ icon: String, into fragment: String) -> String? {
        let closingTag = "</\(elementName)>"
        guard let closing = fragment.range(of: closingTag, options: .backwards) else { return nil }
        return fragment.replacingCharacters(in: closing, with: icon + closingTag)
    }
}
