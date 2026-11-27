#if os(macOS)
import CryptoKit
import Foundation
@testable import KeeForge

struct BrowserBridgeTestClient {
    let key: Curve25519.KeyAgreement.PrivateKey
    let ephemeral: Curve25519.KeyAgreement.PrivateKey
    let nonce: Data
    var cipher: BrowserBridgeCipher?
    var pending: [Int: BrowserBridgeRequest.Operation] = [:]

    var pub: Data { key.publicKey.rawRepresentation }
    var eph: Data { ephemeral.publicKey.rawRepresentation }
    var id: String { BrowserBridgeCrypto.clientID(pub) }
    var commit: BrowserBridgeEnvelope { .pairCommit(commit: Data(SHA256.hash(data: pub + eph + nonce)), name: "Test Browser") }
    var reveal: BrowserBridgeEnvelope { .pairReveal(pub: pub, eph: eph, nonce: nonce) }
    var hello: BrowserBridgeEnvelope { .clientHello(client: id, eph: eph) }

    func code(app: Data, appEphemeral: Data) -> String {
        let bytes = Array(SHA256.hash(data: Data("KeeForge browser pairing v1".utf8) + pub + app + eph + appEphemeral))
        let number = UInt32(bytes[0]) * 16_777_216 + UInt32(bytes[1]) * 65_536 + UInt32(bytes[2]) * 256 + UInt32(bytes[3])
        return String(format: "%06u", number % 1_000_000)
    }

    func keys(app: Data, appEphemeral: Data) throws -> BrowserBridgeCrypto.Keys {
        let s = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: app)
        let es = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: appEphemeral)
        let ee = try ephemeral.sharedSecretFromKeyAgreement(with: es)
        let ce = try key.sharedSecretFromKeyAgreement(with: es)
        let cs = try ephemeral.sharedSecretFromKeyAgreement(with: s)
        let ikm = ee.withUnsafeBytes { Data($0) } + ce.withUnsafeBytes { Data($0) } + cs.withUnsafeBytes { Data($0) }
        let salt = SHA256.hash(data: Data("KeeForge browser bridge v1".utf8) + eph + appEphemeral + pub + app)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(salt), info: Data(info.utf8), outputByteCount: 32)
        }
        return BrowserBridgeCrypto.Keys(c2s: derive("c2s"), s2c: derive("s2c"))
    }

    mutating func establish(_ hello: BrowserBridgeEnvelope, app: Data) throws {
        guard case .serverHello(let es, _, _) = hello else { throw BrowserBridgeErrorCode.badRequest }
        let keys = try keys(app: app, appEphemeral: es)
        cipher = BrowserBridgeCipher(sending: keys.c2s, receiving: keys.s2c)
    }

    mutating func send(_ request: BrowserBridgeRequest) throws -> BrowserBridgeEnvelope {
        let message = try cipher!.seal(BrowserBridgeJSON.encode(request))
        pending[request.id] = request.operation
        return message
    }
    mutating func receive(_ reply: BrowserBridgeEnvelope) throws -> BrowserBridgeReply {
        struct Identifier: Decodable { let id: Int }
        let plaintext = try cipher!.open(reply)
        let id = try BrowserBridgeJSON.decode(Identifier.self, from: plaintext).id
        guard let operation = pending[id] else { throw BrowserBridgeErrorCode.badRequest }
        let decoded = try BrowserBridgeJSON.decodeReply(from: plaintext, for: operation)
        pending.removeValue(forKey: id)
        return decoded
    }
}

#endif
