#if os(macOS)
import CryptoKit
import Foundation

enum BrowserBridgeCrypto {
    struct Keys {
        let c2s: SymmetricKey
        let s2c: SymmetricKey
    }

    static func clientID(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func commitment(client: Data, ephemeral: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: client + ephemeral + nonce))
    }

    static func pairingCode(client: Data, app: Data, clientEphemeral: Data, appEphemeral: Data) -> String {
        let digest = SHA256.hash(data: Data("KeeForge browser pairing v1".utf8) + client + app + clientEphemeral + appEphemeral)
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", number % 1_000_000)
    }

    static func serverKeys(app: Curve25519.KeyAgreement.PrivateKey, ephemeral: Curve25519.KeyAgreement.PrivateKey,
                           client: Data, clientEphemeral: Data) throws -> Keys {
        let c = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: client)
        let ec = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphemeral)
        let ee = try ephemeral.sharedSecretFromKeyAgreement(with: ec)
        let ce = try ephemeral.sharedSecretFromKeyAgreement(with: c)
        let es = try app.sharedSecretFromKeyAgreement(with: ec)
        let ikm = ee.withUnsafeBytes { Data($0) } + ce.withUnsafeBytes { Data($0) } + es.withUnsafeBytes { Data($0) }
        return derive(ikm: ikm, client: client, app: app.publicKey.rawRepresentation,
                      clientEphemeral: clientEphemeral, appEphemeral: ephemeral.publicKey.rawRepresentation)
    }

    static func derive(ikm: Data, client: Data, app: Data, clientEphemeral: Data, appEphemeral: Data) -> Keys {
        let salt = Data(SHA256.hash(data: Data("KeeForge browser bridge v1".utf8) + clientEphemeral + appEphemeral + client + app))
        func key(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        return Keys(c2s: key("c2s"), s2c: key("s2c"))
    }

    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: counter >> ($0 * 8)) }))
    }
}

struct BrowserBridgeCipher {
    private let sending: SymmetricKey
    private let receiving: SymmetricKey
    private(set) var nextSend: UInt64? = 0
    private(set) var nextReceive: UInt64? = 0

    init(sending: SymmetricKey, receiving: SymmetricKey) { self.sending = sending; self.receiving = receiving }

    mutating func seal(_ plaintext: Data) throws -> BrowserBridgeEnvelope {
        guard let counter = nextSend else { throw BrowserBridgeErrorCode.badHandshake }
        let sealed = try AES.GCM.seal(plaintext, using: sending, nonce: BrowserBridgeCrypto.nonce(counter), authenticating: Data("msg".utf8))
        nextSend = counter == .max ? nil : counter + 1
        return .message(n: counter, c: sealed.ciphertext + sealed.tag)
    }

    mutating func open(_ envelope: BrowserBridgeEnvelope) throws -> Data {
        guard case .message(let counter, let ciphertext) = envelope, counter == nextReceive, ciphertext.count >= 16 else {
            throw BrowserBridgeErrorCode.badHandshake
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: BrowserBridgeCrypto.nonce(counter), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            let plaintext = try AES.GCM.open(box, using: receiving, authenticating: Data("msg".utf8))
            nextReceive = counter == .max ? nil : counter + 1
            return plaintext
        } catch { throw BrowserBridgeErrorCode.badHandshake }
    }
}
#endif
