import Foundation
import Observation

/// The password generator's options and current suggestion, shared by every generator surface.
/// Options persist through `SettingsService`, so all surfaces start from one remembered set. The
/// suggestion is held only until it is regenerated or the surface closes.
@MainActor @Observable
final class PasswordGeneratorModel {
    typealias Charset = WritableKeyPath<PasswordGenerator.Options, Bool>

    var options: PasswordGenerator.Options {
        didSet {
            guard options != oldValue else { return }
            saveOptions(options)
            regenerate()
        }
    }

    private(set) var suggestion = ""

    private let saveOptions: @MainActor (PasswordGenerator.Options) -> Void
    private let generate: @MainActor (PasswordGenerator.Options) -> String
    private let copyToClipboard: @MainActor (String) -> Void

    init(
        loadOptions: @MainActor () -> PasswordGenerator.Options = { SettingsService.passwordGeneratorOptions },
        saveOptions: @escaping @MainActor (PasswordGenerator.Options) -> Void = {
            SettingsService.passwordGeneratorOptions = $0
        },
        generate: @escaping @MainActor (PasswordGenerator.Options) -> String = { PasswordGenerator.generate(options: $0) },
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) {
        options = loadOptions()
        self.saveOptions = saveOptions
        self.generate = generate
        copyToClipboard = copy
        suggestion = generate(options)
    }

    func regenerate() {
        suggestion = generate(options)
    }

    func isEnabled(_ set: Charset) -> Bool {
        options[keyPath: set]
    }

    /// Refuses to switch off the last enabled set: `PasswordGenerator` would quietly fall back to
    /// lowercase while every switch showed off.
    func setEnabled(_ set: Charset, _ isEnabled: Bool) {
        if isEnabled == false && enabledCharacterSetCount <= 1 { return }
        options[keyPath: set] = isEnabled
    }

    /// The most the suggestion can be worth given how it was generated; caps the estimate.
    var maximumEntropyBits: Double {
        PasswordGenerator.minimumEntropyBits(options: options)
    }

    var strength: PasswordStrengthEstimate? {
        PasswordStrengthEstimator.estimate(suggestion, maximumEntropyBits: maximumEntropyBits)
    }

    func copySuggestion() {
        guard suggestion.isEmpty == false else { return }
        copyToClipboard(suggestion)
    }

    func close() {
        suggestion = ""
    }

    private var enabledCharacterSetCount: Int {
        [options.includeUppercase, options.includeLowercase, options.includeDigits, options.includeSymbols]
            .filter { $0 }
            .count
    }
}
