import XCTest
@testable import KeeForge

final class PasswordGeneratorTests: XCTestCase {
    func testGenerateDefaultLengthReturnsExpectedLength() {
        let password = PasswordGenerator.generate()

        XCTAssertEqual(password.count, 20)
    }

    func testGenerateCharsetIncludesAppliesAllCharacterClasses() {
        var generator = SeededGenerator(seed: 42)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 24,
                includeUppercase: true,
                includeLowercase: true,
                includeDigits: true,
                includeSymbols: true,
                excludeAmbiguous: false
            ),
            using: &generator
        )

        XCTAssertTrue(password.contains(where: \.isUppercase))
        XCTAssertTrue(password.contains(where: \.isLowercase))
        XCTAssertTrue(password.contains(where: \.isNumber))
        XCTAssertTrue(password.contains(where: { $0.isLetter == false && $0.isNumber == false }))
    }

    func testGenerateExcludeAmbiguousDropsConfusingChars() {
        var generator = SeededGenerator(seed: 7)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 64,
                includeUppercase: true,
                includeLowercase: true,
                includeDigits: true,
                includeSymbols: true,
                excludeAmbiguous: true
            ),
            using: &generator
        )

        XCTAssertTrue(password.allSatisfy { "Il1O0|`'\"".contains($0) == false })
    }

    func testGenerateIsHighEntropy() {
        let entropy = PasswordGenerator.minimumEntropyBits()

        XCTAssertGreaterThanOrEqual(entropy, 80)
    }

    func testGenerateWithAllCharsetsDisabledFallsBackToLowercase() {
        var generator = SeededGenerator(seed: 99)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 16,
                includeUppercase: false,
                includeLowercase: false,
                includeDigits: false,
                includeSymbols: false,
                excludeAmbiguous: false
            ),
            using: &generator
        )

        // The generator never returns an empty password: when every character
        // set is disabled it normalizes by re-enabling lowercase. The sheet's
        // charset toggles enforce the same >=1-enabled invariant in the UI so
        // the visible toggles never diverge from the generated password.
        XCTAssertEqual(password.count, 16)
        XCTAssertFalse(password.isEmpty)
        XCTAssertTrue(password.allSatisfy { $0.isLowercase })
    }

    func testGenerateWithAllCharsetsDisabledExcludingAmbiguousStaysLowercase() {
        var generator = SeededGenerator(seed: 123)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 24,
                includeUppercase: false,
                includeLowercase: false,
                includeDigits: false,
                includeSymbols: false,
                excludeAmbiguous: true
            ),
            using: &generator
        )

        XCTAssertEqual(password.count, 24)
        XCTAssertTrue(password.allSatisfy { $0.isLowercase })
        // Ambiguous lowercase ('l') is still filtered out via the normalized fallback.
        XCTAssertTrue(password.allSatisfy { $0 != "l" })
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}
