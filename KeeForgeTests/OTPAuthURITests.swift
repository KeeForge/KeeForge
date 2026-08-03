import XCTest
@testable import KeeForge

final class OTPAuthURITests: XCTestCase {
    func test_fullURI_parsesIssuerParamLabelAndAllParameters() throws {
        let uri = try OTPAuthURI(
            string: "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&period=45&digits=8&algorithm=SHA256"
        )

        XCTAssertEqual(uri.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(uri.issuer, "Example")
        XCTAssertEqual(uri.accountName, "alice@example.com")
        XCTAssertEqual(uri.period, 45)
        XCTAssertEqual(uri.digits, 8)
        XCTAssertEqual(uri.algorithm, .sha256)
    }

    func test_labelOnlyURI_derivesIssuerAndAccountFromLabel() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/ACME%20Co:bob?secret=JBSWY3DPEHPK3PXP")

        XCTAssertEqual(uri.issuer, "ACME Co")
        XCTAssertEqual(uri.accountName, "bob")
    }

    func test_labelWithoutColon_isAccountNameWithNoIssuer() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/bob@example.com?secret=JBSWY3DPEHPK3PXP")

        XCTAssertNil(uri.issuer)
        XCTAssertEqual(uri.accountName, "bob@example.com")
    }

    func test_issuerParam_winsOverLabelPrefix() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/LabelIssuer:carol?secret=JBSWY3DPEHPK3PXP&issuer=ParamIssuer")

        XCTAssertEqual(uri.issuer, "ParamIssuer")
        XCTAssertEqual(uri.accountName, "carol")
    }

    func test_minimalURI_appliesRFC6238Defaults() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/?secret=JBSWY3DPEHPK3PXP")

        XCTAssertEqual(uri.period, 30)
        XCTAssertEqual(uri.digits, 6)
        XCTAssertEqual(uri.algorithm, .sha1)
        XCTAssertNil(uri.issuer)
        XCTAssertNil(uri.accountName)
    }

    func test_lowercasePaddedSecret_canonicalizesWhileRawURIStaysVerbatim() throws {
        let raw = "otpauth://totp/Example:pad?secret=mfrgg%3D%3D%3D&issuer=Example"
        let uri = try OTPAuthURI(string: raw)

        XCTAssertEqual(uri.secret, "MFRGG")
        XCTAssertEqual(uri.rawURI, raw)
    }

    func test_surroundingWhitespace_isTrimmedFromRawURI() throws {
        let uri = try OTPAuthURI(string: "  otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP\n")

        XCTAssertEqual(uri.rawURI, "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP")
    }

    func test_percentEncodedLabel_isDecoded() throws {
        let uri = try OTPAuthURI(string: "otpauth://totp/Big%20Corp%3A%20HQ:d%C3%A9j%C3%A0?secret=JBSWY3DPEHPK3PXP")

        // The first colon (percent-encoded in the label) splits issuer/account.
        XCTAssertEqual(uri.issuer, "Big Corp")
        XCTAssertEqual(uri.accountName, "HQ:déjà")
    }

    func test_schemeAndAlgorithm_areCaseInsensitive() throws {
        let uri = try OTPAuthURI(string: "OTPAUTH://TOTP/Example:x?secret=JBSWY3DPEHPK3PXP&algorithm=sha512")

        XCTAssertEqual(uri.algorithm, .sha512)
    }

    func test_uppercaseSchemeAndHost_areLowercasedInRawURIRestStaysVerbatim() throws {
        // QR alphanumeric mode encodes uppercase. KeePass-family readers —
        // including this app's own parser — compare the "otpauth://" prefix
        // case-sensitively, so the scheme and host are normalized at
        // authoring; everything after the host stays byte-verbatim, including
        // the uppercase query-parameter name (parsers match names lowercased).
        let uri = try OTPAuthURI(string: "OTPAUTH://TOTP/Ex:a?SECRET=JBSWY3DPEHPK3PXP")

        XCTAssertEqual(uri.rawURI, "otpauth://totp/Ex:a?SECRET=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(uri.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(uri.issuer, "Ex")
        XCTAssertEqual(uri.accountName, "a")
    }

    func test_duplicateQueryParameters_firstOccurrenceWins() throws {
        let uri = try OTPAuthURI(
            string: "otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=45&period=90&digits=8&digits=9"
        )

        XCTAssertEqual(uri.period, 45)
        XCTAssertEqual(uri.digits, 8)
    }

    func test_rejections_throwTheExpectedError() {
        let cases: [(uri: String, expected: OTPAuthURIError)] = [
            ("otpauth://hotp/Example:x?secret=JBSWY3DPEHPK3PXP&counter=0", .unsupportedType),
            ("otpauth://totp/Steam:x?secret=JBSWY3DPEHPK3PXP&encoder=steam", .unsupportedType),
            ("otpauth://totp/Example:x?period=30", .missingOrInvalidSecret),
            ("otpauth://totp/Example:x?secret=", .missingOrInvalidSecret),
            ("otpauth://totp/Example:x?secret=1NVALID1", .missingOrInvalidSecret),
            ("otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5", .invalidParameter),
            ("otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&digits=0", .invalidParameter),
            ("otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&digits=10", .invalidParameter),
            ("otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=0", .invalidParameter),
            ("otpauth://totp/Example:x?secret=JBSWY3DPEHPK3PXP&period=-1", .invalidParameter),
            ("https://example.com/?secret=JBSWY3DPEHPK3PXP", .notAnOTPAuthURI),
            ("not a uri at all", .notAnOTPAuthURI),
        ]

        for (uri, expected) in cases {
            XCTAssertThrowsError(try OTPAuthURI(string: uri), uri) { error in
                XCTAssertEqual(error as? OTPAuthURIError, expected, uri)
            }
        }
    }
}
