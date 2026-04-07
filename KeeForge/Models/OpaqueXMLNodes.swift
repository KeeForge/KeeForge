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

struct KPMeta: Sendable, Hashable {
    var recycleBinUUID: UUID?
    var hasRecycleBinUUIDElement: Bool
    var unknownXML: OpaqueXMLNodes

    init(
        recycleBinUUID: UUID? = nil,
        hasRecycleBinUUIDElement: Bool = false,
        unknownXML: OpaqueXMLNodes = .empty
    ) {
        self.recycleBinUUID = recycleBinUUID
        self.hasRecycleBinUUIDElement = hasRecycleBinUUIDElement
        self.unknownXML = unknownXML
    }
}
