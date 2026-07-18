import Foundation

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

    let formatVersion: KDBXParser.FileVersion
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
        let version = try KDBXParser.parseFileVersion(from: data)
        switch version {
        case .kdbx3_1:
            let header = try KDBXParser.parseKDBX3Header(from: data)
            return KDBXFileSummary(
                formatVersion: version,
                cipher: KDBXOuterCipher(uuid: header.cipherID),
                isCompressed: header.compressionFlags == 1,
                keyDerivation: .aesKDF(rounds: header.transformRounds)
            )
        case .kdbx4:
            var reader = DataReader(data: data)
            _ = try KDBXParser.parseVersion(from: &reader)
            let header = try KDBXParser.parseHeader(&reader)
            return KDBXFileSummary(
                formatVersion: version,
                cipher: KDBXOuterCipher(uuid: header.cipherID),
                isCompressed: header.compressionFlags == 1,
                keyDerivation: keyDerivation(fromKDFParameters: header.kdfParameters)
            )
        }
    }

    // Missing-parameter fallbacks mirror KDBXParser.deriveKey so the displayed
    // values match what unlock actually uses.
    private static func keyDerivation(fromKDFParameters params: [String: Any]) -> KeyDerivation {
        guard let uuid = params["$UUID"] as? Data else { return .unknown }

        if uuid == KDBXParser.aesKDFUUID {
            return .aesKDF(rounds: (params["R"] as? UInt64) ?? 0)
        }

        let iterations = (params["I"] as? UInt64) ?? 3
        let memoryBytes = (params["M"] as? UInt64) ?? (64 * 1024 * 1024)
        let parallelism = (params["P"] as? UInt32) ?? 1

        if uuid == KDBXParser.argon2dUUID {
            return .argon2d(iterations: iterations, memoryBytes: memoryBytes, parallelism: parallelism)
        }
        if uuid == KDBXParser.argon2idUUID {
            return .argon2id(iterations: iterations, memoryBytes: memoryBytes, parallelism: parallelism)
        }
        return .unknown
    }
}
