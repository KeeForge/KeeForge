import Foundation

/// XML fragments a document element does not model, each kept at its position
/// among the element's typed children.
///
/// Fragments are canonical XML as the reader renders it: paired tags (a source
/// `<X/>` becomes `<X></X>`), attributes sorted and double-quoted, `&`, `<`,
/// `>`, and CR escaped in text. Protected values inside a fragment are
/// plaintext and are masked again on write. Code that splices fragments must
/// produce the same form.
public struct OpaqueXMLNodes: Sendable, Hashable {
    public struct Node: Sendable, Hashable {
        /// Empty for a direct child of the owner; `["Times"]` or `["History"]`
        /// for a child of that typed element.
        public let path: [String]
        /// The number of typed siblings the writer emits before this fragment.
        public let insertionIndex: Int
        public let xml: String

        public init(path: [String] = [], insertionIndex: Int, xml: String) {
            self.path = path
            self.insertionIndex = insertionIndex
            self.xml = xml
        }

        /// The outermost start tag's name, or `nil` for a fragment that does
        /// not begin with one (comment, processing instruction, text).
        public var elementName: String? {
            guard xml.hasPrefix("<") else { return nil }
            let body = xml.dropFirst()
            guard let first = body.first, first != "/", first != "!", first != "?" else {
                return nil
            }
            let name = body.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }
            return name.isEmpty ? nil : String(name)
        }

        /// The text of a fragment that is one element holding only text, with
        /// entities resolved; `nil` for anything else.
        var textContent: String? {
            guard let name = elementName, xml.hasSuffix("</\(name)>"),
                  let open = xml.firstIndex(of: ">") else { return nil }
            let start = xml.index(after: open)
            let end = xml.index(xml.endIndex, offsetBy: -(name.count + 3))
            guard start <= end else { return nil }
            let body = xml[start..<end]
            guard !body.contains("<") else { return nil }
            return XMLText.unescape(String(body))
        }
    }

    public var nodes: [Node]

    public static let empty = OpaqueXMLNodes()

    public init(nodes: [Node] = []) {
        self.nodes = nodes
    }

    public var isEmpty: Bool {
        nodes.isEmpty
    }

    public mutating func append(xml: String, path: [String] = [], insertionIndex: Int) {
        nodes.append(Node(path: path, insertionIndex: insertionIndex, xml: xml))
    }

    /// Drops the direct-child fragments with this element name. Other nodes
    /// keep their positions.
    public mutating func removeDirectChildren(named elementName: String) {
        nodes.removeAll { $0.path.isEmpty && $0.elementName == elementName }
    }

    /// The fragments at one position, in recorded order.
    public func xmlFragments(path: [String] = [], insertionIndex: Int) -> [String] {
        nodes
            .filter { $0.path == path && $0.insertionIndex == insertionIndex }
            .map(\.xml)
    }

    /// The highest position under `path`, or 0 when there is none.
    public func maxInsertionIndex(path: [String] = []) -> Int {
        nodes
            .filter { $0.path == path }
            .map(\.insertionIndex)
            .max() ?? 0
    }

    func contains(path: [String]) -> Bool {
        nodes.contains { $0.path == path }
    }

    /// The last direct-child (or `path`) fragment with this name.
    func last(named name: String, path: [String] = []) -> Node? {
        nodes.last { $0.path == path && $0.elementName == name }
    }
}
