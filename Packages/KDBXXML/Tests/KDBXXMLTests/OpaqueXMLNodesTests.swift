import Foundation
import XCTest
@testable import KDBXXML

final class OpaqueXMLNodesTests: XCTestCase {
    func test_elementName() {
        let cases: [(String, String?)] = [
            ("<A>x</A>", "A"), ("<B c=\"d\"></B>", "B"), ("<C/>", "C"), ("<D\n/>", "D"),
            ("text", nil), ("", nil), ("</E>", nil), ("<F />", "F"), ("<!-- c -->", nil), ("<?pi?>", nil), ("<", nil), ("< x>", nil),
        ]
        for (xml, name) in cases {
            XCTAssertEqual(OpaqueXMLNodes.Node(insertionIndex: 0, xml: xml).elementName, name, xml)
        }
    }

    func test_textContent() {
        let cases: [(String, String?)] = [
            ("<A>x &amp; y</A>", "x & y"), ("<A b=\"c\">v</A>", "v"), ("<A></A>", ""),
            ("<A><B/></A>", nil), ("<A>x</B>", nil), ("text", nil), ("<A>", nil), ("<A </A>", nil),
        ]
        for (xml, text) in cases {
            XCTAssertEqual(OpaqueXMLNodes.Node(insertionIndex: 0, xml: xml).textContent, text, xml)
        }
    }

    func test_editing() {
        var nodes = OpaqueXMLNodes.empty
        XCTAssertTrue(nodes.isEmpty)
        XCTAssertEqual(nodes.maxInsertionIndex(), 0)
        nodes.append(xml: "<A></A>", insertionIndex: 2)
        nodes.append(xml: "<B></B>", insertionIndex: 2)
        nodes.append(xml: "<A></A>", path: ["Times"], insertionIndex: 5)
        nodes.append(xml: "<A></A>", insertionIndex: 4)
        XCTAssertEqual(nodes.xmlFragments(insertionIndex: 2), ["<A></A>", "<B></B>"])
        XCTAssertEqual(nodes.maxInsertionIndex(), 4)
        XCTAssertEqual(nodes.maxInsertionIndex(path: ["Times"]), 5)
        nodes.removeDirectChildren(named: "A")
        XCTAssertEqual(nodes.nodes, [
            .init(insertionIndex: 2, xml: "<B></B>"),
            .init(path: ["Times"], insertionIndex: 5, xml: "<A></A>"),
        ])
    }
}
