import Foundation

/// Preserves XML fragments that KeeForge does not model structurally.
struct OpaqueXMLNodes: Sendable, Hashable {
    struct Node: Sendable, Hashable {
        /// Empty path means a direct child of the owning container.
        let path: [String]
        /// Number of structured siblings that should be emitted before this fragment.
        let insertionIndex: Int
        let xml: String

        init(path: [String] = [], insertionIndex: Int, xml: String) {
            self.path = path
            self.insertionIndex = insertionIndex
            self.xml = xml
        }
    }

    var nodes: [Node]

    static let empty = OpaqueXMLNodes()

    init(nodes: [Node] = []) {
        self.nodes = nodes
    }

    var isEmpty: Bool {
        nodes.isEmpty
    }

    mutating func append(xml: String, path: [String] = [], insertionIndex: Int) {
        nodes.append(Node(path: path, insertionIndex: insertionIndex, xml: xml))
    }

    func xmlFragments(path: [String] = [], insertionIndex: Int) -> [String] {
        nodes
            .filter { $0.path == path && $0.insertionIndex == insertionIndex }
            .map(\.xml)
    }

    func maxInsertionIndex(path: [String] = []) -> Int {
        nodes
            .filter { $0.path == path }
            .map(\.insertionIndex)
            .max() ?? 0
    }
}

/// A tombstone record for a permanently deleted entry or group, used by
/// KeePass sync/merge to prevent resurrecting deleted objects.
struct KPDeletedObject: Sendable, Hashable {
    let uuid: UUID
    let deletionTime: Date
}

struct KPMeta: Sendable, Hashable {
    var recycleBinUUID: UUID?
    var hasRecycleBinUUIDElement: Bool
    var maintenanceHistoryDays: Int?
    var historyMaxItems: Int?
    var historyMaxSize: Int64?
    var unknownXML: OpaqueXMLNodes
    var deletedObjects: [KPDeletedObject]

    static let defaultMaintenanceHistoryDays = 365
    static let defaultHistoryMaxItems = 10
    static let defaultHistoryMaxSize: Int64 = 6 * 1024 * 1024

    init(
        recycleBinUUID: UUID? = nil,
        hasRecycleBinUUIDElement: Bool = false,
        maintenanceHistoryDays: Int? = nil,
        historyMaxItems: Int? = nil,
        historyMaxSize: Int64? = nil,
        unknownXML: OpaqueXMLNodes = .empty,
        deletedObjects: [KPDeletedObject] = []
    ) {
        self.recycleBinUUID = recycleBinUUID
        self.hasRecycleBinUUIDElement = hasRecycleBinUUIDElement
        self.maintenanceHistoryDays = maintenanceHistoryDays
        self.historyMaxItems = historyMaxItems
        self.historyMaxSize = historyMaxSize
        self.unknownXML = unknownXML
        self.deletedObjects = deletedObjects
    }

    var resolvedMaintenanceHistoryDays: Int {
        maintenanceHistoryDays ?? Self.defaultMaintenanceHistoryDays
    }

    var resolvedHistoryMaxItems: Int {
        historyMaxItems ?? Self.defaultHistoryMaxItems
    }

    var resolvedHistoryMaxSize: Int64 {
        historyMaxSize ?? Self.defaultHistoryMaxSize
    }
}
