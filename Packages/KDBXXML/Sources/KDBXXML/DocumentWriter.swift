import Foundation
import KDBXKit

/// Writes a `KDBXDocument` as payload XML.
///
/// Each container emits its typed children in `ChildOrder` and, before
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
        try document.validateForWriting()
        var children = Children(unknownXML: document.unknownXML, path: [])
        children.supersede(["Meta", "Root"])
        var xml = "<KeePassFile>"
        xml += typed(&children) { meta(document.meta) }
        xml += typed(&children) { root(document.root) }
        xml += trailing(children)
        xml += "</KeePassFile>"
        return Self.prolog + Data(xml.utf8)
    }

    // MARK: - Containers

    private func meta(_ meta: KDBXDocument.Meta) -> String {
        container("Meta", meta.layout.children, meta.unknownXML, path: [])
    }

    private func root(_ root: KDBXDocument.Root) -> String {
        var children = Children(unknownXML: root.unknownXML, path: [])
        children.supersede(root.deletedObjects.isEmpty ? [] : ["DeletedObjects"])
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

    fileprivate func group(_ group: KDBXDocument.Group) -> String {
        container("Group", group.layout.children, group.unknownXML, path: [])
    }

    fileprivate func entry(_ entry: KDBXDocument.Entry) -> String {
        let typedChildren = entry.layout.children
        var children = Children(unknownXML: entry.unknownXML, path: [])
        children.supersede(typedChildren.map(\.name))
        // Attachments are typed children too, but their recorded positions
        // count only the other typed children (`attachmentAnchor`).
        var attachmentAnchor = 0
        var pendingAttachments = entry.binaries
        var xml = "<Entry>"
        for child in typedChildren {
            xml += opaque(children)
            for attachment in pendingAttachments where attachment.insertionIndex == attachmentAnchor {
                xml += binary(attachment)
                children.knownChildCount += 1
                xml += opaque(children)
            }
            pendingAttachments.removeAll { $0.insertionIndex == attachmentAnchor }
            xml += child.xml(self)
            children.knownChildCount += 1
            attachmentAnchor += 1
        }
        // Positions at or past the last typed child, new attachments included.
        xml += pendingAttachments.map(binary).joined()
        xml += trailing(children)
        return xml + "</Entry>"
    }

    fileprivate func history(_ entries: [KDBXDocument.Entry], _ unknownXML: OpaqueXMLNodes) -> String {
        let children = entries.map { entry in TypedChild("Entry") { $0.entry(entry) } }
        return container("History", children, unknownXML, path: ["History"])
    }

    fileprivate func times(_ times: KDBXDocument.Times, _ unknownXML: OpaqueXMLNodes) -> String {
        container("Times", times.layout.children, unknownXML, path: ["Times"])
    }

    /// `<tag>` with its typed children, each after the fragments recorded
    /// before it, and the remaining fragments last.
    private func container(_ tag: String, _ typedChildren: [TypedChild], _ unknownXML: OpaqueXMLNodes, path: [String]) -> String {
        var children = Children(unknownXML: unknownXML, path: path)
        children.supersede(typedChildren.map(\.name))
        var xml = "<\(tag)>"
        for child in typedChildren {
            xml += typed(&children) { child.xml(self) }
        }
        xml += trailing(children)
        return xml + "</\(tag)>"
    }

    // MARK: - Leaves

    private func deletedObjects(_ objects: [KDBXDocument.DeletedObject]) -> String {
        let body = objects.map {
            "<DeletedObject>" + element("UUID", $0.uuid.kdbxBase64String)
                + element("DeletionTime", $0.deletionTime.kdbxBase64String) + "</DeletedObject>"
        }
        return "<DeletedObjects>" + body.joined() + "</DeletedObjects>"
    }

    fileprivate func string(_ field: KDBXDocument.Field) -> String {
        let value = field.isProtected
            ? element("Value", attributes: " Protected=\"True\"", mask(field.value))
            : element("Value", XMLText.escape(field.value))
        return "<String>" + element("Key", XMLText.escape(field.key)) + value + "</String>"
    }

    private func binary(_ attachment: KDBXDocument.BinaryReference) -> String {
        "<Binary>" + element("Key", XMLText.escape(attachment.key)) + "<Value Ref=\"\(attachment.ref)\"/></Binary>"
    }

    fileprivate func element(_ name: String, attributes: String = "", _ content: String) -> String {
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

        /// The typed children the container writes; a fragment of a
        /// repeatable name is kept beside them.
        mutating func supersede(_ names: [String]) {
            superseded = Set(names).subtracting(ChildOrder.repeatable)
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
    private func maskingProtectedValues(in xml: String) -> String {
        XMLText.replacingProtectedValues(in: xml) { mask(XMLText.unescape(String($0))) }
    }
}

// MARK: - Typed children

// What each element writes, in `ChildOrder`. The writer emits these lists and
// `ChildLayout` counts them, so a new fragment is placed by the same children.

extension KDBXDocument.Meta {
    var layout: ChildLayout {
        var children: [TypedChild] = []
        if let days = maintenanceHistoryDays {
            children.append(TypedChild("MaintenanceHistoryDays") { $0.element("MaintenanceHistoryDays", String(days)) })
        }
        if let recycleBin {
            children.append(TypedChild("RecycleBinUUID") { $0.element("RecycleBinUUID", recycleBin.uuid.kdbxBase64String) })
        }
        if let items = historyMaxItems {
            children.append(TypedChild("HistoryMaxItems") { $0.element("HistoryMaxItems", String(items)) })
        }
        if let size = historyMaxSize {
            children.append(TypedChild("HistoryMaxSize") { $0.element("HistoryMaxSize", String(size)) })
        }
        return ChildLayout(order: ChildOrder.meta, children: ChildOrder.arranged(children, in: ChildOrder.meta))
    }
}

extension KDBXDocument.Group {
    var layout: ChildLayout {
        let group = self
        var children = [
            TypedChild("UUID") { $0.element("UUID", group.uuid.kdbxBase64String) },
            TypedChild("Name") { $0.element("Name", XMLText.escape(group.name)) },
            TypedChild("IconID") { $0.element("IconID", String(group.iconID)) },
            TypedChild("IsExpanded") { $0.element("IsExpanded", group.isExpanded ? "True" : "False") },
        ]
        if let notes {
            children.append(TypedChild("Notes") { $0.element("Notes", XMLText.escape(notes)) })
        }
        if times.isWritten(unknownXML) {
            children.append(TypedChild("Times") { $0.times(group.times, group.unknownXML) })
        }
        if let enableSearching {
            children.append(TypedChild("EnableSearching") { $0.element("EnableSearching", enableSearching.xmlText) })
        }
        if let tags {
            children.append(TypedChild("Tags") { $0.element("Tags", XMLText.escape(tags.joined(separator: ","))) })
        }
        children += entries.map { entry in TypedChild("Entry") { $0.entry(entry) } }
        children += groups.map { subgroup in TypedChild("Group") { $0.group(subgroup) } }
        return ChildLayout(order: ChildOrder.group, children: ChildOrder.arranged(children, in: ChildOrder.group))
    }
}

extension KDBXDocument.Entry {
    var layout: ChildLayout {
        let entry = self
        var children = [
            TypedChild("UUID") { $0.element("UUID", entry.uuid.kdbxBase64String) },
            TypedChild("IconID") { $0.element("IconID", String(entry.iconID)) },
        ]
        if let tags {
            children.append(TypedChild("Tags") { $0.element("Tags", XMLText.escape(tags.joined(separator: ","))) })
        }
        if times.isWritten(unknownXML) {
            children.append(TypedChild("Times") { $0.times(entry.times, entry.unknownXML) })
        }
        children += strings.map { field in TypedChild("String") { $0.string(field) } }
        if !history.isEmpty || unknownXML.contains(path: ["History"]) {
            children.append(TypedChild("History") { $0.history(entry.history, entry.unknownXML) })
        }
        return ChildLayout(
            order: ChildOrder.entry,
            children: ChildOrder.arranged(children, in: ChildOrder.entry),
            binaries: binaries
        )
    }
}

extension KDBXDocument.Times {
    var layout: ChildLayout {
        var children: [TypedChild] = []
        if let creationTime {
            children.append(TypedChild("CreationTime") { $0.element("CreationTime", creationTime.kdbxBase64String) })
        }
        if let lastModificationTime {
            children.append(TypedChild("LastModificationTime") {
                $0.element("LastModificationTime", lastModificationTime.kdbxBase64String)
            })
        }
        if let locationChanged {
            children.append(TypedChild("LocationChanged") { $0.element("LocationChanged", locationChanged.kdbxBase64String) })
        }
        return ChildLayout(order: ChildOrder.times, children: ChildOrder.arranged(children, in: ChildOrder.times))
    }

    /// Whether the owner writes `<Times>`: for a typed date or a preserved child.
    func isWritten(_ ownerXML: OpaqueXMLNodes) -> Bool {
        creationTime != nil || lastModificationTime != nil || locationChanged != nil
            || ownerXML.contains(path: ["Times"])
    }
}
