import Foundation
import KDBXKit

/// Writes a `KDBXDocument` as payload XML.
///
/// Each container emits its typed children in KeePass's order and, before
/// each one, the opaque fragments recorded at that count; fragments past the
/// last typed child trail before the closing tag. A typed child replaces any
/// direct opaque fragment of the same name in its container, so a document can
/// never carry two of an element KeePass expects once.
final class DocumentWriter {
    private var innerStream: KDBXInnerStream

    private static let prolog = Data([0xEF, 0xBB, 0xBF]) +
        Data("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n".utf8)

    init(innerStream: KDBXInnerStream) {
        self.innerStream = innerStream
    }

    func write(_ document: KDBXDocument) throws -> Data {
        var xml = "<KeePassFile>"
        xml += meta(document.meta)
        xml += root(document.root)
        xml += "</KeePassFile>"
        try KDBXDocument.validate(text: xml)
        return Self.prolog + Data(xml.utf8)
    }

    // MARK: - Containers

    private func meta(_ meta: KDBXDocument.Meta) -> String {
        var children = Children(unknownXML: meta.unknownXML, path: [])
        children.supersede([
            "RecycleBinUUID": meta.recycleBinUUID != nil,
            "MaintenanceHistoryDays": meta.maintenanceHistoryDays != nil,
            "HistoryMaxItems": meta.historyMaxItems != nil,
            "HistoryMaxSize": meta.historyMaxSize != nil,
        ])
        var xml = "<Meta>"
        if let uuid = meta.recycleBinUUID {
            xml += typed(&children) { element("RecycleBinUUID", uuid.kdbxBase64String) }
        }
        if let days = meta.maintenanceHistoryDays {
            xml += typed(&children) { element("MaintenanceHistoryDays", String(days)) }
        }
        if let items = meta.historyMaxItems {
            xml += typed(&children) { element("HistoryMaxItems", String(items)) }
        }
        if let size = meta.historyMaxSize {
            xml += typed(&children) { element("HistoryMaxSize", String(size)) }
        }
        xml += trailing(children)
        return xml + "</Meta>"
    }

    private func root(_ root: KDBXDocument.Root) -> String {
        var children = Children(unknownXML: root.unknownXML, path: [])
        children.supersede(["DeletedObjects": !root.deletedObjects.isEmpty])
        var xml = "<Root>"
        for entry in root.entries {
            xml += typed(&children) { self.entry(entry) }
        }
        for group in root.groups {
            xml += typed(&children) { self.group(group) }
        }
        if !root.deletedObjects.isEmpty {
            xml += typed(&children) { deletedObjects(root.deletedObjects) }
        }
        xml += trailing(children)
        return xml + "</Root>"
    }

    private func group(_ group: KDBXDocument.Group) -> String {
        let writesTimes = writesTimes(group.times, group.unknownXML)
        var children = Children(unknownXML: group.unknownXML, path: [])
        children.supersede([
            "UUID": true,
            "Name": true,
            "Notes": group.notes != nil,
            "IconID": true,
            "IsExpanded": true,
            "Times": writesTimes,
            "EnableSearching": group.enableSearching != nil,
            "Tags": group.tags != nil,
        ])
        var xml = "<Group>"
        xml += typed(&children) { element("UUID", group.uuid.kdbxBase64String) }
        xml += typed(&children) { element("Name", XMLText.escape(group.name)) }
        // Right after `<Name>`, where KeePass writes it.
        if let notes = group.notes {
            xml += typed(&children) { element("Notes", XMLText.escape(notes)) }
        }
        xml += typed(&children) { element("IconID", String(group.iconID)) }
        xml += typed(&children) { element("IsExpanded", group.isExpanded ? "True" : "False") }
        if writesTimes {
            xml += typed(&children) { times(group.times, group.unknownXML) }
        }
        if let enableSearching = group.enableSearching {
            xml += typed(&children) { element("EnableSearching", enableSearching.xmlText) }
        }
        if let tags = group.tags {
            xml += typed(&children) { element("Tags", XMLText.escape(tags.joined(separator: ","))) }
        }
        for entry in group.entries {
            xml += typed(&children) { self.entry(entry) }
        }
        for subgroup in group.groups {
            xml += typed(&children) { self.group(subgroup) }
        }
        xml += trailing(children)
        return xml + "</Group>"
    }

    private func entry(_ entry: KDBXDocument.Entry) -> String {
        let writesTimes = writesTimes(entry.times, entry.unknownXML)
        let writesHistory = !entry.history.isEmpty || entry.unknownXML.contains(path: ["History"])
        var children = Children(unknownXML: entry.unknownXML, path: [])
        children.supersede([
            "UUID": true,
            "IconID": true,
            "Tags": entry.tags != nil,
            "Times": writesTimes,
            "History": writesHistory,
        ])
        // Attachments are typed children too, but their recorded positions
        // count only the other typed children (`attachmentAnchor`).
        var attachmentAnchor = 0
        var pendingAttachments = entry.binaries
        var xml = "<Entry>"

        func emit(_ child: () -> String) {
            xml += opaque(children)
            for attachment in pendingAttachments where attachment.insertionIndex == attachmentAnchor {
                xml += binary(attachment)
                children.knownChildCount += 1
                xml += opaque(children)
            }
            pendingAttachments.removeAll { $0.insertionIndex == attachmentAnchor }
            xml += child()
            children.knownChildCount += 1
            attachmentAnchor += 1
        }

        emit { element("UUID", entry.uuid.kdbxBase64String) }
        emit { element("IconID", String(entry.iconID)) }
        if let tags = entry.tags {
            emit { element("Tags", XMLText.escape(tags.joined(separator: ","))) }
        }
        if writesTimes {
            emit { times(entry.times, entry.unknownXML) }
        }
        for field in entry.strings {
            emit { string(field) }
        }
        if writesHistory {
            emit { history(entry.history, entry.unknownXML) }
        }
        // Positions at or past the last typed child, new attachments included.
        xml += pendingAttachments.map(binary).joined()
        xml += trailing(children)
        return xml + "</Entry>"
    }

    private func history(_ entries: [KDBXDocument.Entry], _ unknownXML: OpaqueXMLNodes) -> String {
        var children = Children(unknownXML: unknownXML, path: ["History"])
        var xml = "<History>"
        for entry in entries {
            xml += typed(&children) { self.entry(entry) }
        }
        xml += trailing(children)
        return xml + "</History>"
    }

    private func writesTimes(_ times: KDBXDocument.Times, _ unknownXML: OpaqueXMLNodes) -> Bool {
        times.creationTime != nil || times.lastModificationTime != nil || times.locationChanged != nil
            || unknownXML.contains(path: ["Times"])
    }

    private func times(_ times: KDBXDocument.Times, _ unknownXML: OpaqueXMLNodes) -> String {
        var children = Children(unknownXML: unknownXML, path: ["Times"])
        children.supersede([
            "CreationTime": times.creationTime != nil,
            "LastModificationTime": times.lastModificationTime != nil,
            "LocationChanged": times.locationChanged != nil,
        ])
        var xml = "<Times>"
        if let date = times.creationTime {
            xml += typed(&children) { element("CreationTime", date.kdbxBase64String) }
        }
        if let date = times.lastModificationTime {
            xml += typed(&children) { element("LastModificationTime", date.kdbxBase64String) }
        }
        // Last of KeePass's children, so the untyped ones before it
        // (`ExpiryTime`, `Expires`, `UsageCount`, ...) keep their slot.
        if let date = times.locationChanged {
            xml += typed(&children) { element("LocationChanged", date.kdbxBase64String) }
        }
        xml += trailing(children)
        return xml + "</Times>"
    }

    // MARK: - Leaves

    private func deletedObjects(_ objects: [KDBXDocument.DeletedObject]) -> String {
        let body = objects.map {
            "<DeletedObject>" + element("UUID", $0.uuid.kdbxBase64String)
                + element("DeletionTime", $0.deletionTime.kdbxBase64String) + "</DeletedObject>"
        }
        return "<DeletedObjects>" + body.joined() + "</DeletedObjects>"
    }

    private func string(_ field: KDBXDocument.Field) -> String {
        let value = field.isProtected
            ? element("Value", attributes: " Protected=\"True\"", mask(field.value))
            : element("Value", XMLText.escape(field.value))
        return "<String>" + element("Key", XMLText.escape(field.key)) + value + "</String>"
    }

    private func binary(_ attachment: KDBXDocument.BinaryReference) -> String {
        "<Binary>" + element("Key", XMLText.escape(attachment.key)) + "<Value Ref=\"\(attachment.ref)\"/></Binary>"
    }

    private func element(_ name: String, attributes: String = "", _ content: String) -> String {
        "<\(name)\(attributes)>\(content)</\(name)>"
    }

    private func mask(_ plaintext: String) -> String {
        innerStream.apply(Data(plaintext.utf8)).base64EncodedString()
    }

    // MARK: - Opaque fragments

    /// The opaque fragments of one container and its running count of typed
    /// children.
    private struct Children {
        let unknownXML: OpaqueXMLNodes
        let path: [String]
        var knownChildCount = 0
        private var superseded: Set<String> = []

        init(unknownXML: OpaqueXMLNodes, path: [String]) {
            self.unknownXML = unknownXML
            self.path = path
        }

        /// Names whose value says the container writes that typed child.
        mutating func supersede(_ names: [String: Bool]) {
            superseded = Set(names.filter(\.value).keys)
        }

        func fragments(at index: Int) -> [String] {
            unknownXML.nodes
                .filter { $0.path == path && $0.insertionIndex == index }
                .filter { node in node.elementName.map { !superseded.contains($0) } ?? true }
                .map(\.xml)
        }
    }

    /// The fragments before the next typed child, then the child, built only
    /// now so protected values keep document order.
    private func typed(_ children: inout Children, _ child: () -> String) -> String {
        let xml = opaque(children)
        let typed = child()
        children.knownChildCount += 1
        return xml + typed
    }

    private func opaque(_ children: Children) -> String {
        children.fragments(at: children.knownChildCount).map(maskingProtectedValues).joined()
    }

    private func trailing(_ children: Children) -> String {
        let last = children.unknownXML.maxInsertionIndex(path: children.path)
        guard last >= children.knownChildCount else { return "" }
        var xml = ""
        for index in children.knownChildCount...last {
            xml += children.fragments(at: index).map(maskingProtectedValues).joined()
        }
        return xml
    }

    /// Masks the plaintext of every protected value in a fragment, in order.
    /// Canonical fragments escape `<` and `>` in text and attributes, so the
    /// next `>` ends a tag and the next `</Value>` ends its value.
    private func maskingProtectedValues(in xml: String) -> String {
        var output = ""
        var rest = Substring(xml)
        while let open = rest.range(of: "<Value"),
              let close = rest[open.upperBound...].firstIndex(of: ">"),
              let end = rest[close...].range(of: "</Value>") {
            let tag = rest[open.lowerBound...close]
            let content = rest.index(after: close)..<end.lowerBound
            guard Self.isProtectedValueTag(tag) else {
                output += rest[..<content.lowerBound]
                rest = rest[content.lowerBound...]
                continue
            }
            output += rest[..<content.lowerBound] + mask(XMLText.unescape(String(rest[content])))
            rest = rest[content.upperBound...]
        }
        return output + rest
    }

    /// `<Value …>` (not `<ValueX>` or self-closing) whose `Protected` attribute
    /// is `true` in any case.
    private static func isProtectedValueTag(_ tag: Substring) -> Bool {
        let afterName = tag.dropFirst("<Value".count)
        guard let next = afterName.first, next == " " || next == ">", !tag.hasSuffix("/>"),
              let attribute = afterName.range(of: " Protected=\"") else { return false }
        return afterName[attribute.upperBound...].prefix { $0 != "\"" }.lowercased() == "true"
    }
}
