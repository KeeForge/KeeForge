import CommonCrypto
import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXKeyDerivationTests: XCTestCase {
    private let compositeKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let seed = Data((32..<64).map { UInt8($0) })
    private let policy = TestKDF.permissivePolicy
    private let password = SymmetricKey(data: Data("password".utf8))
    private let somesalt = Data("somesalt".utf8)

    // MARK: - Describing parameters

    func testAlgorithmUUIDsRoundTrip() {
        for algorithm in KDBXKeyDerivation.Algorithm.allCases {
            XCTAssertEqual(KDBXKeyDerivation.Algorithm(uuid: algorithm.uuid), algorithm)
        }
        XCTAssertEqual(KDBXKeyDerivation.Algorithm.aesKDF.uuid, Data(hex: "c9d9f39a628a4460bf740d08c18a4fea"))
        XCTAssertEqual(KDBXKeyDerivation.Algorithm.argon2d.uuid, Data(hex: "ef636ddf8c29444b91f7a9a403e30a0c"))
        XCTAssertEqual(KDBXKeyDerivation.Algorithm.argon2id.uuid, Data(hex: "9e298b1956db4773b23dfc3ec6f0a1e6"))
        XCTAssertNil(KDBXKeyDerivation.Algorithm(uuid: Data(count: 16)))
    }

    func testReadsAESKDFParameters() {
        let kdf = KDBXKeyDerivation(parameters: [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.aesKDF.uuid),
            "R": .uint64(6000),
            "S": .bytes(seed),
        ])
        XCTAssertEqual(kdf, .aesKDF(rounds: 6000, seed: seed))
        XCTAssertEqual(kdf?.algorithm, .aesKDF)
        XCTAssertEqual(kdf?.salt, seed)
    }

    func testMissingAESRoundsReadAsZero() {
        let kdf = KDBXKeyDerivation(parameters: ["$UUID": .bytes(KDBXKeyDerivation.Algorithm.aesKDF.uuid)])
        XCTAssertEqual(kdf, .aesKDF(rounds: 0, seed: nil))
        XCTAssertNil(kdf?.salt)
    }

    func testReadsArgon2ParametersAndDefaultsMissingOrMistypedOnes() {
        let full = KDBXKeyDerivation(parameters: [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2d.uuid),
            "I": .uint64(5), "M": .uint64(2048), "P": .uint32(4), "V": .uint32(0x10), "S": .bytes(seed),
        ])
        XCTAssertEqual(full, .argon2(.init(variant: .d, iterations: 5, memoryBytes: 2048, parallelism: 4, version: 0x10, salt: seed)))
        XCTAssertEqual(full?.algorithm, .argon2d)
        XCTAssertEqual(full?.salt, seed)

        let defaults = KDBXKeyDerivation(parameters: [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid),
            "I": .uint32(5),
            "P": .uint64(4),
        ])
        XCTAssertEqual(defaults, .argon2(.init(
            variant: .id,
            iterations: KDBXKeyDerivation.Argon2Parameters.defaultIterations,
            memoryBytes: KDBXKeyDerivation.Argon2Parameters.defaultMemoryBytes,
            parallelism: KDBXKeyDerivation.Argon2Parameters.defaultParallelism,
            version: KDBXKeyDerivation.Argon2Parameters.defaultVersion,
            salt: nil
        )))
        XCTAssertEqual(defaults?.algorithm, .argon2id)
        XCTAssertEqual(KDBXKeyDerivation.Argon2Parameters.defaultVersion, 0x13)
    }

    func testUnknownOrMissingKDFDescribesAsNil() {
        XCTAssertNil(KDBXKeyDerivation(parameters: [:]))
        XCTAssertNil(KDBXKeyDerivation(parameters: ["$UUID": .string("aes")]))
        XCTAssertNil(KDBXKeyDerivation(parameters: ["$UUID": .bytes(Data(count: 16))]))
    }

    func testParametersRoundTripAndOmitANilSalt() {
        let argon2 = KDBXKeyDerivation.argon2(.init(variant: .id, iterations: 2, memoryBytes: 4096, parallelism: 3, version: 0x10, salt: seed))
        XCTAssertEqual(argon2.parameters, [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid),
            "I": .uint64(2), "M": .uint64(4096), "P": .uint32(3), "V": .uint32(0x10), "S": .bytes(seed),
        ])
        XCTAssertEqual(KDBXKeyDerivation(parameters: argon2.parameters), argon2)

        let aes = KDBXKeyDerivation.aesKDF(rounds: 7, seed: nil)
        XCTAssertEqual(aes.parameters, ["$UUID": .bytes(KDBXKeyDerivation.Algorithm.aesKDF.uuid), "R": .uint64(7)])
        XCTAssertEqual(KDBXKeyDerivation(parameters: aes.parameters), aes)
    }

    // MARK: - AES-KDF

    /// Expected values from Python's `cryptography` AES-ECB.
    func testAESKDFKnownAnswers() throws {
        XCTAssertEqual(
            try KDBXKeyDerivation.transformAESKDF(compositeKey: compositeKey, seed: seed, rounds: 10).hex,
            "f76f387e7538424a09d988e6f358824cd30d0dd35d0e8ecb1487ff6ffc1581cf"
        )
        XCTAssertEqual(
            try KDBXKeyDerivation.transformAESKDF(compositeKey: compositeKey, seed: seed, rounds: 1).hex,
            "cc90ad15c134f62626e42e128d9ec14cd0f8a74dd38ee7b09847ff1ad4551258"
        )
    }

    func testAESKDFMatchesAReferenceTwoHalvesImplementation() throws {
        for rounds: UInt64 in [0, 2, 11, 257] {
            XCTAssertEqual(
                try KDBXKeyDerivation.transformAESKDF(compositeKey: compositeKey, seed: seed, rounds: rounds),
                try referenceAESKDF(rounds: rounds),
                "rounds \(rounds)"
            )
        }
    }

    func testAESKDFRejectsWrongKeyOrSeedSize() {
        assertThrows(KDBXCrypto.CryptoError.invalidKey) {
            try KDBXKeyDerivation.transformAESKDF(compositeKey: SymmetricKey(data: Data(count: 16)), seed: self.seed, rounds: 1)
        }
        assertThrows(KDBXCrypto.CryptoError.invalidKey) {
            try KDBXKeyDerivation.transformAESKDF(compositeKey: self.compositeKey, seed: Data(count: 16), rounds: 1)
        }
    }

    func testDeriveKeyRunsAESKDFFromParameters() throws {
        let derived = try KDBXKeyDerivation.deriveKey(
            compositeKey: compositeKey,
            parameters: KDBXKeyDerivation.aesKDF(rounds: 10, seed: seed).parameters,
            policy: policy
        )
        XCTAssertEqual(derived.hex, "f76f387e7538424a09d988e6f358824cd30d0dd35d0e8ecb1487ff6ffc1581cf")
    }

    func testDeriveKeyRejectsAESRoundsOutsideTheRange() {
        let max = KDBXKeyDerivation.aesKDFMaxRounds
        XCTAssertEqual(max, 100_000_000)
        for rounds in [0, max + 1, .max] {
            assertThrows(KDBXContainer.ParseError.kdfParameterOutOfRange("rounds \(rounds) not in 1...\(max)")) {
                try KDBXKeyDerivation.deriveKey(
                    compositeKey: self.compositeKey,
                    parameters: KDBXKeyDerivation.aesKDF(rounds: rounds, seed: self.seed).parameters,
                    policy: self.policy
                )
            }
        }
    }

    // MARK: - Unsupported parameter sets

    func testDeriveKeyReportsWhyParametersAreUnusable() {
        assertThrows(KDBXCrypto.CryptoError.unsupportedKDF(.missingUUID)) {
            try KDBXKeyDerivation.deriveKey(compositeKey: self.compositeKey, parameters: ["R": .uint64(1)], policy: self.policy)
        }
        let unknown = Data(repeating: 0xAB, count: 16)
        assertThrows(KDBXCrypto.CryptoError.unsupportedKDF(.unknownUUID(unknown))) {
            try KDBXKeyDerivation.deriveKey(compositeKey: self.compositeKey, parameters: ["$UUID": .bytes(unknown)], policy: self.policy)
        }
        assertThrows(KDBXCrypto.CryptoError.unsupportedKDF(.missingSalt(.aesKDF))) {
            try KDBXKeyDerivation.deriveKey(
                compositeKey: self.compositeKey,
                parameters: KDBXKeyDerivation.aesKDF(rounds: 1, seed: nil).parameters,
                policy: self.policy
            )
        }
        assertThrows(KDBXCrypto.CryptoError.unsupportedKDF(.missingSalt(.argon2d))) {
            try KDBXKeyDerivation.deriveKey(
                compositeKey: self.compositeKey,
                parameters: self.argon2(variant: .d, salt: nil),
                policy: self.policy
            )
        }
    }

    // MARK: - Argon2

    /// phc-winner-argon2 `src/test.c`, Argon2id v1.3.
    func testArgon2idReferenceVectors() throws {
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 256, parallelism: 1, version: 0x13, variant: .id).hex,
            "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe"
        )
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 256, parallelism: 2, version: 0x13, variant: .id).hex,
            "6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037"
        )
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 65_536, parallelism: 1, version: 0x13, variant: .id).hex,
            "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7"
        )
    }

    /// The reference code's `argon2_hash`, built separately with -O2.
    func testArgon2dAndVersion10Vectors() throws {
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 65_536, parallelism: 1, version: 0x13, variant: .d).hex,
            "955e5d5b163a1b60bba35fc36d0496474fba4f6b59ad53628666f07fb2f93eaf"
        )
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 256, parallelism: 2, version: 0x13, variant: .d).hex,
            "7b69c92d7c3889aad1281dbc8baefc12cc37c80f1c75e33ef2c2d40c28ebc573"
        )
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 256, parallelism: 1, version: 0x10, variant: .d).hex,
            "bd404868ff00c52e7543c8332e6a772a5724892d7e328d5cf253bbc8e726b371"
        )
        XCTAssertEqual(
            try Argon2.hash(password: password, salt: somesalt, timeCost: 2, memoryCost: 256, parallelism: 1, version: 0x10, variant: .id).hex,
            "da070e576e50f2f38a3c897cbddc6c7fb4028e870971ff9eae7b4e1879295e6e"
        )
    }

    func testArgon2SurfacesTheReferenceErrorCode() {
        assertThrows(Argon2.Argon2Error.hashFailed(-6)) {
            try Argon2.hash(password: self.password, salt: Data("short".utf8), timeCost: 2, memoryCost: 8, parallelism: 1, version: 0x13, variant: .id)
        }
    }

    /// KDBX passes the memory in bytes; Argon2 takes KiB.
    func testDeriveKeyRunsArgon2FromParameters() throws {
        let derived = try KDBXKeyDerivation.deriveKey(
            compositeKey: password,
            parameters: [
                "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid),
                "I": .uint64(2), "M": .uint64(256 * 1024), "P": .uint32(1), "V": .uint32(0x13), "S": .bytes(somesalt),
            ],
            policy: policy
        )
        XCTAssertEqual(derived.hex, "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe")

        let argon2d = try KDBXKeyDerivation.deriveKey(
            compositeKey: password,
            parameters: [
                "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2d.uuid),
                "I": .uint64(2), "M": .uint64(256 * 1024), "P": .uint32(1), "V": .uint32(0x10), "S": .bytes(somesalt),
            ],
            policy: policy
        )
        XCTAssertEqual(argon2d.hex, "bd404868ff00c52e7543c8332e6a772a5724892d7e328d5cf253bbc8e726b371")
    }

    func testAbsentArgon2VersionDerivesAsVersion13() throws {
        var parameters: KDBXVariantMap = [
            "$UUID": .bytes(KDBXKeyDerivation.Algorithm.argon2id.uuid),
            "I": .uint64(2), "M": .uint64(256 * 1024), "P": .uint32(1), "S": .bytes(somesalt),
        ]
        let absent = try KDBXKeyDerivation.deriveKey(compositeKey: password, parameters: parameters, policy: policy)
        parameters["V"] = .uint32(0x13)
        XCTAssertEqual(absent, try KDBXKeyDerivation.deriveKey(compositeKey: password, parameters: parameters, policy: policy))
        parameters["V"] = .uint32(0x10)
        XCTAssertNotEqual(absent, try KDBXKeyDerivation.deriveKey(compositeKey: password, parameters: parameters, policy: policy))
    }

    func testDeriveKeyRejectsArgon2ParametersOutsideTheFormat() {
        let cases: [(KDBXVariantMap, String)] = [
            (argon2(iterations: 0), "iterations 0 must be >= 1"),
            (argon2(parallelism: 0), "parallelism 0 not in 1...16777215"),
            (argon2(parallelism: 0x100_0000), "parallelism 16777216 not in 1...16777215"),
            (argon2(memory: 8191), "memory 8191 bytes below Argon2 minimum for 1 lanes"),
            (argon2(memory: 16 * 1024, parallelism: 3), "memory 16384 bytes below Argon2 minimum for 3 lanes"),
            (argon2(version: 0x12), "unsupported Argon2 version 0x12"),
            (argon2(iterations: 1 << 32), "iterations 4294967296 overflows UInt32"),
            (argon2(memory: 1 << 42), "memory 4398046511104 bytes overflows UInt32 KiB"),
        ]
        for (parameters, message) in cases {
            assertThrows(KDBXContainer.ParseError.kdfParameterOutOfRange(message)) {
                try KDBXKeyDerivation.deriveKey(compositeKey: self.compositeKey, parameters: parameters, policy: self.policy)
            }
        }
    }

    func testDeriveKeyChecksThePolicyBeforeRunningArgon2() {
        let policy = KDFExecutionPolicy(maxPeakMemoryBytes: 1 << 20, maxTotalWorkBytes: 1 << 30, maxParallelism: 4)
        assertThrows(KDBXContainer.ParseError.kdfResourceLimitExceeded(iterations: 1 << 40, memoryBytes: 1 << 30, parallelism: 1)) {
            try KDBXKeyDerivation.deriveKey(
                compositeKey: self.compositeKey,
                parameters: self.argon2(iterations: 1 << 40, memory: 1 << 30),
                policy: policy
            )
        }
    }

    func testDeriveKeySurfacesArgon2Failures() {
        assertThrows(Argon2.Argon2Error.hashFailed(-6)) {
            try KDBXKeyDerivation.deriveKey(
                compositeKey: self.compositeKey,
                parameters: self.argon2(salt: Data("short".utf8)),
                policy: self.policy
            )
        }
    }

    // MARK: - Helpers

    private func argon2(
        variant: KDBXKeyDerivation.Argon2Variant = .id,
        iterations: UInt64 = 1,
        memory: UInt64 = 8192,
        parallelism: UInt32 = 1,
        version: UInt32 = 0x13,
        salt: Data? = Data(repeating: 1, count: 16)
    ) -> KDBXVariantMap {
        KDBXKeyDerivation.argon2(.init(
            variant: variant,
            iterations: iterations,
            memoryBytes: memory,
            parallelism: parallelism,
            version: version,
            salt: salt
        )).parameters
    }

    /// AES-KDF as KeePass describes it: each 16-byte half of the key encrypted
    /// `rounds` times with AES-256-ECB, then SHA-256 of the result.
    private func referenceAESKDF(rounds: UInt64) throws -> Data {
        let key = compositeKey.bytes
        var halves = [Data(key.prefix(16)), Data(key.suffix(16))]
        for _ in 0..<rounds {
            halves = try halves.map { try encryptBlock($0) }
        }
        return Data(SHA256.hash(data: halves[0] + halves[1]))
    }

    private func encryptBlock(_ block: Data) throws -> Data {
        var output = Data(count: 16)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            block.withUnsafeBytes { input in
                seed.withUnsafeBytes { key in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        key.baseAddress, key.count, nil,
                        input.baseAddress, 16, out.baseAddress, 16, &moved
                    )
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return output
    }
}
