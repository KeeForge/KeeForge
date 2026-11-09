import Foundation
import KDBXKit

/// Credential-free summary of a KDBX file's outer header.
///
/// The outer header is stored in plaintext, so format version, cipher,
/// compression, and KDF settings can be shown without unlocking the database.
struct KDBXFileSummary: Equatable, Sendable {
    enum KeyDerivation: Equatable, Sendable {
        case aesKDF(rounds: UInt64)
        case argon2d(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32)
        case argon2id(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32)
        case unknown
    }

    let formatVersion: KDBXContainer.FileVersion
    let cipher: KDBXOuterCipher?
    let isCompressed: Bool
    let keyDerivation: KeyDerivation

    var formatDisplayName: String {
        "KDBX \(formatVersion.majorVersion).\(formatVersion.minorVersion)"
    }

    var cipherDisplayName: String {
        cipher?.displayName ?? String(localized: "Unknown")
    }

    var compressionDisplayName: String {
        isCompressed ? "GZip" : String(localized: "None")
    }

    var keyDerivationDisplayName: String {
        switch keyDerivation {
        case .aesKDF: "AES-KDF"
        case .argon2d: "Argon2d"
        case .argon2id: "Argon2id"
        case .unknown: String(localized: "Unknown")
        }
    }

    var keyDerivationDetailText: String? {
        switch keyDerivation {
        case .aesKDF(let rounds):
            String(localized: "\(rounds.formatted()) rounds")
        case .argon2d(let iterations, let memoryBytes, let parallelism),
             .argon2id(let iterations, let memoryBytes, let parallelism):
            String(localized: """
                \(Self.memoryText(memoryBytes)) · \(iterations.formatted()) iterations · \(parallelism.formatted()) threads
                """)
        case .unknown:
            nil
        }
    }

    private static func memoryText(_ memoryBytes: UInt64) -> String {
        Int64(clamping: memoryBytes).formatted(.byteCount(style: .memory))
    }

    /// Inspects the plaintext outer header. `data` may be a prefix of the file
    /// as long as it covers the full header.
    static func inspect(data: Data) throws -> KDBXFileSummary {
        let header = try KDBXContainer.readHeader(from: data)
        return KDBXFileSummary(
            formatVersion: header.formatVersion,
            cipher: header.cipher,
            isCompressed: header.compression == .gzip,
            keyDerivation: KeyDerivation(header.keyDerivation)
        )
    }
}

private extension KDBXFileSummary.KeyDerivation {
    init(_ keyDerivation: KDBXKeyDerivation?) {
        switch keyDerivation {
        case .aesKDF(let rounds, _)?:
            self = .aesKDF(rounds: rounds)
        case .argon2(let parameters)?:
            self = parameters.variant == .d
                ? .argon2d(iterations: parameters.iterations, memoryBytes: parameters.memoryBytes, parallelism: parameters.parallelism)
                : .argon2id(iterations: parameters.iterations, memoryBytes: parameters.memoryBytes, parallelism: parameters.parallelism)
        case nil:
            self = .unknown
        }
    }
}
