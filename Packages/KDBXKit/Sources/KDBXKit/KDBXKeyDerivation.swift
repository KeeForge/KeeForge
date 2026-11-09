import CommonCrypto
import CryptoKit
import Foundation
import argon2

/// A key derivation function and its settings, read from KDF parameters the
/// way KeePass reads them: a missing or wrongly typed cost value takes
/// KeePass's default. The salt is optional here so a header can be described
/// before it is validated; deriving a key requires one.
public enum KDBXKeyDerivation: Sendable, Hashable {
    case aesKDF(rounds: UInt64, seed: Data?)
    case argon2(Argon2Parameters)

    public enum Algorithm: Sendable, Hashable, CaseIterable {
        case aesKDF
        case argon2d
        case argon2id

        public var uuid: Data {
            switch self {
            case .aesKDF:
                Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                      0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
            case .argon2d:
                Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B,
                      0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
            case .argon2id:
                Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73,
                      0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
            }
        }

        public init?(uuid: Data) {
            guard let algorithm = Self.allCases.first(where: { $0.uuid == uuid }) else { return nil }
            self = algorithm
        }
    }

    public enum Argon2Variant: Sendable, Hashable {
        case d
        case id
    }

    public struct Argon2Parameters: Sendable, Hashable {
        public var variant: Argon2Variant
        public var iterations: UInt64
        public var memoryBytes: UInt64
        public var parallelism: UInt32
        public var version: UInt32
        public var salt: Data?

        public init(
            variant: Argon2Variant,
            iterations: UInt64,
            memoryBytes: UInt64,
            parallelism: UInt32,
            version: UInt32 = Argon2Parameters.defaultVersion,
            salt: Data?
        ) {
            self.variant = variant
            self.iterations = iterations
            self.memoryBytes = memoryBytes
            self.parallelism = parallelism
            self.version = version
            self.salt = salt
        }

        public static let defaultIterations: UInt64 = 3
        public static let defaultMemoryBytes: UInt64 = 64 * 1024 * 1024
        public static let defaultParallelism: UInt32 = 1
        /// Argon2 1.3.
        public static let defaultVersion: UInt32 = 0x13
    }

    /// The largest AES-KDF round count this library will run.
    public static let aesKDFMaxRounds: UInt64 = 100_000_000

    /// Why a parameter set cannot derive a key.
    public enum Unsupported: Sendable, Hashable {
        case missingUUID
        case missingSalt(Algorithm)
        case unknownUUID(Data)
    }

    private enum Key {
        static let uuid = "$UUID"
        static let salt = "S"
        static let rounds = "R"
        static let iterations = "I"
        static let memory = "M"
        static let parallelism = "P"
        static let version = "V"
    }

    /// nil when the parameters name no KDF or one this library does not know.
    public init?(parameters: KDBXVariantMap) {
        guard let uuid = parameters.bytes(Key.uuid), let algorithm = Algorithm(uuid: uuid) else { return nil }
        let salt = parameters.bytes(Key.salt)
        switch algorithm {
        case .aesKDF:
            self = .aesKDF(rounds: parameters.uint64(Key.rounds) ?? 0, seed: salt)
        case .argon2d, .argon2id:
            self = .argon2(Argon2Parameters(
                variant: algorithm == .argon2d ? .d : .id,
                iterations: parameters.uint64(Key.iterations) ?? Argon2Parameters.defaultIterations,
                memoryBytes: parameters.uint64(Key.memory) ?? Argon2Parameters.defaultMemoryBytes,
                parallelism: parameters.uint32(Key.parallelism) ?? Argon2Parameters.defaultParallelism,
                version: parameters.uint32(Key.version) ?? Argon2Parameters.defaultVersion,
                salt: salt
            ))
        }
    }

    public var algorithm: Algorithm {
        switch self {
        case .aesKDF: .aesKDF
        case .argon2(let parameters): parameters.variant == .d ? .argon2d : .argon2id
        }
    }

    /// The AES-KDF seed or Argon2 salt.
    public var salt: Data? {
        switch self {
        case .aesKDF(_, let seed): seed
        case .argon2(let parameters): parameters.salt
        }
    }

    /// The parameters as KeePass stores them, for a new or changed header.
    /// A nil salt is left out; the writer generates a fresh one on every save.
    public var parameters: KDBXVariantMap {
        var map: KDBXVariantMap = [Key.uuid: .bytes(algorithm.uuid)]
        switch self {
        case .aesKDF(let rounds, _):
            map[Key.rounds] = .uint64(rounds)
        case .argon2(let parameters):
            map[Key.iterations] = .uint64(parameters.iterations)
            map[Key.memory] = .uint64(parameters.memoryBytes)
            map[Key.parallelism] = .uint32(parameters.parallelism)
            map[Key.version] = .uint32(parameters.version)
        }
        if let salt {
            map[Key.salt] = .bytes(salt)
        }
        return map
    }

    // MARK: - Deriving

    /// Runs the KDF named by `parameters` over the composite key, returning the
    /// transformed key. The parameters come from an untrusted header: each is
    /// checked against the KDF's format limits, and Argon2's cost against
    /// `policy`, before any work runs.
    public static func deriveKey(
        compositeKey: SymmetricKey,
        parameters: KDBXVariantMap,
        policy: KDFExecutionPolicy
    ) throws -> Data {
        guard let uuid = parameters.bytes(Key.uuid) else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(.missingUUID)
        }
        guard let keyDerivation = KDBXKeyDerivation(parameters: parameters) else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(.unknownUUID(uuid))
        }
        guard let salt = keyDerivation.salt else {
            throw KDBXCrypto.CryptoError.unsupportedKDF(.missingSalt(keyDerivation.algorithm))
        }

        switch keyDerivation {
        case .aesKDF(let rounds, _):
            guard rounds >= 1, rounds <= aesKDFMaxRounds else {
                throw KDBXContainer.ParseError.kdfParameterOutOfRange("rounds \(rounds) not in 1...\(aesKDFMaxRounds)")
            }
            return try transformAESKDF(compositeKey: compositeKey, seed: salt, rounds: rounds)
        case .argon2(let argon2):
            return try deriveArgon2(compositeKey: compositeKey, parameters: argon2, salt: salt, policy: policy)
        }
    }

    private static func deriveArgon2(
        compositeKey: SymmetricKey,
        parameters: Argon2Parameters,
        salt: Data,
        policy: KDFExecutionPolicy
    ) throws -> Data {
        let iterations = parameters.iterations
        let memory = parameters.memoryBytes
        let parallelism = parameters.parallelism

        // Format validation (RFC 9106).
        guard iterations >= 1 else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("iterations \(iterations) must be >= 1")
        }
        guard parallelism >= 1, parallelism <= 0xFF_FFFF else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("parallelism \(parallelism) not in 1...16777215")
        }
        let memoryKiB = memory / 1024
        guard memory >= 8192, memoryKiB >= 8 * UInt64(parallelism) else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("memory \(memory) bytes below Argon2 minimum for \(parallelism) lanes")
        }
        guard parameters.version == 0x10 || parameters.version == 0x13 else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("unsupported Argon2 version 0x\(String(parameters.version, radix: 16))")
        }

        // Before the UInt32 conversions, so absurd values get the actionable
        // resource-limit error rather than a generic one.
        try policy.validate(iterations: iterations, memoryBytes: memory, parallelism: parallelism)

        guard let iterationsU32 = UInt32(exactly: iterations) else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("iterations \(iterations) overflows UInt32")
        }
        guard let memoryCostU32 = UInt32(exactly: memoryKiB) else {
            throw KDBXContainer.ParseError.kdfParameterOutOfRange("memory \(memory) bytes overflows UInt32 KiB")
        }

        return try Argon2.hash(
            password: compositeKey,
            salt: salt,
            timeCost: iterationsU32,
            memoryCost: memoryCostU32,
            parallelism: parallelism,
            version: parameters.version,
            variant: parameters.variant
        )
    }

    // MARK: - AES-KDF

    /// `rounds` encryptions of the composite key with AES-256-ECB under `seed`,
    /// then SHA-256.
    static func transformAESKDF(compositeKey: SymmetricKey, seed: Data, rounds: UInt64) throws -> Data {
        guard compositeKey.bitCount == kCCKeySizeAES256 * 8, seed.count == kCCKeySizeAES256 else {
            throw KDBXCrypto.CryptoError.invalidKey
        }

        var derived = compositeKey.withUnsafeBytes { [UInt8]($0) }
        defer { SecureWipe.wipe(&derived) }

        var cryptor: CCCryptorRef?
        let createStatus = seed.withUnsafeBytes { seedBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt),
                CCMode(kCCModeECB),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                nil,
                seedBytes.baseAddress,
                seed.count,
                nil,
                0,
                0,
                CCModeOptions(),
                &cryptor
            )
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw KDBXCrypto.CryptoError.encryptionFailed
        }
        defer { CCCryptorRelease(cryptor) }

        let blockByteCount = derived.count
        let updateStatus = derived.withUnsafeMutableBytes { derivedPtr in
            var bytesMoved = 0
            for _ in 0..<rounds {
                let status = CCCryptorUpdate(
                    cryptor,
                    derivedPtr.baseAddress,
                    blockByteCount,
                    derivedPtr.baseAddress,
                    blockByteCount,
                    &bytesMoved
                )
                if status != kCCSuccess || bytesMoved != blockByteCount {
                    return CCCryptorStatus(kCCUnspecifiedError)
                }
            }
            return CCCryptorStatus(kCCSuccess)
        }
        guard updateStatus == kCCSuccess else {
            throw KDBXCrypto.CryptoError.encryptionFailed
        }

        return Data(CryptoKit.SHA256.hash(data: derived))
    }
}

// MARK: - Argon2

enum Argon2 {
    enum Argon2Error: Error, Equatable, Sendable {
        case hashFailed(Int32)
    }

    static func hash(
        password: SymmetricKey,
        salt: Data,
        timeCost: UInt32,
        memoryCost: UInt32, // KiB
        parallelism: UInt32,
        hashLength: Int = 32,
        version: UInt32,
        variant: KDBXKeyDerivation.Argon2Variant
    ) throws -> Data {
        let type: argon2_type = switch variant {
        case .d: Argon2_d
        case .id: Argon2_id
        }

        var output = [UInt8](repeating: 0, count: hashLength)
        defer { SecureWipe.wipe(&output) }

        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    argon2_hash(
                        timeCost,
                        memoryCost,
                        parallelism,
                        passwordBytes.baseAddress,
                        passwordBytes.count,
                        saltBytes.baseAddress,
                        saltBytes.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        nil,
                        0,
                        type,
                        version
                    )
                }
            }
        }

        guard status == Int32(ARGON2_OK.rawValue) else {
            throw Argon2Error.hashFailed(status)
        }
        return Data(output)
    }
}
