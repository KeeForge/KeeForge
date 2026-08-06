import Foundation

/// Adds an image to `Meta/CustomIcons` without rewriting the icons already
/// there.
///
/// The parser keeps that whole element as one preserved fragment and the writer
/// replays it verbatim, which is why every custom icon in a foreign database
/// survives a save untouched. Rebuilding the element from the decoded
/// dictionary would throw that away — `<Icon>` child order, KDBX 4.1's optional
/// `<Name>` and `<LastModificationTime>`, and each writer's own base64 wrapping
/// are all things this app does not model and must not normalize.
///
/// So the new icon is spliced into the fragment instead: everything before the
/// closing tag stays byte-identical, and only the appended element is ours.
enum CustomIconXML {
    static let elementName = "CustomIcons"

    /// A minimal `<Icon>`: the UUID and the image, nothing else.
    ///
    /// `<Name>` and `<LastModificationTime>` are KDBX 4.1 additions. Writing one
    /// would oblige `KDBXWriter.requiredMinorVersion(for:)` to raise the file's
    /// minor version, so an icon download would quietly upgrade the format —
    /// a much larger promise than the user made by tapping a button. Both are
    /// optional, and KeePass and KeePassXC read an icon without them.
    static func iconElement(uuid: UUID, imageData: Data) -> String {
        "<Icon><UUID>\(uuid.kdbxBase64String)</UUID><Data>\(imageData.base64EncodedString())</Data></Icon>"
    }

    /// Returns `unknownXML` with the icon added to its `<CustomIcons>` fragment,
    /// creating that element when the database has none, or `nil` when the
    /// fragment offers no place to splice into.
    ///
    /// Base64 cannot contain `<` or `>`, so searching the fragment's text for
    /// its own closing tag is unambiguous: the last occurrence is the element's
    /// own, whatever the icons inside it look like.
    ///
    /// `nil` rather than a rebuilt element: a fragment this cannot splice is a
    /// fragment it does not understand, and rebuilding one from the decoded
    /// dictionary would drop every icon whose bytes this app does not model —
    /// the loss the whole type exists to prevent. Refusing the edit costs the
    /// user an icon; guessing would cost them the ones they already had.
    static func adding(
        uuid: UUID,
        imageData: Data,
        to unknownXML: OpaqueXMLNodes
    ) -> OpaqueXMLNodes? {
        let icon = iconElement(uuid: uuid, imageData: imageData)

        guard let index = unknownXML.nodes.firstIndex(where: {
            $0.path.isEmpty && $0.elementName == elementName
        }) else {
            var created = unknownXML
            created.append(
                xml: "<\(elementName)>\(icon)</\(elementName)>",
                insertionIndex: unknownXML.maxInsertionIndex()
            )
            return created
        }

        let existing = unknownXML.nodes[index]
        guard let spliced = inserting(icon, into: existing.xml) else { return nil }
        var updated = unknownXML
        updated.nodes[index] = OpaqueXMLNodes.Node(
            path: existing.path,
            insertionIndex: existing.insertionIndex,
            xml: spliced
        )
        return updated
    }

    /// The parser renders every preserved fragment through a start/end tag pair,
    /// so a captured `<CustomIcons>` always closes explicitly — a source
    /// `<CustomIcons/>` reaches this type as `<CustomIcons></CustomIcons>`.
    /// Anything else did not come from the parser.
    private static func inserting(_ icon: String, into fragment: String) -> String? {
        let closingTag = "</\(elementName)>"
        guard let closing = fragment.range(of: closingTag, options: .backwards) else { return nil }
        return fragment.replacingCharacters(in: closing, with: icon + closingTag)
    }
}
