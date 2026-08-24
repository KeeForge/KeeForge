import Foundation

enum PasswordGenerator {
    struct Options: Equatable, Sendable, Codable {
        var length: Int
        var includeUppercase: Bool
        var includeLowercase: Bool
        var includeDigits: Bool
        var includeSymbols: Bool
        var excludeAmbiguous: Bool

        init(
            length: Int = 20,
            includeUppercase: Bool = true,
            includeLowercase: Bool = true,
            includeDigits: Bool = true,
            includeSymbols: Bool = true,
            excludeAmbiguous: Bool = true
        ) {
            self.length = length
            self.includeUppercase = includeUppercase
            self.includeLowercase = includeLowercase
            self.includeDigits = includeDigits
            self.includeSymbols = includeSymbols
            self.excludeAmbiguous = excludeAmbiguous
        }

        /// Decodes field by field so a stored value written before a new option
        /// existed keeps the options the user did pick instead of resetting
        /// them all to the defaults.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Options()
            self.init(
                length: try container.decodeIfPresent(Int.self, forKey: .length)
                    ?? defaults.length,
                includeUppercase: try container.decodeIfPresent(Bool.self, forKey: .includeUppercase)
                    ?? defaults.includeUppercase,
                includeLowercase: try container.decodeIfPresent(Bool.self, forKey: .includeLowercase)
                    ?? defaults.includeLowercase,
                includeDigits: try container.decodeIfPresent(Bool.self, forKey: .includeDigits)
                    ?? defaults.includeDigits,
                includeSymbols: try container.decodeIfPresent(Bool.self, forKey: .includeSymbols)
                    ?? defaults.includeSymbols,
                excludeAmbiguous: try container.decodeIfPresent(Bool.self, forKey: .excludeAmbiguous)
                    ?? defaults.excludeAmbiguous
            )
        }
    }

    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.<>?/\\~|`'\"")
    private static let ambiguousCharacters = Set("Il1O0|`'\"")

    static func generate(options: Options = Options()) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(options: options, using: &generator)
    }

    static func generate<RNG: RandomNumberGenerator>(
        options: Options,
        using generator: inout RNG
    ) -> String {
        let normalizedOptions = normalized(options)
        let characterSets = enabledCharacterSets(for: normalizedOptions)
        guard characterSets.isEmpty == false else { return "" }

        let targetLength = max(normalizedOptions.length, 1)
        let requiredCharacters: [Character] = if targetLength >= characterSets.count {
            characterSets.compactMap { $0.randomElement(using: &generator) }
        } else {
            []
        }

        let allCharacters = Array(characterSets.joined())
        guard allCharacters.isEmpty == false else { return "" }

        var password = requiredCharacters
        while password.count < targetLength {
            if let next = allCharacters.randomElement(using: &generator) {
                password.append(next)
            }
        }

        password.shuffle(using: &generator)
        return String(password.prefix(targetLength))
    }

    static func minimumEntropyBits(options: Options = Options()) -> Double {
        let normalizedOptions = normalized(options)
        let poolSize = Double(enabledCharacterSets(for: normalizedOptions).joined().count)
        guard poolSize > 0 else { return 0 }
        return Double(max(normalizedOptions.length, 1)) * log2(poolSize)
    }

    private static func enabledCharacterSets(for options: Options) -> [[Character]] {
        var sets: [[Character]] = []
        if options.includeUppercase {
            sets.append(filtered(uppercase, excludeAmbiguous: options.excludeAmbiguous))
        }
        if options.includeLowercase {
            sets.append(filtered(lowercase, excludeAmbiguous: options.excludeAmbiguous))
        }
        if options.includeDigits {
            sets.append(filtered(digits, excludeAmbiguous: options.excludeAmbiguous))
        }
        if options.includeSymbols {
            sets.append(filtered(symbols, excludeAmbiguous: options.excludeAmbiguous))
        }
        return sets.filter { $0.isEmpty == false }
    }

    private static func filtered(
        _ characters: [Character],
        excludeAmbiguous: Bool
    ) -> [Character] {
        guard excludeAmbiguous else { return characters }
        return characters.filter { ambiguousCharacters.contains($0) == false }
    }

    private static func normalized(_ options: Options) -> Options {
        var normalized = options
        normalized.length = max(1, options.length)

        if normalized.includeUppercase == false &&
            normalized.includeLowercase == false &&
            normalized.includeDigits == false &&
            normalized.includeSymbols == false {
            normalized.includeLowercase = true
        }

        return normalized
    }
}
