import Foundation

/// KeePass's child order for each element the writer builds, typed and opaque
/// names together, as KeePass 2.59 writes them (`KdbxFile.Write.cs`).
///
/// The writer emits typed children in this order, and a new opaque fragment
/// is placed by it (`ChildLayout`), so the two cannot disagree.
enum ChildOrder {
    static let meta = [
        "Generator", "HeaderHash", "SettingsChanged", "DatabaseName", "DatabaseNameChanged",
        "DatabaseDescription", "DatabaseDescriptionChanged", "DefaultUserName", "DefaultUserNameChanged",
        "MaintenanceHistoryDays", "Color", "MasterKeyChanged", "MasterKeyChangeRec", "MasterKeyChangeForce",
        "MasterKeyChangeForceOnce", "MemoryProtection", "CustomIcons", "RecycleBinEnabled", "RecycleBinUUID",
        "RecycleBinChanged", "EntryTemplatesGroup", "EntryTemplatesGroupChanged", "HistoryMaxItems",
        "HistoryMaxSize", "LastSelectedGroup", "LastTopVisibleGroup", "Binaries", "CustomData",
    ]

    static let group = [
        "UUID", "Name", "Notes", "IconID", "CustomIconUUID", "Times", "IsExpanded", "DefaultAutoTypeSequence",
        "EnableAutoType", "EnableSearching", "LastTopVisibleEntry", "PreviousParentGroup", "Tags", "CustomData",
        "Entry", "Group",
    ]

    static let entry = [
        "UUID", "IconID", "CustomIconUUID", "ForegroundColor", "BackgroundColor", "OverrideURL", "QualityCheck",
        "Tags", "PreviousParentGroup", "Times", "String", "Binary", "AutoType", "CustomData", "History",
    ]

    static let times = [
        "CreationTime", "LastModificationTime", "LastAccessTime", "ExpiryTime", "Expires", "UsageCount",
        "LocationChanged",
    ]

    /// Elements a container holds any number of, which a fragment of the same
    /// name never gives way to.
    static let repeatable: Set<String> = ["Entry", "Group", "String", "Binary"]

    /// `children` in `order`, each name's children as given. A name missing
    /// from `order` is a writer bug that the writer tests catch: it is dropped.
    static func arranged(_ children: [TypedChild], in order: [String]) -> [TypedChild] {
        let byName = Dictionary(grouping: children, by: \.name)
        return order.flatMap { byName[$0] ?? [] }
    }
}

/// One typed child the writer emits, built only when emitted so protected
/// values keep document order.
struct TypedChild {
    let name: String
    let xml: (DocumentWriter) -> String

    init(_ name: String, _ xml: @escaping (DocumentWriter) -> String) {
        self.name = name
        self.xml = xml
    }
}

/// The typed children one element writes, which is what an opaque
/// fragment's position counts.
struct ChildLayout {
    let order: [String]
    let children: [TypedChild]
    /// An entry's attachments, which advance fragment positions without being
    /// counted in their own.
    var binaries: [KDBXDocument.BinaryReference] = []

    /// The typed children written before a `name` child; all of them for a
    /// name `order` does not list.
    func typedCount(before name: String) -> Int {
        let preceding = Set(order.prefix { $0 != name })
        return children.count { preceding.contains($0.name) }
    }

    /// The position of a new `name` fragment: after the typed children, and
    /// the attachments written among them, that KeePass writes before it.
    func insertionIndex(for name: String) -> Int {
        let anchor = typedCount(before: name)
        let followsBinaries = rank(of: name) > rank(of: "Binary")
        return anchor + binaries.count {
            $0.insertionIndex < anchor || (followsBinaries && $0.insertionIndex == anchor)
        }
    }

    /// `name`'s place in `order`; past the end for a name it does not list.
    func rank(of name: String) -> Int {
        order.firstIndex(of: name) ?? order.count
    }
}

extension OpaqueXMLNodes {
    /// Replaces every `name` fragment under `path` with `fragments`, at the
    /// first one's position. With none, they go where `layout` puts a new
    /// `name`, before the fragments at that position KeePass writes after it.
    mutating func replaceChildren(named name: String, path: [String], with fragments: [String], layout: ChildLayout) {
        let matches: (Node) -> Bool = { $0.path == path && $0.elementName == name }
        let insertionIndex: Int
        let position: Int
        if let first = nodes.firstIndex(where: matches) {
            insertionIndex = nodes[first].insertionIndex
            position = first
            nodes.removeAll(where: matches)
        } else {
            insertionIndex = layout.insertionIndex(for: name)
            let rank = layout.rank(of: name)
            position = nodes.firstIndex { node in
                node.path == path && node.insertionIndex == insertionIndex
                    && node.elementName.map { layout.order.contains($0) && layout.rank(of: $0) > rank } == true
            } ?? nodes.endIndex
        }
        nodes.insert(
            contentsOf: fragments.map { Node(path: path, insertionIndex: insertionIndex, xml: $0) },
            at: position
        )
    }
}
