#if os(macOS)
import CryptoKit
import Foundation
import Security

enum SSHAgentKeyError: Error, Equatable {
    /// Not an OpenSSH private key file (PEM, PKCS#8, PuTTY, or anything else).
    case unsupportedFormat
    /// An OpenSSH key sealed with a passphrase.
    case passphraseProtected
    case unsupportedKeyType(String)
    /// RSA signatures need the SHA-2 flags; SHA-1 (`ssh-rsa`) is refused.
    case unsupportedSignatureAlgorithm
    case malformed
    case signingFailed
}

/// An unencrypted OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`,
/// the PROTOCOL.key format `ssh-keygen` writes by default) that can sign
/// agent requests: Ed25519, ECDSA P-256/P-384/P-521, and RSA.
///
/// Parsed from the attachment bytes for each use and dropped afterwards, so no
/// key outlives the request that needed it.
struct SSHAgentKey {
    enum Algorithm: Sendable, Equatable {
        case ed25519
        case ecdsaP256
        case ecdsaP384
        case ecdsaP521
        case rsa(bits: Int)

        var displayName: String {
            switch self {
            case .ed25519: "Ed25519"
            case .ecdsaP256: "ECDSA P-256"
            case .ecdsaP384: "ECDSA P-384"
            case .ecdsaP521: "ECDSA P-521"
            case .rsa(let bits): "RSA \(bits)"
            }
        }
    }

    /// `ssh-agent` flags on a sign request (draft-miller-ssh-agent §4.5.1).
    static let rsaSHA256Flag: UInt32 = 0x02
    static let rsaSHA512Flag: UInt32 = 0x04

    let algorithm: Algorithm
    /// The public key in SSH wire format, as `ssh-add -L` prints it base64-encoded.
    let publicKeyBlob: Data
    let comment: String
    private let privateKey: PrivateKey

    private enum PrivateKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(RSAComponents)
    }

    private static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let footer = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Data("openssh-key-v1\0".utf8)

    /// `SHA256:` plus the unpadded base64 digest, matching `ssh-add -l`.
    var fingerprint: String {
        let digest = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Whether `data` starts like a private key file of any format, so an
    /// unsupported one is reported instead of silently ignored.
    static func looksLikePrivateKey(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("PuTTY-User-Key-File-") {
            return true
        }
        guard head.hasPrefix("-----BEGIN "),
              let firstLine = head.split(whereSeparator: \.isNewline).first
        else { return false }
        return firstLine.hasSuffix("PRIVATE KEY-----")
    }

    init(privateKeyFile: Data) throws {
        var outer = SSHWireReader(try Self.decodeArmor(privateKeyFile))
        guard try outer.readBytes(Self.magic.count) == Self.magic else {
            throw SSHAgentKeyError.malformed
        }
        let cipherName = try outer.readString()
        let kdfName = try outer.readString()
        _ = try outer.readString()
        guard try outer.readUInt32() == 1 else { throw SSHAgentKeyError.malformed }
        let publicKeyBlob = try outer.readString()
        let privateSection = try outer.readString()
        guard outer.isAtEnd else { throw SSHAgentKeyError.malformed }
        guard cipherName == Data("none".utf8), kdfName == Data("none".utf8) else {
            throw SSHAgentKeyError.passphraseProtected
        }

        var section = SSHWireReader(privateSection)
        let checkInteger = try section.readUInt32()
        guard try section.readUInt32() == checkInteger else { throw SSHAgentKeyError.malformed }
        let keyType = String(decoding: try section.readString(), as: UTF8.self)
        let (algorithm, privateKey, derivedPublicKeyBlob) = try Self.readPrivateKey(keyType, from: &section)
        let comment = String(decoding: try section.readString(), as: UTF8.self)
        let padding = section.remainingBytes
        guard padding.elementsEqual((0 ..< padding.count).map { UInt8(truncatingIfNeeded: $0 + 1) }),
              derivedPublicKeyBlob == publicKeyBlob
        else { throw SSHAgentKeyError.malformed }

        self.algorithm = algorithm
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
        self.privateKey = privateKey
    }

    /// The SSH signature blob over `data` (RFC 8709 §6, RFC 5656 §3.1.2,
    /// RFC 8332 §3). `flags` only matters for RSA.
    func signature(for data: Data, flags: UInt32) throws -> Data {
        var writer = SSHWireWriter()
        switch privateKey {
        case .ed25519(let key):
            writer.writeString("ssh-ed25519")
            writer.writeString(try key.signature(for: data))
        case .p256(let key):
            Self.writeECDSASignature(try key.signature(for: data).rawRepresentation, curve: "nistp256", to: &writer)
        case .p384(let key):
            Self.writeECDSASignature(try key.signature(for: data).rawRepresentation, curve: "nistp384", to: &writer)
        case .p521(let key):
            Self.writeECDSASignature(try key.signature(for: data).rawRepresentation, curve: "nistp521", to: &writer)
        case .rsa(let components):
            let (name, algorithm) = try Self.rsaSignatureAlgorithm(flags: flags)
            writer.writeString(name)
            writer.writeString(try components.signature(for: data, algorithm: algorithm))
        }
        return writer.data
    }

    /// Same precedence as OpenSSH's ssh-agent when both flags are set.
    private static func rsaSignatureAlgorithm(flags: UInt32) throws -> (String, SecKeyAlgorithm) {
        if flags & rsaSHA256Flag != 0 {
            return ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256)
        }
        if flags & rsaSHA512Flag != 0 {
            return ("rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512)
        }
        throw SSHAgentKeyError.unsupportedSignatureAlgorithm
    }

    private static func decodeArmor(_ file: Data) throws -> Data {
        guard let text = String(data: file, encoding: .utf8) else {
            throw SSHAgentKeyError.unsupportedFormat
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: header) else {
            throw SSHAgentKeyError.unsupportedFormat
        }
        guard let end = lines[(begin + 1)...].firstIndex(of: footer),
              let body = Data(base64Encoded: lines[(begin + 1) ..< end].joined())
        else { throw SSHAgentKeyError.malformed }
        return body
    }

    private static func readPrivateKey(
        _ keyType: String,
        from section: inout SSHWireReader
    ) throws -> (Algorithm, PrivateKey, Data) {
        var publicKey = SSHWireWriter()
        publicKey.writeString(keyType)
        switch keyType {
        case "ssh-ed25519":
            let publicBytes = try section.readString()
            let secret = try section.readString()
            // The secret is the 32-byte seed followed by the public key.
            guard publicBytes.count == 32, secret.count == 64, secret.suffix(32) == publicBytes else {
                throw SSHAgentKeyError.malformed
            }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
            guard key.publicKey.rawRepresentation == publicBytes else { throw SSHAgentKeyError.malformed }
            publicKey.writeString(publicBytes)
            return (.ed25519, .ed25519(key), publicKey.data)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try section.readString()
            let point = try section.readString()
            let scalar = try section.readMPInt()
            guard curve == Data(keyType.dropFirst("ecdsa-sha2-".count).utf8) else {
                throw SSHAgentKeyError.malformed
            }
            publicKey.writeString(curve)
            publicKey.writeString(point)
            let (algorithm, privateKey, derivedPoint) = try ecdsaPrivateKey(keyType, scalar: scalar)
            guard derivedPoint == point else { throw SSHAgentKeyError.malformed }
            return (algorithm, privateKey, publicKey.data)

        case "ssh-rsa":
            let components = RSAComponents(
                modulus: try section.readMPInt(),
                publicExponent: try section.readMPInt(),
                privateExponent: try section.readMPInt(),
                coefficient: try section.readMPInt(),
                prime1: try section.readMPInt(),
                prime2: try section.readMPInt()
            )
            guard components.isComplete else { throw SSHAgentKeyError.malformed }
            publicKey.writeMPInt(components.publicExponent)
            publicKey.writeMPInt(components.modulus)
            return (.rsa(bits: components.modulusBitCount), .rsa(components), publicKey.data)

        default:
            throw SSHAgentKeyError.unsupportedKeyType(keyType)
        }
    }

    /// The key and the uncompressed public point it derives.
    private static func ecdsaPrivateKey(_ keyType: String, scalar: Data) throws -> (Algorithm, PrivateKey, Data) {
        switch keyType {
        case "ecdsa-sha2-nistp256":
            let key = try P256.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 32))
            return (.ecdsaP256, .p256(key), key.publicKey.x963Representation)
        case "ecdsa-sha2-nistp384":
            let key = try P384.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 48))
            return (.ecdsaP384, .p384(key), key.publicKey.x963Representation)
        default:
            let key = try P521.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 66))
            return (.ecdsaP521, .p521(key), key.publicKey.x963Representation)
        }
    }

    private static func fixedWidth(_ magnitude: Data, _ width: Int) throws -> Data {
        guard magnitude.count <= width else { throw SSHAgentKeyError.malformed }
        return Data(repeating: 0, count: width - magnitude.count) + magnitude
    }

    private static func writeECDSASignature(_ raw: Data, curve: String, to writer: inout SSHWireWriter) {
        let half = raw.count / 2
        var inner = SSHWireWriter()
        inner.writeMPInt(raw.prefix(half))
        inner.writeMPInt(raw.suffix(half))
        writer.writeString("ecdsa-sha2-" + curve)
        writer.writeString(inner.data)
    }
}

/// The RSA fields of an OpenSSH private key, as unsigned big-endian magnitudes.
private struct RSAComponents: Sendable {
    let modulus: Data
    let publicExponent: Data
    let privateExponent: Data
    /// q⁻¹ mod p.
    let coefficient: Data
    let prime1: Data
    let prime2: Data

    var isComplete: Bool {
        [modulus, publicExponent, privateExponent, coefficient, prime1, prime2].allSatisfy { $0.isEmpty == false }
            && prime1 != Data([1]) && prime2 != Data([1])
    }

    var modulusBitCount: Int {
        guard let first = modulus.first else { return 0 }
        return modulus.count * 8 - first.leadingZeroBitCount
    }

    func signature(for data: Data, algorithm: SecKeyAlgorithm) throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1DER() as CFData, attributes as CFDictionary, &error),
              let signature = SecKeyCreateSignature(key, algorithm, data as CFData, &error)
        else {
            _ = error?.takeRetainedValue()
            throw SSHAgentKeyError.signingFailed
        }
        return signature as Data
    }

    /// PKCS#1 `RSAPrivateKey`, the only RSA private-key encoding
    /// `SecKeyCreateWithData` takes. OpenSSH stores no CRT exponents, so they
    /// are derived here: d mod (p − 1) and d mod (q − 1).
    private func pkcs1DER() -> Data {
        let exponent1 = BigUnsigned.remainder(privateExponent, modulo: BigUnsigned.decremented(prime1))
        let exponent2 = BigUnsigned.remainder(privateExponent, modulo: BigUnsigned.decremented(prime2))
        let integers = [
            Data([0]), modulus, publicExponent, privateExponent,
            prime1, prime2, exponent1, exponent2, coefficient,
        ]
        return DER.element(tag: 0x30, contents: integers.reduce(into: Data()) { $0.append(DER.integer($1)) })
    }
}

/// Just enough DER for a PKCS#1 private key: SEQUENCE and unsigned INTEGER.
private enum DER {
    static func integer(_ magnitude: Data) -> Data {
        var contents = Data(magnitude.drop { $0 == 0 })
        if contents.first.map({ ($0 & 0x80) != 0 }) ?? true {
            contents.insert(0, at: 0)
        }
        return element(tag: 0x02, contents: contents)
    }

    static func element(tag: UInt8, contents: Data) -> Data {
        var encoded = Data([tag])
        if contents.count < 0x80 {
            encoded.append(UInt8(contents.count))
        } else {
            var length = contents.count
            var lengthBytes: [UInt8] = []
            while length > 0 {
                lengthBytes.insert(UInt8(truncatingIfNeeded: length), at: 0)
                length >>= 8
            }
            encoded.append(0x80 | UInt8(lengthBytes.count))
            encoded.append(contentsOf: lengthBytes)
        }
        encoded.append(contents)
        return encoded
    }
}

/// Unsigned big-endian arithmetic for the two RSA CRT exponents.
private enum BigUnsigned {
    /// `value mod modulus` by shift-and-subtract over 32-bit limbs. `modulus`
    /// must be non-zero.
    static func remainder(_ value: Data, modulo modulus: Data) -> Data {
        let divisor = limbs(modulus)
        var remainder = [UInt32](repeating: 0, count: divisor.count + 1)
        for byte in value {
            for bit in (0 ..< 8).reversed() {
                var carry = UInt32((byte >> UInt8(bit)) & 1)
                for index in remainder.indices {
                    let shiftedOut = remainder[index] >> 31
                    remainder[index] = remainder[index] << 1 | carry
                    carry = shiftedOut
                }
                if isGreaterOrEqual(remainder, divisor) {
                    subtract(divisor, from: &remainder)
                }
            }
        }
        var bytes = Data()
        for limb in remainder.reversed() {
            bytes.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: limb >> $0) })
        }
        return Data(bytes.drop { $0 == 0 })
    }

    /// `value − 1`; `value` must be non-zero.
    static func decremented(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        for index in bytes.indices.reversed() {
            if bytes[index] > 0 {
                bytes[index] -= 1
                break
            }
            bytes[index] = 0xFF
        }
        return Data(bytes)
    }

    private static func limbs(_ magnitude: Data) -> [UInt32] {
        var limbs = [UInt32](repeating: 0, count: max(1, (magnitude.count + 3) / 4))
        for (offset, byte) in magnitude.reversed().enumerated() {
            limbs[offset / 4] |= UInt32(byte) << UInt32(8 * (offset % 4))
        }
        return limbs
    }

    private static func isGreaterOrEqual(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
        for index in lhs.indices.reversed() {
            let right = index < rhs.count ? rhs[index] : 0
            if lhs[index] != right {
                return lhs[index] > right
            }
        }
        return true
    }

    private static func subtract(_ rhs: [UInt32], from lhs: inout [UInt32]) {
        var borrow: UInt64 = 0
        for index in lhs.indices {
            let right = UInt64(index < rhs.count ? rhs[index] : 0) + borrow
            let left = UInt64(lhs[index])
            lhs[index] = UInt32(truncatingIfNeeded: left &- right)
            borrow = left < right ? 1 : 0
        }
    }
}

/// Reads the SSH wire encoding (RFC 4251 §5).
struct SSHWireReader {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = Data(bytes)
    }

    var isAtEnd: Bool { offset == bytes.count }

    var remainingBytes: Data { Data(bytes[offset...]) }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw SSHAgentKeyError.malformed }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw SSHAgentKeyError.malformed }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    mutating func readString() throws -> Data {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }

    /// A non-negative mpint as its magnitude, without leading zero bytes.
    mutating func readMPInt() throws -> Data {
        let encoded = try readString()
        if let first = encoded.first, (first & 0x80) != 0 {
            throw SSHAgentKeyError.malformed
        }
        return Data(encoded.drop { $0 == 0 })
    }
}

/// Writes the SSH wire encoding (RFC 4251 §5).
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeByte(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    mutating func writeString(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func writeString(_ value: String) {
        writeString(Data(value.utf8))
    }

    /// A non-negative mpint from an unsigned big-endian magnitude.
    mutating func writeMPInt(_ magnitude: Data) {
        var encoded = Data(magnitude.drop { $0 == 0 })
        if let first = encoded.first, (first & 0x80) != 0 {
            encoded.insert(0, at: 0)
        }
        writeString(encoded)
    }
}
#endif
