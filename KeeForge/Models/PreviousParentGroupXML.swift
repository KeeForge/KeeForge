import Foundation

/// KeePass's optional recovery reference stays opaque so unrelated edits preserve it.
enum PreviousParentGroupXML {
    static func parentID(in nodes: OpaqueXMLNodes) -> UUID? {
        let references = nodes.nodes.filter { $0.path.isEmpty && $0.elementName == "PreviousParentGroup" }
        guard references.count == 1, let reference = references.first else { return nil }
        let reader = Reader()
        let parser = XMLParser(data: Data(reference.xml.utf8))
        parser.delegate = reader
        guard parser.parse(), reader.isValid,
              let data = Data(base64Encoded: reader.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func setting(_ parentID: UUID?, in nodes: OpaqueXMLNodes) -> OpaqueXMLNodes {
        guard let parentID else { return nodes }
        var updated = nodes
        let index = nodes.nodes.first { $0.path.isEmpty && $0.elementName == "PreviousParentGroup" }?.insertionIndex
            ?? nodes.maxInsertionIndex()
        updated.removeDirectChildren(named: "PreviousParentGroup")
        updated.append(xml: "<PreviousParentGroup>\(parentID.kdbxBase64String)</PreviousParentGroup>", insertionIndex: index)
        return updated
    }

    static func removing(from nodes: OpaqueXMLNodes) -> OpaqueXMLNodes {
        var updated = nodes
        updated.removeDirectChildren(named: "PreviousParentGroup")
        return updated
    }

    static func copying(from source: OpaqueXMLNodes, into target: OpaqueXMLNodes) -> OpaqueXMLNodes {
        let references = source.nodes.filter { $0.path.isEmpty && $0.elementName == "PreviousParentGroup" }
        guard references != target.nodes.filter({ $0.path.isEmpty && $0.elementName == "PreviousParentGroup" }) else {
            return target
        }
        var updated = removing(from: target)
        updated.nodes.append(contentsOf: references)
        return updated
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var text = ""
        var isValid = true
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            depth += 1
            if depth != 1 || elementName != "PreviousParentGroup" || !attributeDict.isEmpty {
                isValid = false
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
        }
    }
}
