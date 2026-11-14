import XCTest
@testable import KeeForge

@MainActor
final class PasswordGeneratorModelTests: XCTestCase {
    func testTheFirstSuggestionUsesTheRememberedOptions() {
        var generatedWith: [PasswordGenerator.Options] = []
        let remembered = PasswordGenerator.Options(mode: .passphrase, wordCount: 5, separator: "+")
        let model = PasswordGeneratorModel(
            loadOptions: { remembered }, saveOptions: { _ in XCTFail("Opening saves nothing") },
            generate: { generatedWith.append($0); return "first" }
        )

        XCTAssertEqual(model.options, remembered)
        XCTAssertEqual(model.suggestion, "first")
        XCTAssertEqual(generatedWith, [remembered])
    }

    func testChangingAnOptionSavesItAndRegeneratesButAnUnchangedValueDoesNeither() {
        var saved: [PasswordGenerator.Options] = []
        var count = 0
        let model = PasswordGeneratorModel(
            loadOptions: { PasswordGenerator.Options() }, saveOptions: { saved.append($0) },
            generate: { _ in count += 1; return "s\(count)" }
        )

        model.options.length = 32
        XCTAssertEqual(saved.map(\.length), [32])
        XCTAssertEqual(model.suggestion, "s2")

        model.options.length = 32
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(model.suggestion, "s2")

        model.regenerate()
        XCTAssertEqual(model.suggestion, "s3", "Regenerate replaces the suggestion")
        XCTAssertEqual(saved.count, 1)
    }

    func testTheLastEnabledCharacterSetCannotBeSwitchedOff() {
        let model = PasswordGeneratorModel(
            loadOptions: {
                PasswordGenerator.Options(includeUppercase: true, includeLowercase: false,
                                          includeDigits: false, includeSymbols: true)
            },
            saveOptions: { _ in }, generate: { _ in "x" }
        )

        model.setEnabled(\.includeSymbols, false)
        XCTAssertFalse(model.isEnabled(\.includeSymbols))
        model.setEnabled(\.includeUppercase, false)
        XCTAssertTrue(model.isEnabled(\.includeUppercase), "The last set stays on")
        model.setEnabled(\.includeDigits, true)
        model.setEnabled(\.includeUppercase, false)
        XCTAssertFalse(model.isEnabled(\.includeUppercase))
        XCTAssertTrue(model.isEnabled(\.includeDigits))
    }

    func testStrengthIsCappedByHowTheSuggestionWasGenerated() {
        let options = PasswordGenerator.Options(mode: .passphrase, wordCount: 4, separator: "a")
        let model = PasswordGeneratorModel(loadOptions: { options }, saveOptions: { _ in })

        XCTAssertEqual(model.maximumEntropyBits, PasswordGenerator.minimumEntropyBits(options: options))
        XCTAssertEqual(model.strength?.entropyBits ?? 0, model.maximumEntropyBits, accuracy: 0.001,
                       "Letters as a separator would otherwise credit each letter as random")
    }

    func testCopyHandsTheSuggestionToTheClipboardAndCloseDropsIt() {
        var copied: [String] = []
        let model = PasswordGeneratorModel(loadOptions: { PasswordGenerator.Options() }, saveOptions: { _ in },
                                           generate: { _ in "Vx7$kQ2m" }, copy: { copied.append($0) })

        model.copySuggestion()
        XCTAssertEqual(copied, ["Vx7$kQ2m"])

        model.close()
        XCTAssertEqual(model.suggestion, "")
        XCTAssertNil(model.strength)
        model.copySuggestion()
        XCTAssertEqual(copied, ["Vx7$kQ2m"], "Nothing is left to copy once closed")
    }

    func testEverySurfaceStartsFromTheOptionsAnotherOneLastChanged() {
        let saved = SettingsService.passwordGeneratorOptions
        defer { SettingsService.passwordGeneratorOptions = saved }
        SettingsService.passwordGeneratorOptions = PasswordGenerator.Options()

        let popover = PasswordGeneratorModel()
        popover.options.mode = .passphrase
        popover.options.wordCount = 9
        let panel = PasswordGeneratorModel()

        XCTAssertEqual(panel.options, popover.options)
        XCTAssertEqual(SettingsService.passwordGeneratorOptions.wordCount, 9)
        XCTAssertEqual(panel.suggestion.split(separator: "-").count, 9)
    }
}
