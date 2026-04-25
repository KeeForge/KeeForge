import XCTest
@testable import KeeForge

final class PasswordStrengthEstimatorTests: XCTestCase {
    func testEstimateReturnsNilForEmptyPassword() {
        XCTAssertNil(PasswordStrengthEstimator.estimate(""))
    }

    func testEstimateClassifiesShortPasswordAsVeryWeak() throws {
        let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate("abc"))

        XCTAssertEqual(estimate.level, .veryWeak)
        XCTAssertEqual(estimate.roundedEntropyBits, 14)
    }

    func testEstimateIncludesCharacterClassesInEntropy() throws {
        let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate("CorrectHorseBatteryStaple42!"))

        XCTAssertEqual(estimate.level, .veryGood)
        XCTAssertGreaterThanOrEqual(estimate.entropyBits, 150)
    }

    func testEstimatePenalizesRepeatedCharacters() throws {
        let repeated = try XCTUnwrap(PasswordStrengthEstimator.estimate("aaaaaaaa"))
        let varied = try XCTUnwrap(PasswordStrengthEstimator.estimate("abcdefgh"))

        XCTAssertLessThan(repeated.entropyBits, varied.entropyBits)
    }
}
