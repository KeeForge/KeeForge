import Foundation
import KDBXXML

/// KeePass's optional recovery reference stays opaque so unrelated edits preserve it.
/// It is a KDBX 4.1 element; `KDBXWriter` raises the header to 4.1 when a tree carries one.
enum PreviousParentGroupXML {
    private static let elementName = "PreviousParentGroup"

    static func isPresent(in nodes: OpaqueXMLNodes) -> Bool {
        nodes.nodes.contains { $0.path.isEmpty && $0.elementName == elementName }
    }

    /// Sets the entry's reference, where KeePass writes it unless it has one.
    static func setting(_ parentID: UUID?, on entry: KPEntry) -> OpaqueXMLNodes {
        guard let parentID else { return entry.unknownXML }
        var element = KDBXWriter.element(of: entry)
        element.replaceOpaqueChildren(named: elementName, with: [fragment(parentID)])
        return element.unknownXML
    }

    /// Sets the group's reference, where KeePass writes it unless it has one.
    static func setting(_ parentID: UUID?, on group: KPGroup) -> OpaqueXMLNodes {
        guard let parentID else { return group.unknownXML }
        var element = KDBXWriter.element(of: group)
        element.replaceOpaqueChildren(named: elementName, with: [fragment(parentID)])
        return element.unknownXML
    }

    static func fragment(_ parentID: UUID) -> String {
        "<\(elementName)>\(parentID.kdbxBase64String)</\(elementName)>"
    }

    static func parentID(in nodes: OpaqueXMLNodes) -> UUID? {
        let references = nodes.nodes.filter { $0.path.isEmpty && $0.elementName == elementName }
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

    static func removing(from nodes: OpaqueXMLNodes) -> OpaqueXMLNodes {
        var updated = nodes
        updated.removeDirectChildren(named: elementName)
        return updated
    }

    static func copying(from source: OpaqueXMLNodes, into target: OpaqueXMLNodes) -> OpaqueXMLNodes {
        let references = source.nodes.filter { $0.path.isEmpty && $0.elementName == elementName }
        guard references != target.nodes.filter({ $0.path.isEmpty && $0.elementName == elementName }) else {
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
            if depth != 1 || elementName != PreviousParentGroupXML.elementName || !attributeDict.isEmpty {
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
