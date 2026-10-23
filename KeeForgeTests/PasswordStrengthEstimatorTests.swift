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

    func testEstimateRatesEFFPassphrasesByWordCount() throws {
        for separator in ["-", " ", "::", "4"] {
            let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate("abacus\(separator)zoom"))
            XCTAssertEqual(estimate.entropyBits, 2 * log2(7_772), accuracy: 0.0001)
        }

        let generated = PasswordGenerator.generate(
            options: .init(mode: .passphrase, wordCount: 4, separator: "-")
        )
        let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate(generated))
        XCTAssertEqual(estimate.entropyBits, 4 * log2(7_772), accuracy: 0.0001)
        XCTAssertEqual(estimate.level, .weak)
    }

    func testEstimateKeepsCharacterEntropyForMixedSeparatorsAndNonWords() throws {
        for password in ["abacus-zoom.abacus", "-abacus-zoom", "abacus-zoomx", "Abacus-Zoom"] {
            let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate(password))
            XCTAssertGreaterThan(estimate.entropyBits, 2 * log2(7_772), password)
        }
    }

    func testEstimateHonorsMaximumEntropyBits() throws {
        let phrase = PasswordGenerator.generate(
            options: .init(mode: .passphrase, wordCount: 4, separator: "")
        )
        let cap = PasswordGenerator.minimumEntropyBits(
            options: .init(mode: .passphrase, wordCount: 4, separator: "")
        )
        let estimate = try XCTUnwrap(PasswordStrengthEstimator.estimate(phrase, maximumEntropyBits: cap))
        XCTAssertEqual(estimate.entropyBits, cap, accuracy: 0.0001)
        XCTAssertEqual(estimate.level, .weak)
    }

    func testEstimatePenalizesRepeatedCharacters() throws {
        let repeated = try XCTUnwrap(PasswordStrengthEstimator.estimate("aaaaaaaa"))
        let varied = try XCTUnwrap(PasswordStrengthEstimator.estimate("abcdefgh"))

        XCTAssertLessThan(repeated.entropyBits, varied.entropyBits)
    }
}
