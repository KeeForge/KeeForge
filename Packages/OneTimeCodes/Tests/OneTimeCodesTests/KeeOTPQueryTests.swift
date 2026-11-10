import XCTest
import OneTimeCodes

// A rewritten query goes straight back into an entry's `otp` field, so
// anything this drops or mangles is written to disk.
final class KeeOTPQueryTests: XCTestCase {
    func testReplacesKnownParametersInPlaceAndPreservesTheRest() {
        XCTAssertEqual(
            KeeOTPQuery.rewriting(
                "key=OLDSECRET&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1&custom=keep%20me&bare",
                secret: "NEWSECRET", period: 45, digits: 8, algorithm: .sha512
            ),
            "key=NEWSECRET&type=TOTP&step=45&size=8&encoding=Base32&otpHashMode=SHA512&custom=keep%20me&bare",
            "Unrelated parameters, their order, and their percent-encoding must survive verbatim"
        )
    }

    func testWithoutSecretLeavesKeyAndEncodingUntouched() {
        XCTAssertEqual(
            KeeOTPQuery.rewriting(
                "key=OLDSECRET&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1",
                secret: nil, period: 60, digits: 6, algorithm: .sha256
            ),
            "key=OLDSECRET&type=TOTP&step=60&size=6&encoding=UTF8&otpHashMode=SHA256"
        )
    }

    func testAppendsOmittedParametersUnderCanonicalNames() {
        // KeeOtp2 omits default-valued parameters, so "key=SECRET" is complete.
        XCTAssertEqual(
            KeeOTPQuery.rewriting("key=JBSWY3DP", secret: nil, period: 45, digits: 8, algorithm: .sha256),
            "key=JBSWY3DP&step=45&size=8&otpHashMode=SHA256",
            "With no new secret there is nothing to declare an encoding for"
        )
        XCTAssertEqual(
            KeeOTPQuery.rewriting("key=JBSWY3DP", secret: "NEWSECRET", period: 45, digits: 8, algorithm: .sha256),
            "key=NEWSECRET&encoding=Base32&step=45&size=8&otpHashMode=SHA256",
            "A rewritten secret is always Base32, so the encoding must be stated"
        )
    }

    func testMatchesNamesCaseInsensitivelyAndPercentDecoded() {
        XCTAssertEqual(
            KeeOTPQuery.rewriting("KEY=OLD&%73tep=30&OTPHASHMODE=SHA1", secret: "NEW", period: 45, digits: 8, algorithm: .sha512),
            "KEY=NEW&%73tep=45&OTPHASHMODE=SHA512&encoding=Base32&size=8",
            "Names match case-insensitively after percent-decoding, but keep their original spelling"
        )
    }

    func testRewritesOnlyTheFirstDuplicateParameter() {
        XCTAssertEqual(
            KeeOTPQuery.rewriting("step=30&step=99&key=OLD", secret: "NEW", period: 45, digits: 8, algorithm: .sha512),
            "step=45&step=99&key=NEW&encoding=Base32&size=8&otpHashMode=SHA512"
        )
    }

    func testLeavesUndecodableNamesAndEmptyComponentsAlone() {
        XCTAssertEqual(
            KeeOTPQuery.rewriting("%ZZ=1&&key=OLD", secret: nil, period: 30, digits: 6, algorithm: .sha1),
            "%ZZ=1&&key=OLD&step=30&size=6&otpHashMode=SHA1"
        )
    }
}
