import Foundation
import KDBXKit

/// Streams the payload XML into a `KDBXDocument`.
///
/// Every element gets a role from its parent's role and its own name when it
/// opens. Only the structured containers (`Meta`, `Root`, `Group`, `Entry`,
/// `History`, `Times`, `String`, `Binary`, `DeletedObjects`) take children
/// apart; an element anywhere else is a leaf, captured whole as canonical XML.
///
/// When a leaf closes, its container either accepts it as a typed value or
/// records it as an opaque fragment at the container's current count of typed
/// children. The writer emits typed children in a fixed order and counts the
/// same way, so the one `accept` decision is both the parse and the position.
final class DocumentReader: NSObject, XMLParserDelegate {
    private var innerStream: KDBXInnerStream
    private var stack: [Frame] = []
    private let root = RootBuilder()
    private var meta = MetaBuilder()
    private var failure: KDBXDocument.ReadError?

    init(innerStream: KDBXInnerStream) {
        self.innerStream = innerStream
    }

    func read(_ xml: Data) throws -> KDBXDocument {
        let parser = XMLParser(data: xml)
        parser.delegate = self
        let succeeded = parser.parse()
        if let failure { throw failure }
        guard succeeded else {
            throw KDBXDocument.ReadError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
        }
        return KDBXDocument(meta: meta.build(), root: root.build())
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard let parent = stack.last?.role else {
            guard elementName == "KeePassFile" else {
                fail(.unexpectedRootElement(elementName), parser)
                return
            }
            stack.append(Frame(name: elementName, attributes: attributes, role: .document))
            return
        }
        stack.append(Frame(name: elementName, attributes: attributes, role: role(of: elementName, in: parent)))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let index = stack.indices.last, stack[index].role.capturesXML else { return }
        stack[index].text += string
        stack[index].content += XMLText.escape(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        var frame = stack.removeLast()
        if frame.name == "Value", frame.attributes["Protected"]?.lowercased() == "true" {
            // The stream spans every protected value in document order, opaque
            // ones included, so each is unmasked here whatever its context.
            guard let masked = Data(
                base64Encoded: frame.text.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .ignoreUnknownCharacters
            ) else {
                fail(.invalidProtectedValue, parser)
                return
            }
            frame.text = String(decoding: innerStream.apply(masked), as: UTF8.self)
            frame.content = XMLText.escape(frame.text)
        }
        guard let parentIndex = stack.indices.last else { return }
        let xml = frame.role.capturesXML
            ? XMLText.element(frame.name, attributes: frame.attributes, content: frame.content)
            : ""
        take(frame, xml: xml, into: stack[parentIndex].role)
        if stack[parentIndex].role.capturesXML {
            stack[parentIndex].content += xml
        }
    }

    private func fail(_ error: KDBXDocument.ReadError, _ parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }

    // MARK: - Roles

    private func role(of name: String, in parent: Role) -> Role {
        switch (parent, name) {
        case (.document, "Meta"):
            meta = MetaBuilder()
            return .meta(meta)
        case (.document, "Root"):
            return .root(root)
        case (.root, "Group"), (.group, "Group"):
            return .group(GroupBuilder())
        case (.root, "Entry"), (.group, "Entry"), (.history, "Entry"):
            return .entry(EntryBuilder())
        case (.entry(let entry), "History"):
            entry.historyKnownChildCount = 0
            return .history(entry)
        case (.entry(let owner as TimesOwner), "Times"), (.group(let owner as TimesOwner), "Times"):
            owner.timesKnownChildCount = 0
            return .times(owner)
        case (.entry, "String"):
            return .string(StringBuilder())
        case (.entry, "Binary"):
            return .binary(BinaryBuilder())
        case (.root, "DeletedObjects"):
            return .deletedObjects
        case (.deletedObjects, "DeletedObject"):
            return .deletedObject(DeletedObjectBuilder())
        default:
            return .leaf
        }
    }

    /// Stores `child` in `parent`: as typed data when the parent models it,
    /// otherwise as an opaque fragment at the parent's current count.
    private func take(_ child: Frame, xml: String, into parent: Role) {
        let text = child.text
        switch parent {
        case .document, .leaf:
            break

        case .meta(let meta):
            let accepted: Bool
            switch child.name {
            case "RecycleBinUUID":
                meta.recycleBin = UUID(kdbxText: text).map { $0 == .kdbxNone ? .unset : .group($0) }
                accepted = meta.recycleBin != nil
            case "MaintenanceHistoryDays":
                meta.maintenanceHistoryDays = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
                accepted = meta.maintenanceHistoryDays != nil
            case "HistoryMaxItems":
                meta.historyMaxItems = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
                accepted = meta.historyMaxItems != nil
            case "HistoryMaxSize":
                meta.historyMaxSize = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
                accepted = meta.historyMaxSize != nil
            default:
                accepted = false
            }
            if accepted {
                meta.knownChildCount += 1
            } else {
                meta.unknownXML.append(xml: xml, insertionIndex: meta.knownChildCount)
            }

        case .root(let root):
            switch child.role {
            case .entry(let entry): root.entries.append(entry.build())
            case .group(let group): root.groups.append(group.build())
            case .deletedObjects: break
            default:
                root.unknownXML.append(xml: xml, insertionIndex: root.knownChildCount)
                return
            }
            root.knownChildCount += 1

        case .group(let group):
            switch child.role {
            case .entry(let entry): group.entries.append(entry.build())
            case .group(let subgroup): group.groups.append(subgroup.build())
            case .times: break
            default:
                switch child.name {
                case "UUID":
                    if let uuid = UUID(kdbxText: text), uuid != .kdbxNone { group.uuid = uuid }
                case "Name": group.name = text
                case "Notes": group.notes = text
                case "IconID": group.iconID = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                case "IsExpanded":
                    group.isExpanded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false"
                case "Tags": group.tags = XMLText.splitTags(text)
                case "EnableSearching" where KDBXDocument.InheritableBool(xmlText: text) != nil:
                    group.enableSearching = KDBXDocument.InheritableBool(xmlText: text)
                default:
                    group.unknownXML.append(xml: xml, insertionIndex: group.knownChildCount)
                    return
                }
            }
            group.knownChildCount += 1

        case .entry(let entry):
            switch child.role {
            case .times, .history: break
            case .string(let field):
                entry.strings.append(KDBXDocument.Field(key: field.key, value: field.value, isProtected: field.isProtected))
            case .binary(let binary):
                guard let ref = binary.validRef else {
                    entry.unknownXML.append(xml: xml, insertionIndex: entry.knownChildCount)
                    return
                }
                // Attachments count in the opaque position space but not in
                // their own, so adjacent ones keep their recorded order.
                entry.binaries.append(KDBXDocument.BinaryReference(
                    key: binary.key, ref: ref, insertionIndex: entry.attachmentAnchorChildCount
                ))
                entry.knownChildCount += 1
                return
            default:
                switch child.name {
                case "UUID":
                    if let uuid = UUID(kdbxText: text), uuid != .kdbxNone { entry.uuid = uuid }
                case "IconID": entry.iconID = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                case "Tags": entry.tags = XMLText.splitTags(text)
                default:
                    entry.unknownXML.append(xml: xml, insertionIndex: entry.knownChildCount)
                    return
                }
            }
            entry.knownChildCount += 1
            entry.attachmentAnchorChildCount += 1

        case .history(let owner):
            if case .entry(let entry) = child.role {
                owner.history.append(entry.build())
                owner.historyKnownChildCount += 1
            } else {
                owner.unknownXML.append(xml: xml, path: ["History"], insertionIndex: owner.historyKnownChildCount)
            }

        case .times(let owner):
            switch (child.name, Date(kdbxText: text)) {
            case ("CreationTime", let date?): owner.times.creationTime = date
            case ("LastModificationTime", let date?): owner.times.lastModificationTime = date
            case ("LocationChanged", let date?): owner.times.locationChanged = date
            default:
                owner.unknownXML.append(xml: xml, path: ["Times"], insertionIndex: owner.timesKnownChildCount)
                return
            }
            owner.timesKnownChildCount += 1

        case .string(let field):
            switch child.name {
            case "Key": field.key = text
            case "Value":
                field.value = text
                field.isProtected = child.attributes["Protected"]?.lowercased() == "true"
            default: break
            }

        case .binary(let binary):
            switch child.name {
            case "Key": binary.key = text
            case "Value":
                if let attribute = child.attributes["Ref"] {
                    if let ref = Int(attribute) {
                        binary.ref = ref
                    } else {
                        binary.hasUnreadableRef = true
                    }
                }
            default: break
            }

        case .deletedObjects:
            if case .deletedObject(let object) = child.role, let uuid = object.uuid, let time = object.deletionTime {
                root.deletedObjects.append(KDBXDocument.DeletedObject(uuid: uuid, deletionTime: time))
            }

        case .deletedObject(let object):
            switch child.name {
            case "UUID": object.uuid = UUID(kdbxText: text).flatMap { $0 == .kdbxNone ? nil : $0 }
            case "DeletionTime": object.deletionTime = Date(kdbxText: text)
            default: break
            }
        }
    }
}

// MARK: - Frames and builders

private struct Frame {
    let name: String
    let attributes: [String: String]
    let role: Role
    /// Direct text, unescaped. Only for roles that capture XML.
    var text = ""
    /// Rendered children and escaped text. Only for roles that capture XML.
    var content = ""
}

private enum Role {
    case document
    case meta(MetaBuilder)
    case root(RootBuilder)
    case group(GroupBuilder)
    case entry(EntryBuilder)
    case history(EntryBuilder)
    case times(TimesOwner)
    case string(StringBuilder)
    case binary(BinaryBuilder)
    case deletedObjects
    case deletedObject(DeletedObjectBuilder)
    case leaf

    /// Leaves, and `Binary`, which stays opaque when its `Ref` is unreadable.
    var capturesXML: Bool {
        switch self {
        case .leaf, .binary: true
        default: false
        }
    }
}

private protocol TimesOwner: AnyObject {
    var times: KDBXDocument.Times { get set }
    var unknownXML: OpaqueXMLNodes { get set }
    var timesKnownChildCount: Int { get set }
}

private final class MetaBuilder {
    var recycleBin: KDBXDocument.RecycleBin?
    var maintenanceHistoryDays: Int?
    var historyMaxItems: Int?
    var historyMaxSize: Int64?
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0

    func build() -> KDBXDocument.Meta {
        KDBXDocument.Meta(
            recycleBin: recycleBin,
            maintenanceHistoryDays: maintenanceHistoryDays,
            historyMaxItems: historyMaxItems,
            historyMaxSize: historyMaxSize,
            unknownXML: unknownXML
        )
    }
}

private final class RootBuilder {
    var entries: [KDBXDocument.Entry] = []
    var groups: [KDBXDocument.Group] = []
    var deletedObjects: [KDBXDocument.DeletedObject] = []
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0

    func build() -> KDBXDocument.Root {
        KDBXDocument.Root(entries: entries, groups: groups, deletedObjects: deletedObjects, unknownXML: unknownXML)
    }
}

private final class GroupBuilder: TimesOwner {
    var uuid = UUID()
    var name = ""
    var notes: String?
    var iconID = 48
    var isExpanded = true
    var times = KDBXDocument.Times()
    var enableSearching: KDBXDocument.InheritableBool?
    var tags: [String]?
    var entries: [KDBXDocument.Entry] = []
    var groups: [KDBXDocument.Group] = []
    var unknownXML = OpaqueXMLNodes.empty
    var knownChildCount = 0
    var timesKnownChildCount = 0

    func build() -> KDBXDocument.Group {
        KDBXDocument.Group(
            uuid: uuid, name: name, notes: notes, iconID: iconID, isExpanded: isExpanded, times: times,
            enableSearching: enableSearching, tags: tags, entries: entries, groups: groups, unknownXML: unknownXML
        )
    }
}

private final class EntryBuilder: TimesOwner {
    var uuid = UUID()
    var iconID = 0
    var tags: [String]?
    var times = KDBXDocument.Times()
    var strings: [KDBXDocument.Field] = []
    var binaries: [KDBXDocument.BinaryReference] = []
    var history: [KDBXDocument.Entry] = []
    var unknownXML = OpaqueXMLNodes.empty
    /// Typed children so far, attachments included: the opaque position space.
    var knownChildCount = 0
    /// Typed children so far, attachments excluded: `BinaryReference.insertionIndex`.
    var attachmentAnchorChildCount = 0
    var timesKnownChildCount = 0
    var historyKnownChildCount = 0

    func build() -> KDBXDocument.Entry {
        KDBXDocument.Entry(
            uuid: uuid, iconID: iconID, tags: tags, times: times, strings: strings,
            binaries: binaries, history: history, unknownXML: unknownXML
        )
    }
}

private final class StringBuilder {
    var key = ""
    var value = ""
    var isProtected = false
}

private final class BinaryBuilder {
    var key = ""
    var ref: Int?
    var hasUnreadableRef = false

    var validRef: Int? {
        hasUnreadableRef ? nil : ref
    }
}

private final class DeletedObjectBuilder {
    var uuid: UUID?
    var deletionTime: Date?
}
