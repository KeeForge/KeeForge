import CryptoKit
import XCTest
@testable import KeeForge

final class PasswordGeneratorTests: XCTestCase {
    func testBundledWordlistMatchesEFFSource() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "eff_large_wordlist", withExtension: "txt"))
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e")
        XCTAssertEqual(PasswordGenerator.passphraseWords.count, 7_772)
        XCTAssertEqual(Set(PasswordGenerator.passphraseWords).count, 7_772)
        XCTAssertTrue(PasswordGenerator.passphraseWords.allSatisfy { $0.allSatisfy(PasswordGenerator.isPassphraseLetter) })
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
            XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), Double(expected) * log2(7_772), accuracy: 0.0001)
        }
    }

    func testGenerateDefaultLengthReturnsExpectedLength() {
        let password = PasswordGenerator.generate()

        XCTAssertEqual(password.count, 20)
    }

    func testGenerateReachesMaximumSliderLengthWithEveryCharacterClass() {
        XCTAssertEqual(PasswordGenerator.lengthRange, 8...128)
        var generator = SeededGenerator(seed: 128)
        let options = PasswordGenerator.Options(length: PasswordGenerator.lengthRange.upperBound)
        let password = PasswordGenerator.generate(options: options, using: &generator)

        XCTAssertEqual(password.count, 128)
        XCTAssertTrue(password.contains(where: \.isUppercase))
        XCTAssertTrue(password.contains(where: \.isLowercase))
        XCTAssertTrue(password.contains(where: \.isNumber))
        XCTAssertTrue(password.contains(where: { $0.isLetter == false && $0.isNumber == false }))
        XCTAssertEqual(
            PasswordGenerator.minimumEntropyBits(options: options),
            128 * PasswordGenerator.minimumEntropyBits() / 20,
            accuracy: 0.0001
        )
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

    func testIncludedCharactersAlwaysAppearAndJoinThePool() {
        let options = PasswordGenerator.Options(
            length: 8, includeUppercase: false, includeLowercase: false, includeDigits: true,
            includeSymbols: false, excludeAmbiguous: false, includedCharacters: "äß"
        )
        for seed in 0..<200 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let password = PasswordGenerator.generate(options: options, using: &generator)
            XCTAssertEqual(password.count, 8)
            XCTAssertTrue(password.contains(where: { "äß".contains($0) }), "One included character is required")
            XCTAssertTrue(password.allSatisfy { $0.isNumber || "äß".contains($0) })
        }
        XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), 8 * log2(12), accuracy: 0.0001)
    }

    func testIncludedCharactersAlreadyInASetAreNotCountedTwice() {
        let options = PasswordGenerator.Options(
            length: 10, includeUppercase: false, includeLowercase: false, includeDigits: true,
            includeSymbols: false, excludeAmbiguous: false, includedCharacters: "0123x x"
        )

        XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), 10 * log2(11), accuracy: 0.0001,
                       "Duplicates and whitespace are dropped; digits typed again add nothing")
    }

    func testIncludedCharactersSurviveTheAmbiguousFilter() {
        var generator = SeededGenerator(seed: 5)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 8, includeUppercase: false, includeLowercase: true, includeDigits: false,
                includeSymbols: false, excludeAmbiguous: true, includedCharacters: "0"
            ),
            using: &generator
        )

        XCTAssertTrue(password.contains("0"))
    }

    func testExcludedCharactersNeverAppear() {
        let excluded = "aeiouAEIOU0123456789#$%"
        let options = PasswordGenerator.Options(length: 128, excludeAmbiguous: false, excludedCharacters: excluded)
        for seed in 0..<50 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let password = PasswordGenerator.generate(options: options, using: &generator)
            XCTAssertEqual(password.count, 128)
            XCTAssertTrue(password.allSatisfy { excluded.contains($0) == false })
        }
    }

    func testExcludedCharactersOverrideIncludedOnes() {
        var generator = SeededGenerator(seed: 9)
        let password = PasswordGenerator.generate(
            options: PasswordGenerator.Options(
                length: 32, includeUppercase: false, includeLowercase: true, includeDigits: false,
                includeSymbols: false, includedCharacters: "!?", excludedCharacters: "!"
            ),
            using: &generator
        )

        XCTAssertFalse(password.contains("!"))
        XCTAssertTrue(password.contains("?"))
    }

    func testExcludingAWholeSetDropsItWithoutStallingGeneration() {
        let options = PasswordGenerator.Options(
            length: 12, includeUppercase: false, includeLowercase: true, includeDigits: true,
            includeSymbols: false, excludeAmbiguous: false, excludedCharacters: "0123456789"
        )
        var generator = SeededGenerator(seed: 3)
        let password = PasswordGenerator.generate(options: options, using: &generator)

        XCTAssertEqual(password.count, 12)
        XCTAssertTrue(password.allSatisfy(\.isLowercase))
        XCTAssertTrue(PasswordGenerator.hasCharacters(options: options))
        XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), 12 * log2(26), accuracy: 0.0001)
    }

    func testExcludingEveryEnabledCharacterLeavesNothingToGenerate() {
        let options = PasswordGenerator.Options(
            includeUppercase: false, includeLowercase: false, includeDigits: true, includeSymbols: false,
            excludeAmbiguous: false, includedCharacters: "x", excludedCharacters: "0123456789x"
        )

        XCTAssertFalse(PasswordGenerator.hasCharacters(options: options))
        XCTAssertEqual(PasswordGenerator.generate(options: options), "")
        XCTAssertEqual(PasswordGenerator.minimumEntropyBits(options: options), 0)

        var passphrase = options
        passphrase.mode = .passphrase
        XCTAssertTrue(PasswordGenerator.hasCharacters(options: passphrase), "Passphrases ignore character options")
        XCTAssertFalse(PasswordGenerator.generate(options: passphrase).isEmpty)
    }

    func testUnattendedGenerationDropsExclusionsOnlyWhenTheyLeaveNothing() {
        let empty = PasswordGenerator.Options(
            includeUppercase: false, includeLowercase: false, includeDigits: true, includeSymbols: false,
            excludeAmbiguous: false, excludedCharacters: "0123456789"
        )
        XCTAssertEqual(PasswordGenerator.unattended(empty).excludedCharacters, "")
        XCTAssertEqual(PasswordGenerator.generate(options: PasswordGenerator.unattended(empty)).count, empty.length)

        let usable = PasswordGenerator.Options(excludedCharacters: "abc")
        XCTAssertEqual(PasswordGenerator.unattended(usable), usable)
    }

    func testIncludedCharactersThatWouldMergeWithANeighborAreIgnored() {
        for usable in ["é", "😀", "€", "!"] {
            XCTAssertTrue(PasswordGenerator.isUsableCustomCharacter(Character(usable)), usable)
        }
        // Each on its own: written next to another character, a combining scalar joins it.
        let merging = ["\u{0301}", "\u{1F1FA}", "\u{1F3FD}", "\u{1100}", "\u{200D}", "e\u{0301}", "\t", " "]
        for scalar in merging {
            XCTAssertFalse(PasswordGenerator.isUsableCustomCharacter(Character(scalar)), scalar.debugDescription)
        }
        XCTAssertEqual(String(PasswordGenerator.usableIncludedCharacters("é😀é\t\n ")), "é😀")

        let typed = "é😀" + merging.joined()
        let options = PasswordGenerator.Options(
            length: 40, includeUppercase: false, includeLowercase: false, includeDigits: true,
            includeSymbols: false, includedCharacters: typed
        )
        for seed in 0..<50 {
            var generator = SeededGenerator(seed: UInt64(seed))
            XCTAssertEqual(PasswordGenerator.generate(options: options, using: &generator).count, 40)
        }
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
