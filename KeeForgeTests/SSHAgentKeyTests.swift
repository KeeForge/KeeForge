#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

/// OpenSSH private key parsing and signing against keys and signatures that
/// Python's `cryptography` produced (`Support/SSHAgentTestKeys.swift`).
final class SSHAgentKeyTests: XCTestCase {
    private typealias Keys = SSHAgentTestKeys

    // MARK: - Parsing

    func testParsesEverySupportedKeyTypeToItsPublicKey() throws {
        let expectations: [(Keys.Fixture, SSHAgentKey.Algorithm)] = [
            (Keys.ed25519, .ed25519),
            (Keys.ed25519WrittenByCryptography, .ed25519),
            (Keys.ecdsaP256, .ecdsaP256),
            (Keys.ecdsaP384, .ecdsaP384),
            (Keys.ecdsaP521, .ecdsaP521),
            (Keys.rsa, .rsa(bits: 2048)),
            (Keys.rsaWrittenByCryptography, .rsa(bits: 2048)),
        ]
        for (fixture, algorithm) in expectations {
            let key = try SSHAgentKey(privateKeyFile: fixture.fileData)

            XCTAssertEqual(key.algorithm, algorithm)
            XCTAssertEqual(key.publicKeyBlob, fixture.publicKeyData, "\(algorithm)")
            XCTAssertEqual(key.fingerprint, fixture.fingerprint, "\(algorithm)")
            XCTAssertEqual(key.comment, fixture.comment, "\(algorithm)")
        }
    }

    func testToleratesWindowsLineEndingsAndSurroundingText() throws {
        let file = "Notes above the key\r\n" + Keys.ed25519.privateKeyFile.replacingOccurrences(of: "\n", with: "\r\n")

        let key = try SSHAgentKey(privateKeyFile: Data(file.utf8))

        XCTAssertEqual(key.publicKeyBlob, Keys.ed25519.publicKeyData)
    }

    func testPassphraseProtectedKeyIsReportedAsSuch() {
        XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: Keys.ed25519PassphraseProtected.fileData)) {
            XCTAssertEqual($0 as? SSHAgentKeyError, .passphraseProtected)
        }
    }

    func testOtherPrivateKeyFormatsAreUnsupported() {
        let files = [
            Keys.rsaTraditionalPEM,
            "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n",
            "ssh-ed25519 \(Keys.ed25519.publicKeyBlob) public@keeforge.test\n",
        ]
        for file in files {
            XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: Data(file.utf8))) {
                XCTAssertEqual($0 as? SSHAgentKeyError, .unsupportedFormat)
            }
        }
    }

    func testKeyWhosePublicKeyDoesNotMatchItsPrivateKeyIsRejected() throws {
        var body = try XCTUnwrap(Self.armoredBody(of: Keys.ed25519.privateKeyFile))
        // The first copy of the public key blob is the container's; the private
        // section's own copy, which the private key derives, stays intact.
        let outerPublicKey = try XCTUnwrap(body.range(of: Keys.ed25519.publicKeyData))
        body[outerPublicKey.upperBound - 1] ^= 0x01

        XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: Self.armored(body))) {
            XCTAssertEqual($0 as? SSHAgentKeyError, .malformed)
        }
    }

    func testTruncatedKeyIsRejected() throws {
        let body = try XCTUnwrap(Self.armoredBody(of: Keys.ecdsaP256.privateKeyFile))

        XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: Self.armored(body.prefix(body.count - 9)))) {
            XCTAssertEqual($0 as? SSHAgentKeyError, .malformed)
        }
    }

    /// OpenSSH refuses RSA keys under 1024 and over 16384 bits. The upper
    /// bound matters here beyond compatibility: signing derives two exponents
    /// with arithmetic whose cost grows with the square of the key size.
    func testRSAKeysOutsideOpenSSHsSizeLimitsAreRejected() throws {
        func number(bytes: Int) -> Data { Data([0x7F]) + Data(repeating: 0xFF, count: bytes - 1) }
        let usable = try Self.rsaKeyFile(modulusBytes: 256, number: number)
        XCTAssertEqual(try SSHAgentKey(privateKeyFile: usable).algorithm, .rsa(bits: 2047))

        for modulusBytes in [64, 2049, 100_000] {
            let file = try Self.rsaKeyFile(modulusBytes: modulusBytes, number: number)
            XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: file), "\(modulusBytes) bytes") {
                XCTAssertEqual($0 as? SSHAgentKeyError, .malformed)
            }
        }
    }

    /// A private exponent or prime longer than the modulus belongs to no RSA
    /// key, and is what would make deriving the CRT exponents expensive.
    func testRSAKeyWithAComponentLongerThanItsModulusIsRejected() throws {
        func number(bytes: Int) -> Data { Data([0x7F]) + Data(repeating: 0xFF, count: bytes - 1) }
        for oversized in ["privateExponent", "prime1"] {
            let file = try Self.rsaKeyFile(modulusBytes: 256, oversized: oversized, number: number)
            XCTAssertThrowsError(try SSHAgentKey(privateKeyFile: file), oversized) {
                XCTAssertEqual($0 as? SSHAgentKeyError, .malformed)
            }
        }
    }

    func testRecognizesPrivateKeyFilesOfAnyFormat() {
        XCTAssertTrue(SSHAgentKey.looksLikePrivateKey(Keys.ed25519.fileData))
        XCTAssertTrue(SSHAgentKey.looksLikePrivateKey(Keys.ed25519PassphraseProtected.fileData))
        XCTAssertTrue(SSHAgentKey.looksLikePrivateKey(Data(Keys.rsaTraditionalPEM.utf8)))
        XCTAssertTrue(SSHAgentKey.looksLikePrivateKey(Data("\nPuTTY-User-Key-File-2: ssh-rsa\n".utf8)))

        XCTAssertFalse(SSHAgentKey.looksLikePrivateKey(Data("ssh-ed25519 \(Keys.ed25519.publicKeyBlob)".utf8)))
        XCTAssertFalse(SSHAgentKey.looksLikePrivateKey(Data("-----BEGIN CERTIFICATE-----\n".utf8)))
        XCTAssertFalse(SSHAgentKey.looksLikePrivateKey(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    // MARK: - Signing

    func testEd25519SignatureVerifies() throws {
        let key = try SSHAgentKey(privateKeyFile: Keys.ed25519.fileData)

        var signature = SSHWireReader(try key.signature(for: Keys.message, flags: 0))
        let signatureType = try signature.readString()
        let bytes = try signature.readString()

        XCTAssertEqual(signatureType, Data("ssh-ed25519".utf8))
        XCTAssertTrue(signature.isAtEnd)
        var publicKey = SSHWireReader(Keys.ed25519.publicKeyData)
        _ = try publicKey.readString()
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: try publicKey.readString())
        XCTAssertTrue(verifier.isValidSignature(bytes, for: Keys.message))
        XCTAssertFalse(verifier.isValidSignature(bytes, for: Data("another message".utf8)))
    }

    func testECDSASignaturesVerifyOnEachCurve() throws {
        for fixture in [Keys.ecdsaP256, Keys.ecdsaP384, Keys.ecdsaP521] {
            let key = try SSHAgentKey(privateKeyFile: fixture.fileData)
            var publicKey = SSHWireReader(fixture.publicKeyData)
            let keyType = try publicKey.readString()
            _ = try publicKey.readString()
            let point = try publicKey.readString()

            var signature = SSHWireReader(try key.signature(for: Keys.message, flags: 0))
            let signatureType = try signature.readString()
            XCTAssertEqual(signatureType, keyType)
            var integers = SSHWireReader(try signature.readString())
            let r = try integers.readMPInt()
            let s = try integers.readMPInt()
            XCTAssertTrue(integers.isAtEnd)

            switch key.algorithm {
            case .ecdsaP256:
                let raw = try Self.padded(r, 32) + Self.padded(s, 32)
                let verifier = try P256.Signing.PublicKey(x963Representation: point)
                XCTAssertTrue(verifier.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: Keys.message))
            case .ecdsaP384:
                let raw = try Self.padded(r, 48) + Self.padded(s, 48)
                let verifier = try P384.Signing.PublicKey(x963Representation: point)
                XCTAssertTrue(verifier.isValidSignature(try P384.Signing.ECDSASignature(rawRepresentation: raw), for: Keys.message))
            case .ecdsaP521:
                let raw = try Self.padded(r, 66) + Self.padded(s, 66)
                let verifier = try P521.Signing.PublicKey(x963Representation: point)
                XCTAssertTrue(verifier.isValidSignature(try P521.Signing.ECDSASignature(rawRepresentation: raw), for: Keys.message))
            default:
                XCTFail("Unexpected algorithm \(key.algorithm)")
            }
        }
    }

    /// PKCS #1 v1.5 is deterministic, so a byte-for-byte match with the
    /// reference also proves the CRT exponents KeeForge derives are right.
    func testRSASignaturesMatchTheReferenceForEachHash() throws {
        for fixture in [Keys.rsa, Keys.rsaWrittenByCryptography] {
            let key = try SSHAgentKey(privateKeyFile: fixture.fileData)

            XCTAssertEqual(
                try key.signature(for: Keys.message, flags: SSHAgentKey.rsaSHA256Flag).base64EncodedString(),
                Keys.rsaSHA256SignatureBlob
            )
            XCTAssertEqual(
                try key.signature(for: Keys.message, flags: SSHAgentKey.rsaSHA512Flag).base64EncodedString(),
                Keys.rsaSHA512SignatureBlob
            )
        }
    }

    func testRSAPrefersSHA256WhenBothHashesAreAllowed() throws {
        let key = try SSHAgentKey(privateKeyFile: Keys.rsa.fileData)
        let flags = SSHAgentKey.rsaSHA256Flag | SSHAgentKey.rsaSHA512Flag

        XCTAssertEqual(try key.signature(for: Keys.message, flags: flags).base64EncodedString(), Keys.rsaSHA256SignatureBlob)
    }

    func testRSAWithoutASHA2FlagIsRefused() throws {
        let key = try SSHAgentKey(privateKeyFile: Keys.rsa.fileData)

        XCTAssertThrowsError(try key.signature(for: Keys.message, flags: 0)) {
            XCTAssertEqual($0 as? SSHAgentKeyError, .unsupportedSignatureAlgorithm)
        }
    }

    // MARK: - Helpers

    /// An `openssh-key-v1` file around RSA numbers of the given size. The
    /// numbers are not a working key; the parser reads sizes before anything
    /// signs with them.
    private static func rsaKeyFile(
        modulusBytes: Int,
        oversized: String? = nil,
        number: (Int) -> Data
    ) throws -> Data {
        func component(_ name: String, bytes: Int) -> Data {
            number(name == oversized ? modulusBytes + 1 : bytes)
        }
        let modulus = number(modulusBytes)
        let publicExponent = Data([0x01, 0x00, 0x01])

        var publicKey = SSHWireWriter()
        publicKey.writeString("ssh-rsa")
        publicKey.writeMPInt(publicExponent)
        publicKey.writeMPInt(modulus)

        var section = SSHWireWriter()
        section.writeUInt32(0x4B46_4B46)
        section.writeUInt32(0x4B46_4B46)
        section.writeString("ssh-rsa")
        section.writeMPInt(modulus)
        section.writeMPInt(publicExponent)
        section.writeMPInt(component("privateExponent", bytes: modulusBytes))
        section.writeMPInt(component("coefficient", bytes: modulusBytes / 2))
        section.writeMPInt(component("prime1", bytes: modulusBytes / 2))
        section.writeMPInt(component("prime2", bytes: modulusBytes / 2))
        section.writeString("crafted")
        var privateSection = section.data
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(pad)
            pad += 1
        }

        var body = SSHWireWriter()
        body.writeString("none")
        body.writeString("none")
        body.writeString(Data())
        body.writeUInt32(1)
        body.writeString(publicKey.data)
        body.writeString(privateSection)
        return armored(Data("openssh-key-v1\0".utf8) + body.data)
    }

    private static func armoredBody(of file: String) -> Data? {
        let base64 = file.split(separator: "\n").filter { $0.hasPrefix("-----") == false }.joined()
        return Data(base64Encoded: base64)
    }

    private static func armored(_ body: Data) -> Data {
        Data("-----BEGIN OPENSSH PRIVATE KEY-----\n\(body.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
    }

    private static func padded(_ magnitude: Data, _ width: Int) throws -> Data {
        guard magnitude.count <= width else { throw SSHAgentKeyError.malformed }
        return Data(repeating: 0, count: width - magnitude.count) + magnitude
    }
}
#endif
