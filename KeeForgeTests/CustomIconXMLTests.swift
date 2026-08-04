import XCTest
@testable import KeeForge

/// `Meta/CustomIcons` is round-tripped verbatim, so adding an icon is a splice
/// into a preserved fragment rather than a rebuild. What has to hold is that the
/// bytes already in that fragment come out the other side unchanged, whatever
/// the writing client put in them.
final class CustomIconXMLTests: XCTestCase {

    private let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])

    private func customIconsFragment(in unknownXML: OpaqueXMLNodes) -> String? {
        unknownXML.nodes.first { $0.path.isEmpty && $0.elementName == "CustomIcons" }?.xml
    }

    func test_addsIconToAnExistingElementWithoutDisturbingWhatIsThere() throws {
        // Deliberately not what this app would write: a foreign `<Icon>` child
        // order, a KDBX 4.1 element KeeForge does not model, and whitespace.
        let existing = """
            <CustomIcons>\n  <Icon>\n    <Data>Zm9yZWlnbg==</Data>\n    \
            <UUID>3q2+7wAAAAAAAAAAAAAAAA==</UUID>\n    \
            <LastModificationTime>abc</LastModificationTime>\n  </Icon>\n</CustomIcons>
            """
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: existing, insertionIndex: 3)
        let uuid = UUID()

        let updated = CustomIconXML.adding(uuid: uuid, imageData: imageData, to: unknownXML)

        let fragment = try XCTUnwrap(customIconsFragment(in: updated))
        XCTAssertTrue(
            fragment.hasPrefix(String(existing.dropLast("</CustomIcons>".count))),
            "everything ahead of the closing tag must be byte-identical"
        )
        XCTAssertTrue(fragment.hasSuffix(CustomIconXML.iconElement(uuid: uuid, imageData: imageData) + "</CustomIcons>"))
        XCTAssertEqual(updated.nodes.count, 1, "the icon joins the element, it does not become a sibling")
        XCTAssertEqual(updated.nodes[0].insertionIndex, 3, "and the element keeps its position among Meta's children")
    }

    /// A database that has never held a custom icon may still carry the element
    /// in its empty form, which has no closing tag to insert before.
    func test_opensAnEmptyElementKeepingItsStartTag() throws {
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomIcons/>", insertionIndex: 0)
        let uuid = UUID()

        let updated = CustomIconXML.adding(uuid: uuid, imageData: imageData, to: unknownXML)

        XCTAssertEqual(
            customIconsFragment(in: updated),
            "<CustomIcons>\(CustomIconXML.iconElement(uuid: uuid, imageData: imageData))</CustomIcons>"
        )
    }

    func test_createsTheElementWhenTheDatabaseHasNone() throws {
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<Generator>KeePassXC</Generator>", insertionIndex: 0)
        let uuid = UUID()

        let updated = CustomIconXML.adding(uuid: uuid, imageData: imageData, to: unknownXML)

        XCTAssertEqual(
            customIconsFragment(in: updated),
            "<CustomIcons>\(CustomIconXML.iconElement(uuid: uuid, imageData: imageData))</CustomIcons>"
        )
        XCTAssertTrue(
            updated.nodes.contains { $0.xml == "<Generator>KeePassXC</Generator>" },
            "the Meta children that were already preserved stay preserved"
        )
    }

    /// Writing `<Name>` or `<LastModificationTime>` would oblige the writer to
    /// raise the file's minor version, turning an icon download into a format
    /// upgrade the user never asked for.
    func test_writesOnlyTheElementsThatPredateKDBX41() {
        let element = CustomIconXML.iconElement(uuid: UUID(), imageData: imageData)

        XCTAssertFalse(element.contains("<Name>"))
        XCTAssertFalse(element.contains("<LastModificationTime>"))
        XCTAssertTrue(element.contains("<UUID>"))
        XCTAssertTrue(element.contains("<Data>\(imageData.base64EncodedString())</Data>"))
    }

    /// The splice finds its insertion point by searching the fragment's own
    /// text, so the icon payload must not be able to look like markup. Base64
    /// cannot, which is what makes the search safe.
    func test_encodedImageCannotBeMistakenForMarkup() {
        let everyByte = Data((0...255).map { UInt8($0) })

        let encoded = everyByte.base64EncodedString()
        XCTAssertFalse(encoded.contains("<"))
        XCTAssertFalse(encoded.contains(">"))

        // And with every byte value in the payload, the element still has
        // exactly one closing tag for the splice to find.
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomIcons></CustomIcons>", insertionIndex: 0)
        let updated = CustomIconXML.adding(uuid: UUID(), imageData: everyByte, to: unknownXML)
        let fragment = customIconsFragment(in: updated) ?? ""
        XCTAssertEqual(fragment.components(separatedBy: "</CustomIcons>").count - 1, 1)
    }
}
