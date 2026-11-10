import Foundation
import XCTest
@testable import KDBXXML

final class ValueEncodingTests: XCTestCase {
    // Seconds from 0001-01-01 (.NET DateTime ticks / 10^7), checked with
    // Python's datetime: 2001-01-01 is 63113904000 (0x0EB1E1BF80) and
    // 1970-01-01 is 62135596800.
    func test_date_knownAnswersAgainstTheDotNetEpoch() throws {
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: 0).kdbxBase64String,
                       Data([0x80, 0xBF, 0xE1, 0xB1, 0x0E, 0x00, 0x00, 0x00]).base64EncodedString())
        XCTAssertEqual(Date(timeIntervalSince1970: 0).kdbxBase64String, "APeRdw4AAAA=", "62135596800 s")
        XCTAssertEqual(Date(kdbxBase64String: "APeRdw4AAAA="), Date(timeIntervalSince1970: 0))
        // KeePassXC wrote this LastModificationTime in keepassxc-recycled: 2026-11-04 05:43:04 UTC.
        XCTAssertEqual(Date(kdbxBase64String: "6Lx84g4AAAA="), ISO8601DateFormatter().date(from: "2026-11-04T05:43:04Z"))
    }

    func test_date_cutsFractionsAndSaturates() {
        let fractional = Date(timeIntervalSince1970: 10.9)
        XCTAssertEqual(fractional.kdbxStoredDate, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(Date(kdbxBase64String: fractional.kdbxBase64String), Date(timeIntervalSince1970: 10))
        let max = Data(repeating: 0xFF, count: 7) + Data([0x7F])
        let min = Data(repeating: 0, count: 7) + Data([0x80])
        XCTAssertEqual(Date.distantFuture.addingTimeInterval(1e20).kdbxBase64String, max.base64EncodedString())
        XCTAssertEqual(Date.distantPast.addingTimeInterval(-1e20).kdbxBase64String, min.base64EncodedString())
        XCTAssertEqual(Date(timeIntervalSinceReferenceDate: .nan).kdbxBase64String, Data(count: 8).base64EncodedString())
    }

    func test_date_extremesReadBackAndWriteExactly() throws {
        for seconds in [Int64.max, Int64.min, 0] {
            var littleEndian = seconds.littleEndian
            let text = withUnsafeBytes(of: &littleEndian) { Data($0) }.base64EncodedString()
            XCTAssertEqual(try XCTUnwrap(Date(kdbxBase64String: text)).kdbxBase64String, text, "\(seconds)")
        }
    }

    func test_date_readsEitherFormAndRejectsTheRest() {
        XCTAssertEqual(Date(kdbxText: " APeRdw4AAAA=\n"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Date(kdbxText: "1970-01-01T00:00:00Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Date(kdbxText: "1970-01-01T00:00:00.500Z"), Date(timeIntervalSince1970: 0.5))
        // A 12-character binary form with T and - in it is still binary.
        let tricky = Data([0x4D, 0x2D, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00]).base64EncodedString()
        XCTAssertNotNil(Date(kdbxText: tricky))
        XCTAssertNil(Date(kdbxText: "yesterday"))
        XCTAssertNil(Date(kdbxText: "AAAA"))
        XCTAssertNil(Date(kdbxBase64String: "AAAAAAAAAAAAAAAA"), "12 bytes, not 8")
    }

    func test_uuid_knownAnswerAndReading() {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        XCTAssertEqual(uuid.kdbxBase64String, "ABEiM0RVZneImaq7zN3u/w==")
        XCTAssertEqual(UUID(kdbxText: "\tABEiM0RVZneImaq7zN3u/w== "), uuid)
        XCTAssertEqual(UUID(kdbxText: "AAAAAAAAAAAAAAAAAAAAAA=="), .kdbxNone)
        XCTAssertNil(UUID(kdbxText: "ABEiM0RVZneImaq7zN3u"))
        XCTAssertNil(UUID(kdbxText: "not base64"))
    }

    func test_inheritableBool_xmlText() {
        XCTAssertEqual(KDBXDocument.InheritableBool.allCases.map(\.xmlText), ["null", "True", "False"])
        for value in KDBXDocument.InheritableBool.allCases {
            XCTAssertEqual(KDBXDocument.InheritableBool(xmlText: value.xmlText), value)
        }
        XCTAssertNil(KDBXDocument.InheritableBool(xmlText: "yes"))
    }

    func test_xmlText_escapingRoundTrips() {
        let text = "a & b < c > d \" e ' f \r g"
        XCTAssertEqual(XMLText.escape(text), "a &amp; b &lt; c &gt; d \" e ' f &#xD; g")
        XCTAssertEqual(XMLText.unescape(XMLText.escapeAttribute(text)), text)
        XCTAssertEqual(XMLText.unescape("&amp;lt;"), "&lt;", "&amp; is resolved last")
        XCTAssertEqual(XMLText.splitTags(" a ,b;; c\n"), ["a", "b", "c"])
        XCTAssertEqual(XMLText.splitTags("a\n,b"), ["a\n", "b"], "pieces trim spaces, not newlines")
    }
}
