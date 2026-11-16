#if os(macOS)
import CryptoKit
import Foundation

/// One owner serializes calls off the main thread and handles persistence, the pairing slot and its deadlines.
final class BrowserBridgeSession {
    enum Event: Equatable {
        case pairingRequested(clientPublicKey: Data, name: String, code: String)
        case paired(clientPublicKey: Data, name: String)
        case pairingCancelled
        case established(clientID: String)
        case request(BrowserBridgeRequest)
    }
    struct Output {
        var frames: [Data] = []
        var events: [Event] = []
        var close = false
    }
    enum State: Equatable { case fresh, committed, awaitingAnswer, paired, established, closed }
    private(set) var state: State = .fresh
    private let appKey: Curve25519.KeyAgreement.PrivateKey
    private let appVersion: String
    private let lookupClient: (String) -> Data?
    private let makeEphemeral: () -> Curve25519.KeyAgreement.PrivateKey
    private let admitPairing: () -> Bool
    private var commitment: Data?
    private var name: String?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var pairedKey: Data?
    private var cipher: BrowserBridgeCipher?
    private var pending: [Int: BrowserBridgeRequest] = [:]

    init(appKey: Curve25519.KeyAgreement.PrivateKey, appVersion: String,
         lookupClient: @escaping (String) -> Data?, admitPairing: @escaping () -> Bool = { true },
         makeEphemeral: @escaping () -> Curve25519.KeyAgreement.PrivateKey = { .init() }) {
        self.appKey = appKey; self.appVersion = appVersion; self.lookupClient = lookupClient
        self.admitPairing = admitPairing; self.makeEphemeral = makeEphemeral
    }

    func receive(_ frame: Data) -> Output {
        guard state != .closed else { return Output(close: true) }
        do {
            let payload = try BrowserBridgeFraming.decode(frame, toward: .towardApp)
            let envelope = try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: payload)
            switch (state, envelope) {
            case (.fresh, .pairCommit(let commit, let name)):
                // Taking the slot here, before any `pair-key`, is what limits code guesses.
                guard admitPairing() else { return fail(.pairingBusy) }
                self.commitment = commit; self.name = BrowserPairingStore.sanitizedName(name)
                let ephemeral = makeEphemeral(); self.ephemeral = ephemeral
                state = .committed
                return try output(.pairKey(pub: appKey.publicKey.rawRepresentation, eph: ephemeral.publicKey.rawRepresentation))
            case (.committed, .pairReveal(let pub, let eph, let nonce)):
                guard let ephemeral, let name,
                      BrowserBridgeCrypto.commitment(client: pub, ephemeral: eph, nonce: nonce) == commitment else { return fail(.badHandshake) }
                // Reject low-order points before asking the user to trust an unusable key.
                _ = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub))
                _ = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: eph))
                pairedKey = pub
                state = .awaitingAnswer
                let code = BrowserBridgeCrypto.pairingCode(client: pub, app: appKey.publicKey.rawRepresentation,
                                                         clientEphemeral: eph, appEphemeral: ephemeral.publicKey.rawRepresentation)
                return Output(events: [.pairingRequested(clientPublicKey: pub, name: name, code: code)])
            case (.fresh, .clientHello(let client, let eph)), (.paired, .clientHello(let client, let eph)):
                let key = pairedKey.flatMap { BrowserBridgeCrypto.clientID($0) == client ? $0 : nil } ?? lookupClient(client)
                guard let key, BrowserBridgeCrypto.clientID(key) == client else { return fail(.unpaired) }
                let ephemeral = makeEphemeral()
                let keys = try BrowserBridgeCrypto.serverKeys(app: appKey, ephemeral: ephemeral, client: key, clientEphemeral: eph)
                cipher = BrowserBridgeCipher(sending: keys.s2c, receiving: keys.c2s)
                clearPairing()
                state = .established
                var result = try output(.serverHello(eph: ephemeral.publicKey.rawRepresentation, app: appVersion))
                result.events = [.established(clientID: client)]
                return result
            case (.established, .message):
                guard var cipher else { return fail(.badHandshake) }
                let plaintext = try cipher.open(envelope)
                self.cipher = cipher
                let request = try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: plaintext)
                guard pending[request.id] == nil else { return fail(.badRequest) }
                pending[request.id] = request
                return Output(events: [.request(request)])
            default: return fail(.badRequest)
            }
        } catch let error as BrowserBridgeDecodingError { return fail(error.protocolCode) }
        catch { return fail(.badHandshake) }
    }

    func pairingAnswered(_ accepted: Bool) -> Output {
        guard state == .awaitingAnswer, let pairedKey, let name else { return fail(.badRequest) }
        guard accepted else { return fail(.pairingDeclined) }
        do {
            state = .paired
            commitment = nil; ephemeral = nil
            var result = try output(.pairResult(ok: true))
            result.events = [.paired(clientPublicKey: pairedKey, name: name)]
            return result
        } catch { return fail(.badRequest) }
    }

    func pairingTimedOut() -> Output {
        guard state == .awaitingAnswer else { return Output() }
        return fail(.pairingDeclined)
    }

    func reply(_ result: BrowserBridgeReply.Result, to request: BrowserBridgeRequest) -> Output {
        guard state == .established, pending[request.id] == request, var cipher else { return fail(.badRequest) }
        do {
            let envelope = try cipher.seal(BrowserBridgeJSON.encode(BrowserBridgeReply(id: request.id, result: result)))
            let result = try output(envelope)
            self.cipher = cipher
            pending.removeValue(forKey: request.id)
            return result
        } catch { return fail(.badRequest) }
    }

    func close() -> Output {
        let events: [Event] = state == .awaitingAnswer ? [.pairingCancelled] : []
        state = .closed; cipher = nil; pending.removeAll(); clearPairing()
        return Output(events: events, close: true)
    }

    /// Ends the session with `code`, such as `disabled` when the bridge is switched off.
    func refuse(_ code: BrowserBridgeErrorCode) -> Output { fail(code) }

    private func clearPairing() { commitment = nil; name = nil; ephemeral = nil; pairedKey = nil }
    private func output(_ envelope: BrowserBridgeEnvelope) throws -> Output {
        Output(frames: [try BrowserBridgeFraming.encode(BrowserBridgeJSON.encode(envelope), toward: .towardExtension)])
    }
    private func fail(_ code: BrowserBridgeErrorCode) -> Output {
        guard state != .closed else { return Output(close: true) }
        let frames = (try? output(.error(code)).frames) ?? []
        var result = close(); result.frames = frames
        return result
    }
}
#endif
