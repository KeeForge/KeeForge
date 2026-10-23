import CryptoKit
import XCTest
@testable import KeeForge

final class PasswordGeneratorTests: XCTestCase {
    func testBundledWordlistMatchesEFFSource() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "eff_large_wordlist", withExtension: "txt"))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e")
        XCTAssertEqual(PasswordGenerator.passphraseWords.count, 7_776)
        XCTAssertEqual(Set(PasswordGenerator.passphraseWords).count, 7_776)
    }

    func testPassphrasesUseRequestedCountSeparatorAndEFFWords() {
        let wordlist = Set(PasswordGenerator.passphraseWords)
        for count in [4, 6, 12] {
            for separator in ["-", " ", ".", "::", "🔑"] {
                let options = PasswordGenerator.Options(mode: .passphrase, wordCount: count, separator: separator)
                let phrase = PasswordGenerator.generate(options: options)
                let words = phrase.components(separatedBy: separator)
                XCTAssertEqual(words.count, count)
                XCTAssertTrue(words.allSatisfy(wordlist.contains))
            }
        }
    }

    func testPassphraseDrawsAllowRepeatedWordsAndEmptySeparator() {
        var generator = RepeatedGenerator()
        let options = PasswordGenerator.Options(mode: .passphrase, wordCount: 4, separator: "")
        let phrase = PasswordGenerator.generate(options: options, using: &generator)
        XCTAssertEqual(phrase, "zoomzoomzoomzoom")
    }

    func testPassphraseCountIsBoundedAndEntropyUsesWords() {
        for (requested, expected) in [(Int.min, 4), (6, 6), (Int.max, 12)] {
            let options = PasswordGenerator.Options(mode: .passphrase, wordCount: requested, separator: " ")
            XCTAssertEqual(PasswordGenerator.generate(options: options).split(separator: " ").count, expected)
            XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), Double(expected) * log2(7_776), accuracy: 0.0001)
        }
    }

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

private struct RepeatedGenerator: RandomNumberGenerator {
    mutating func next() -> UInt64 { .max }
}
