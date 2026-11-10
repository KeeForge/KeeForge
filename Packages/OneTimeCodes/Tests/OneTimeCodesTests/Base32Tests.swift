import Foundation
import XCTest
@testable import OneTimeCodes

final class Base32Tests: XCTestCase {
    /// RFC 4648 section 10, with padding as the RFC prints it.
    private static let rfc4648Vectors: [(text: String, encoded: String)] = [
        ("", ""),
        ("f", "MY======"),
        ("fo", "MZXQ===="),
        ("foo", "MZXW6==="),
        ("foob", "MZXW6YQ="),
        ("fooba", "MZXW6YTB"),
        ("foobar", "MZXW6YTBOI======"),
    ]

    func testEncodeMatchesRFC4648VectorsWithoutPadding() {
        for vector in Self.rfc4648Vectors {
            XCTAssertEqual(
                Base32.encode(Data(vector.text.utf8)),
                vector.encoded.replacingOccurrences(of: "=", with: ""),
                vector.text
            )
        }
    }

    func testDecodeMatchesRFC4648VectorsPaddedAndUnpadded() {
        for vector in Self.rfc4648Vectors {
            XCTAssertEqual(Base32.decode(vector.encoded), Data(vector.text.utf8), vector.encoded)
            let unpadded = vector.encoded.replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(Base32.decode(unpadded), Data(vector.text.utf8), unpadded)
        }
    }

    func testDecodeAcceptsLowercaseWhitespaceAndPadding() throws {
        let canonical = try XCTUnwrap(Base32.decode("JBSWY3DPEHPK3PXP"))

        XCTAssertEqual(Base32.decode("jbsw y3dp ehpk3pxp===="), canonical)
        XCTAssertEqual(Base32.decode("JBSW\tY3DP\nEHPK\r3PXP"), canonical)
    }

    func testDecodeRejectsCharactersOutsideTheAlphabet() {
        for invalid in ["ABC$DEF", "ABCDEFG1", "ABCDEFG8", "MZXW6-", "MZXWÉ"] {
            XCTAssertNil(Base32.decode(invalid), invalid)
        }
    }

    func testEncodeRoundTripsThroughDecodeIncludingPartialFinalQuantum() throws {
        // "MFRGG" and "MY" end mid-quantum (25 and 10 bits).
        for encoded in ["MFRGG", "MY", "JBSWY3DPEHPK3PXP", "GEZDGNBVGY3TQOJQ"] {
            XCTAssertEqual(Base32.encode(try XCTUnwrap(Base32.decode(encoded))), encoded)
        }
        let allBytes = Data(0...255)
        XCTAssertEqual(Base32.decode(Base32.encode(allBytes)), allBytes)
    }

    func testCanonicalSecretUppercasesAndRejectsNonCanonicalForms() {
        XCTAssertEqual(Base32.canonicalSecret("mfrgg"), "MFRGG")
        XCTAssertEqual(Base32.canonicalSecret("JBSWY3DPEHPK3PXP"), "JBSWY3DPEHPK3PXP")

        // Padding, whitespace, out-of-alphabet characters, empties, set
        // trailing bits ("MFRGH" re-encodes as "MFRGG"), and input too short
        // to hold a byte are rejected even where `decode` tolerates them.
        for rejected in ["MFRGG===", "MFRG G", "MFRGH", "1NVALID1", "", "M"] {
            XCTAssertNil(Base32.canonicalSecret(rejected), rejected)
        }
    }
}
