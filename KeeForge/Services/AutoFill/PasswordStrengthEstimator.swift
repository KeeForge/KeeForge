import Foundation

struct PasswordStrengthEstimate: Equatable, Sendable {
    enum Level: Equatable, Sendable, CaseIterable {
        case veryWeak
        case weak
        case good
        case veryGood

        var title: String {
            switch self {
            case .veryWeak:
                "Very weak"
            case .weak:
                "Weak"
            case .good:
                "Good"
            case .veryGood:
                "Very good"
            }
        }

        var filledSegments: Int {
            switch self {
            case .veryWeak:
                1
            case .weak:
                2
            case .good:
                3
            case .veryGood:
                4
            }
        }
    }

    let entropyBits: Double
    let level: Level

    var roundedEntropyBits: Int {
        Int(entropyBits.rounded())
    }

    var summary: String {
        "\(level.title) (~\(roundedEntropyBits) bits)"
    }
}

enum PasswordStrengthEstimator {
    static func estimate(_ password: String) -> PasswordStrengthEstimate? {
        guard password.isEmpty == false else { return nil }

        let poolSize = characterPoolSize(for: password)
        guard poolSize > 0 else { return nil }

        let rawEntropy = Double(password.count) * log2(Double(poolSize))
        let entropy = max(0, rawEntropy - repetitionPenalty(for: password))

        return PasswordStrengthEstimate(
            entropyBits: entropy,
            level: level(forEntropyBits: entropy)
        )
    }

    private static func characterPoolSize(for password: String) -> Int {
        var poolSize = 0
        if password.contains(where: \.isLowercase) {
            poolSize += 26
        }
        if password.contains(where: \.isUppercase) {
            poolSize += 26
        }
        if password.contains(where: \.isNumber) {
            poolSize += 10
        }
        if password.contains(where: { $0.isWhitespace }) {
            poolSize += 1
        }
        if password.contains(where: { $0.isSymbolLike }) {
            poolSize += 33
        }
        if password.contains(where: { $0.isExtendedScalar }) {
            poolSize += 128
        }
        return poolSize
    }

    private static func repetitionPenalty(for password: String) -> Double {
        let totalCount = password.count
        guard totalCount > 1 else { return 0 }

        let uniqueCount = Set(password).count
        let repeatedCount = totalCount - uniqueCount
        guard repeatedCount > 0 else { return 0 }

        return Double(repeatedCount) * 1.5
    }

    private static func level(forEntropyBits bits: Double) -> PasswordStrengthEstimate.Level {
        if bits <= 40 {
            .veryWeak
        } else if bits < 75 {
            .weak
        } else if bits < 100 {
            .good
        } else {
            .veryGood
        }
    }
}

private extension Character {
    var isSymbolLike: Bool {
        isLetter == false && isNumber == false && isWhitespace == false && isExtendedScalar == false
    }

    var isExtendedScalar: Bool {
        unicodeScalars.contains { $0.value > 127 }
    }
}
