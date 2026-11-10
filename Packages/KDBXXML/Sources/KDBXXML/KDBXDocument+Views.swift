import Foundation

// Typed views of elements the document keeps opaque. They are computed from
// `unknownXML`, so an edit to the fragments is what changes them.

extension KDBXDocument.Entry {
    /// `<CustomIconUUID>`, the last one if repeated; `nil` when absent,
    /// unreadable, or all-zero.
    public var customIconUUID: UUID? {
        unknownXML.customIconUUID
    }

    /// `<Times>/<ExpiryTime>`, the last one if repeated. KeePass honors it
    /// only while `expires` is true.
    public var expiryTime: Date? {
        unknownXML.last(named: "ExpiryTime", path: ["Times"])?.textContent.flatMap(Date.init(kdbxText:))
    }

    /// `<Times>/<Expires>` is `True`, case-insensitive.
    public var expires: Bool {
        unknownXML.last(named: "Expires", path: ["Times"])?.textContent?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}

extension KDBXDocument.Group {
    /// `<CustomIconUUID>`, the last one if repeated; `nil` when absent,
    /// unreadable, or all-zero.
    public var customIconUUID: UUID? {
        unknownXML.customIconUUID
    }
}

extension KDBXDocument.Meta {
    /// The icons in every `<CustomIcons>` element, keyed by UUID; a later
    /// duplicate wins. An icon without a readable non-zero UUID or base64
    /// `<Data>` is skipped.
    public var customIcons: [UUID: KDBXDocument.CustomIcon] {
        var icons: [UUID: KDBXDocument.CustomIcon] = [:]
        for node in unknownXML.nodes where node.path.isEmpty && node.elementName == "CustomIcons" {
            for (uuid, icon) in CustomIconsReader.icons(in: node.xml) {
                icons[uuid] = icon
            }
        }
        return icons
    }
}

extension OpaqueXMLNodes {
    fileprivate var customIconUUID: UUID? {
        last(named: "CustomIconUUID")?.textContent
            .flatMap(UUID.init(kdbxText:))
            .flatMap { $0 == .kdbxNone ? nil : $0 }
    }
}

/// Reads `<Icon>` children of one canonical `<CustomIcons>` fragment.
private final class CustomIconsReader: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var uuid: UUID?
    private var data: Data?
    private var name: String?
    private var icons: [(UUID, KDBXDocument.CustomIcon)] = []

    static func icons(in fragment: String) -> [(UUID, KDBXDocument.CustomIcon)] {
        let reader = CustomIconsReader()
        let parser = XMLParser(data: Data(fragment.utf8))
        parser.delegate = reader
        parser.parse()
        return reader.icons
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        text = ""
        if path == ["CustomIcons", "Icon"] {
            uuid = nil
            data = nil
            name = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch path {
        case ["CustomIcons", "Icon", "UUID"]:
            uuid = UUID(kdbxText: text).flatMap { $0 == .kdbxNone ? nil : $0 }
        case ["CustomIcons", "Icon", "Data"]:
            data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        options: .ignoreUnknownCharacters)
        case ["CustomIcons", "Icon", "Name"]:
            name = text
        case ["CustomIcons", "Icon"]:
            if let uuid, let data {
                icons.append((uuid, KDBXDocument.CustomIcon(data: data, name: name)))
            }
        default:
            break
        }
        path.removeLast()
    }
}
