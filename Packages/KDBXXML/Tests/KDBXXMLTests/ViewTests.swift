import Foundation
import XCTest
@testable import KDBXXML

final class ViewTests: XCTestCase {
    func test_customIconUUID_readsTheLastPreservedElement() throws {
        let icon = "<CustomIconUUID>\(TestID.other.kdbxBase64String)</CustomIconUUID>"
        let zero = "<CustomIconUUID>\(UUID.kdbxNone.kdbxBase64String)</CustomIconUUID>"
        let parsed = try read(document(root: group(icon + entry("<CustomIconUUID>bad</CustomIconUUID>" + icon)) + group(icon + zero)))
        XCTAssertEqual(parsed.root.groups[0].customIconUUID, TestID.other)
        XCTAssertEqual(parsed.root.groups[0].entries[0].customIconUUID, TestID.other)
        XCTAssertNil(parsed.root.groups[1].customIconUUID, "the all-zero UUID means none")
        XCTAssertNil(KDBXDocument.Entry().customIconUUID)
    }

    func test_expiry_followsThePreservedTimesElements() throws {
        let date = Date(unix: 1_800_000_000)
        let parsed = try read(document(root: group(
            entry("<Times><ExpiryTime>\(date.kdbxBase64String)</ExpiryTime><Expires> TRUE </Expires></Times>")
                + entry("<Times><ExpiryTime>never</ExpiryTime><Expires>False</Expires></Times>")
        )))
        let entries = parsed.root.groups[0].entries
        XCTAssertEqual(entries[0].expiryTime, date)
        XCTAssertTrue(entries[0].expires)
        XCTAssertNil(entries[1].expiryTime)
        XCTAssertFalse(entries[1].expires)
        XCTAssertFalse(KDBXDocument.Entry().expires)
    }

    func test_customIcons_decodeEveryContainer() throws {
        let png = Data([1, 2, 3])
        let named = UUID(uuidString: "6B1F0E3A-2C4D-4E5F-8A9B-0C1D2E3F4A5B")!
        let parsed = try read(document(root: "", meta: """
        <CustomIcons></CustomIcons><CustomIcons>\
        <Icon><UUID>\(TestID.other.kdbxBase64String)</UUID><Data>AAAA</Data></Icon>\
        <Icon><UUID>\(TestID.other.kdbxBase64String)</UUID><Data>\(png.base64EncodedString())</Data></Icon>\
        <Icon><UUID>\(named.kdbxBase64String)</UUID><Data>\n\(png.base64EncodedString())\n</Data><Name>N</Name></Icon>\
        <Icon><UUID>\(UUID.kdbxNone.kdbxBase64String)</UUID><Data>AAAA</Data></Icon>\
        <Icon><UUID>\(TestID.entry.kdbxBase64String)</UUID></Icon><Other><Icon/></Other></CustomIcons>
        """))
        XCTAssertEqual(parsed.meta.customIcons, [
            TestID.other: .init(data: png),
            named: .init(data: png, name: "N"),
        ])
        XCTAssertEqual(KDBXDocument.Meta().customIcons, [:])
    }
}
