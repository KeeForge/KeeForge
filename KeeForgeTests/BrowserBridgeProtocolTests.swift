#if os(macOS)
// Regenerate vectors on the Studio:
// studio-test run mac --test-env BROWSER_BRIDGE_REGENERATE_VECTORS=1 --bundles always KeeForgeMacTests/BrowserBridgeProtocolTests/testVectors
// Fetch with `studio-test fetch <run-id> --bundles`. Export that run's xcresult with `xcrun xcresulttool export attachments --path <xcresult> --output-path <main-checkout>/scratch/299/vectors`.
// Copy the attachment named vectors.json (see manifest.json) to BrowserExtension/test/vectors.json, then rerun normally.
import CryptoKit
import XCTest
@testable import KeeForge

final class BrowserBridgeProtocolTests: XCTestCase {
    private func key(_ byte: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey {
        try .init(rawRepresentation: Data(repeating: byte, count: 32))
    }
    private func client() throws -> BrowserBridgeTestClient {
        try BrowserBridgeTestClient(key: key(1), ephemeral: key(3), nonce: Data(repeating: 5, count: 32))
    }
    private func server(known: Data? = nil, busy: Bool = false, admissions: (() -> Void)? = nil) throws -> BrowserBridgeSession {
        let es = try key(4)
        return BrowserBridgeSession(appKey: try key(2), appVersion: "1.0", lookupClient: { _ in known },
                                    admitPairing: { admissions?(); return !busy }, makeEphemeral: { es })
    }
    private func frame(_ envelope: BrowserBridgeEnvelope) throws -> Data {
        try BrowserBridgeFraming.encode(BrowserBridgeJSON.encode(envelope), toward: .towardApp)
    }
    private func envelope(_ output: BrowserBridgeSession.Output) throws -> BrowserBridgeEnvelope {
        XCTAssertEqual(output.frames.count, 1)
        return try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: BrowserBridgeFraming.decode(XCTUnwrap(output.frames.first), toward: .towardExtension))
    }
    private func assertError(_ output: BrowserBridgeSession.Output, _ code: BrowserBridgeErrorCode, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(output.close, file: file, line: line)
        XCTAssertEqual(try envelope(output), .error(code), file: file, line: line)
    }
    private func established() throws -> (BrowserBridgeSession, BrowserBridgeTestClient) {
        var client = try client()
        let server = try server(known: client.pub)
        try client.establish(envelope(server.receive(frame(client.hello))), app: key(2).publicKey.rawRepresentation)
        return (server, client)
    }

    func testEstablishedEventIdentifiesClient() throws {
        let client = try client()
        let server = try server(known: client.pub)
        let result = server.receive(try frame(client.hello))
        XCTAssertEqual(result.events, [.established(clientID: client.id)])
    }

    func testFramingRoundTripAndCaps() throws {
        for direction in [BrowserBridgeFraming.Direction.towardApp, .towardExtension] {
            for size in [0, 1, direction.limit] {
                let data = Data(repeating: 7, count: size)
                let framed = try BrowserBridgeFraming.encode(data, toward: direction)
                XCTAssertEqual(try BrowserBridgeFraming.decode(framed, toward: direction), data)
                XCTAssertEqual(Array(framed.prefix(4)), (0..<4).map { UInt8(truncatingIfNeeded: UInt32(size) >> ($0 * 8)) })
            }
            XCTAssertThrowsError(try BrowserBridgeFraming.encode(Data(repeating: 0, count: direction.limit + 1), toward: direction))
            let count = UInt32(direction.limit + 1)
            let header = Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
            XCTAssertThrowsError(try BrowserBridgeFraming.decode(header, toward: direction)) { XCTAssertEqual($0 as? BrowserBridgeDecodingError, .oversizedFrame) }
        }
        for bytes in [Data(), Data([1, 0, 0, 0]), Data([0, 0, 0, 0, 1])] {
            XCTAssertThrowsError(try BrowserBridgeFraming.decode(bytes, toward: .towardApp))
        }
        let server = try server()
        try assertError(server.receive(Data([1, 0, 1, 0])), .badRequest)
    }

    func testStrictDecodingFailuresAndErrorMapping() throws {
        let cases: [(String, BrowserBridgeDecodingError)] = [
            ("{\"v\":2,\"t\":\"future\"}", .unsupportedVersion),
            ("{\"t\":\"host\"}", .missingField("v")),
            ("{\"v\":\"1\",\"t\":\"host\"}", .wrongType("v")),
            ("{\"v\":true,\"t\":\"host\"}", .wrongType("v")),
            ("{\"v\":1}", .missingField("t")),
            ("{\"v\":1,\"t\":9}", .wrongType("t")),
            ("{\"v\":1,\"t\":\"other\"}", .unknownType("other")),
            ("{\"v\":1,\"t\":\"pair-result\"}", .missingField("ok")),
            ("{\"v\":1,\"t\":\"pair-result\",\"ok\":1}", .wrongType("ok")),
            ("{\"v\":1,\"t\":\"msg\",\"n\":-1,\"c\":\"\"}", .wrongType("n")),
            ("{\"v\":1,\"t\":\"msg\",\"n\":0.5,\"c\":\"\"}", .wrongType("n")),
            ("{\"v\":1,\"t\":\"msg\",\"n\":0,\"c\":\"!\"}", .invalidField("c")),
            ("{\"v\":1,\"t\":\"pair-key\",\"pub\":\"AA==\",\"eph\":\"AA==\"}", .invalidField("pub")),
            ("{\"v\":1,\"t\":\"hello\",\"client\":\"bad\",\"eph\":\"\"}", .invalidField("client")),
            ("{\"v\":1,\"t\":\"error\",\"code\":\"other\"}", .invalidField("code")),
            ("[]", .invalidJSON), ("no", .invalidJSON)
        ]
        for (json, expected) in cases {
            let data = Data(json.utf8)
            XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: data)) { XCTAssertEqual($0 as? BrowserBridgeDecodingError, expected) }
            try assertError(try server().receive(BrowserBridgeFraming.encode(data, toward: .towardApp)), expected.protocolCode)
        }
        XCTAssertEqual(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: Data("{\"v\":1,\"t\":\"host\",\"extra\":42}".utf8)), .host)
        let tooLong = BrowserBridgeEnvelope.pairCommit(commit: Data(repeating: 0, count: 32), name: String(repeating: "x", count: 65))
        try assertError(try server().receive(frame(tooLong)), .badRequest)
    }

    func testAllEnvelopeFieldsAreRequiredAndTyped() throws {
        let c = try client(), pub = c.pub
        let envelopes: [BrowserBridgeEnvelope] = [c.commit, .pairKey(pub: pub, eph: pub), c.reveal, .pairResult(ok: true), c.hello,
            .serverHello(eph: pub, app: "1"), .message(n: 0, c: Data()), .error(.disabled)]
        for value in envelopes {
            let data = try BrowserBridgeJSON.encode(value)
            XCTAssertEqual(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: data), value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for field in object.keys {
                var missing = object; missing.removeValue(forKey: field)
                XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: missing)))
                var wrong = object; wrong[field] = ["wrong"]
                XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: wrong)))
            }
            var extra = object; extra["future"] = ["arbitrary": true]
            XCTAssertEqual(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: extra)), value)
        }
    }

    func testInnerMessagesRoundTripAndStrictFields() throws {
        let uuid = UUID()
        let requests: [BrowserBridgeRequest] = [.init(id: 0, operation: .status), .init(id: 1, operation: .matches(origin: "https://example.com")),
            .init(id: 2, operation: .credential(entry: uuid, db: uuid, origin: "https://example.com", totp: true)),
            .init(id: 3, operation: .reveal(entry: uuid, db: uuid)), .init(id: 4, operation: .unlock(db: uuid)), .init(id: 5, operation: .unlock(db: nil))]
        for request in requests {
            let data = try BrowserBridgeJSON.encode(request)
            XCTAssertEqual(try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: data), request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for field in object.keys {
                var wrong = object; wrong[field] = [false]
                XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: JSONSerialization.data(withJSONObject: wrong)))
                if field != "totp", !(field == "db" && { if case .unlock = request.operation { return true }; return false }()) {
                    var missing = object; missing.removeValue(forKey: field)
                    XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: JSONSerialization.data(withJSONObject: missing)))
                }
            }
        }
        XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: Data("{\"id\":1,\"type\":\"future\"}".utf8)))
        let results: [BrowserBridgeReply.Result] = [.status(app: "1", unlocked: 2, locked: 3), .matches(entries: [.init(entry: uuid, db: uuid, dbName: "Test", title: "Title", username: "user", hasTotp: true, exact: true)], locked: 1), .credential(username: "user", password: "test"), .credential(username: "", password: ""), .totp("123456"), .empty] + BrowserBridgeRequestError.allCases.map { .failure($0) }
        for result in results {
            let reply = BrowserBridgeReply(id: 7, result: result)
            let operation: BrowserBridgeRequest.Operation
            switch result {
            case .status, .failure: operation = .status
            case .matches: operation = .matches(origin: "https://example.com")
            case .credential: operation = .credential(entry: uuid, db: uuid, origin: "https://example.com", totp: nil)
            case .totp: operation = .credential(entry: uuid, db: uuid, origin: "https://example.com", totp: true)
            case .empty: operation = .unlock(db: nil)
            }
            let encoded = try BrowserBridgeJSON.encode(reply)
            XCTAssertEqual(try BrowserBridgeJSON.decodeReply(from: encoded, for: operation), reply)
            var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            extra["future"] = [false]
            XCTAssertEqual(try BrowserBridgeJSON.decodeReply(from: JSONSerialization.data(withJSONObject: extra), for: operation), reply)
            for field in extra.keys where field != "future" {
                var missing = extra; missing.removeValue(forKey: field)
                XCTAssertThrowsError(try BrowserBridgeJSON.decodeReply(from: JSONSerialization.data(withJSONObject: missing), for: operation))
                var wrong = extra; wrong[field] = [false]
                XCTAssertThrowsError(try BrowserBridgeJSON.decodeReply(from: JSONSerialization.data(withJSONObject: wrong), for: operation))
            }
        }
        let codeOnly = try XCTUnwrap(JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(BrowserBridgeReply(id: 7, result: .totp("123456")))) as? [String: Any])
        XCTAssertEqual(Set(codeOnly.keys), ["id", "ok", "totp"])
        let fill = try XCTUnwrap(JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(BrowserBridgeReply(id: 7, result: .credential(username: "user", password: "test")))) as? [String: Any])
        XCTAssertEqual(Set(fill.keys), ["id", "ok", "username", "password"])
        for code in BrowserBridgeErrorCode.allCases {
            XCTAssertEqual(try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: BrowserBridgeJSON.encode(BrowserBridgeEnvelope.error(code))), .error(code))
        }
    }

    func testMatchesRequireExactBoolean() throws {
        let uuid = UUID()
        let row = BrowserBridgeMatch(entry: uuid, db: uuid, dbName: "Test", title: "Title", username: "user", hasTotp: false, exact: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(row)) as? [String: Any])
        json.removeValue(forKey: "exact")
        XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeMatch.self, from: JSONSerialization.data(withJSONObject: json)))
        json["exact"] = "true"
        XCTAssertThrowsError(try BrowserBridgeJSON.decode(BrowserBridgeMatch.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testPairingHappyPathThenSessionOnSameConnection() throws {
        var client = try client()
        let server = try server()
        guard case .pairKey(let app, let es) = try envelope(server.receive(frame(client.commit))) else { return XCTFail() }
        XCTAssertEqual(server.state, .committed)
        let reveal = try server.receive(frame(client.reveal))
        XCTAssertEqual(reveal.events, [.pairingRequested(clientPublicKey: client.pub, name: "Test Browser", code: client.code(app: app, appEphemeral: es))])
        XCTAssertEqual(server.state, .awaitingAnswer)
        let answer = server.pairingAnswered(true)
        XCTAssertEqual(try envelope(answer), .pairResult(ok: true))
        XCTAssertEqual(answer.events, [.paired(clientPublicKey: client.pub, name: "Test Browser")])
        try client.establish(envelope(server.receive(frame(client.hello))), app: app)
        let request = BrowserBridgeRequest(id: 42, operation: .status)
        XCTAssertEqual(try server.receive(frame(client.send(request))).events, [.request(request)])
        XCTAssertEqual(try client.receive(envelope(server.reply(.status(app: "1.0", unlocked: 1, locked: 2), to: request))), .init(id: 42, result: .status(app: "1.0", unlocked: 1, locked: 2)))
    }

    func testPairingMismatchDeclineBusyTimeoutAndCancellation() throws {
        let client = try client()
        let mismatch = try server()
        _ = try mismatch.receive(frame(client.commit))
        try assertError(mismatch.receive(frame(.pairReveal(pub: client.pub, eph: client.eph, nonce: Data(repeating: 8, count: 32)))), .badHandshake)
        let declined = try server()
        _ = try declined.receive(frame(client.commit)); _ = try declined.receive(frame(client.reveal))
        let answer = declined.pairingAnswered(false)
        try assertError(answer, .pairingDeclined)
        XCTAssertEqual(answer.events, [.pairingCancelled])
        try assertError(try server(busy: true).receive(frame(client.commit)), .pairingBusy)
        let timeout = try server()
        _ = try timeout.receive(frame(client.commit)); _ = try timeout.receive(frame(client.reveal))
        try assertError(timeout.pairingTimedOut(), .pairingDeclined)
        let cancelled = try server()
        _ = try cancelled.receive(frame(client.commit)); _ = try cancelled.receive(frame(client.reveal))
        XCTAssertEqual(cancelled.close().events, [.pairingCancelled])
        XCTAssertTrue(cancelled.pairingAnswered(true).close)
        XCTAssertTrue(cancelled.pairingAnswered(true).frames.isEmpty)
    }

    func testUnknownClientSecondHelloHostAndInvalidStateClose() throws {
        try assertError(try server().receive(frame(client().hello)), .unpaired)
        let (server, client) = try established()
        try assertError(server.receive(frame(client.hello)), .badRequest)
        XCTAssertTrue(try server.receive(frame(client.hello)).frames.isEmpty)
        try assertError(try self.server().receive(frame(.host)), .badRequest)
        try assertError(try self.server().receive(frame(client.reveal)), .badRequest)
        let (disabled, _) = try established()
        try assertError(disabled.refuse(.disabled), .disabled)
    }

    func testSlotIsTakenAtCommitAndBusyIssuesNoPairKey() throws {
        let client = try client()
        var admissions = 0
        let session = try server(admissions: { admissions += 1 })
        _ = try session.receive(frame(client.commit))
        XCTAssertEqual(admissions, 1, "Admission happens at commit, before the pair-key")
        _ = try session.receive(frame(client.reveal))
        XCTAssertEqual(admissions, 1, "Reveal asks for nothing more")
        let busy = try server(busy: true).receive(frame(client.commit))
        try assertError(busy, .pairingBusy)
        XCTAssertTrue(busy.events.isEmpty)
    }

    func testPairingNameIsSanitizedInEvents() throws {
        let client = try client()
        guard case .pairCommit(let commit, _) = client.commit else { return XCTFail() }
        let session = try server()
        _ = try session.receive(frame(.pairCommit(commit: commit, name: "Chrome\nCode matches \u{202E}wolla\u{202C}")))
        guard case .pairingRequested(_, let name, _) = try XCTUnwrap(session.receive(frame(client.reveal)).events.first) else { return XCTFail() }
        XCTAssertEqual(name, "Chrome Code matches wolla")
        XCTAssertEqual(session.pairingAnswered(true).events, [.paired(clientPublicKey: client.pub, name: "Chrome Code matches wolla")])
    }

    func testHelloRefusedAfterLookupSendsUnpaired() throws {
        let client = try client()
        let session = try server(known: client.pub)
        XCTAssertEqual(try session.receive(frame(client.hello)).events, [.established(clientID: client.id)])
        try assertError(session.refuse(.unpaired), .unpaired)
    }

    func testReplyAtPlaintextCapFitsAndLittleMoreCloses() throws {
        for (extra, fits) in [(0, true), (48, false)] {
            var (server, client) = try established()
            let request = BrowserBridgeRequest(id: 1, operation: .status)
            _ = try server.receive(frame(client.send(request)))
            let base = try BrowserBridgeJSON.encode(BrowserBridgeReply(id: 1, result: .credential(username: "", password: ""))).count
            let password = String(repeating: "x", count: BrowserBridgeFraming.maximumReplyPlaintext - base + extra)
            let output = server.reply(.credential(username: "", password: password), to: request)
            XCTAssertEqual(output.close, !fits)
            if fits, case .message = try envelope(output) {} else if fits { XCTFail("Expected a sealed reply") }
        }
    }

    func testEstablishedRoundTripAndExactlyOneReply() throws {
        var (server, client) = try established()
        for id in 0..<2 {
            let request = BrowserBridgeRequest(id: id, operation: .unlock(db: nil))
            XCTAssertEqual(try server.receive(frame(client.send(request))).events, [.request(request)])
            XCTAssertEqual(try client.receive(envelope(server.reply(.empty, to: request))), .init(id: id, result: .empty))
        }
        try assertError(server.reply(.empty, to: .init(id: 1, operation: .status)), .badRequest)
    }

    func testOversizedReplyAndEstablishedHostClose() throws {
        var (server, client) = try established()
        let request = BrowserBridgeRequest(id: 1, operation: .status)
        _ = try server.receive(frame(client.send(request)))
        try assertError(server.reply(.credential(username: "", password: String(repeating: "x", count: BrowserBridgeFraming.maximumExtensionPayload)), to: request), .badRequest)
        let (host, _) = try established()
        try assertError(host.receive(frame(.host)), .badRequest)
    }

    func testWrongStaticKeysFailFirstMessage() throws {
        for wrongApp in [false, true] {
            var client = try client()
            let registered = try key(6).publicKey.rawRepresentation
            let server = try server(known: wrongApp ? client.pub : registered)
            let hello = BrowserBridgeEnvelope.clientHello(client: BrowserBridgeCrypto.clientID(wrongApp ? client.pub : registered), eph: client.eph)
            let response = try envelope(server.receive(frame(hello)))
            try client.establish(response, app: key(wrongApp ? 7 : 2).publicKey.rawRepresentation)
            try assertError(server.receive(frame(client.send(.init(id: 1, operation: .status)))), .badHandshake)
        }
    }

    func testReplaySkippedReorderedAndTamperedMessagesFail() throws {
        for mode in 0..<5 {
            var (server, client) = try established()
            let first = try client.send(.init(id: 1, operation: .status))
            let second = try client.send(.init(id: 2, operation: .status))
            var bad = first
            switch mode {
            case 0: _ = try server.receive(frame(first))
            case 1: bad = second
            case 2:
                _ = try client.send(.init(id: 3, operation: .status))
                bad = second
            case 3:
                guard case .message(let n, var c) = first else { return XCTFail() }
                c[c.startIndex] ^= 1; bad = .message(n: n, c: c)
            default: bad = .message(n: 0, c: Data(repeating: 0, count: 15))
            }
            try assertError(server.receive(frame(bad)), .badHandshake)
        }
        var (_, client) = try established()
        let keys = try client.keys(app: key(2).publicKey.rawRepresentation, appEphemeral: key(4).publicKey.rawRepresentation)
        var sender = BrowserBridgeCipher(sending: keys.s2c, receiving: keys.c2s)
        let first = try sender.seal(Data("{}".utf8)), second = try sender.seal(Data("{}".utf8))
        XCTAssertThrowsError(try client.cipher!.open(second))
        XCTAssertEqual(try client.cipher!.open(first), Data("{}".utf8))
        XCTAssertThrowsError(try client.cipher!.open(first))
    }

    func testMalformedInnerRequestAndDuplicateIDClose() throws {
        for duplicate in [false, true] {
            var (server, client) = try established()
            if duplicate {
                let request = BrowserBridgeRequest(id: 1, operation: .status)
                _ = try server.receive(frame(client.send(request)))
                try assertError(server.receive(frame(client.send(request))), .badRequest)
            } else {
                try assertError(server.receive(frame(client.cipher!.seal(Data("{\"id\":1,\"type\":\"credential\"}".utf8)))), .badRequest)
            }
        }
    }

    private struct VectorMessage: Codable {
        let plaintext: String
        let envelope: BrowserBridgeEnvelope
        let frameBase64: String
    }
    private struct Vectors: Codable {
        let version: Int
        let inputs: [String: String]
        let clientID: String
        let commitment: String
        let pairingCode: String
        let k_c2s: String
        let k_s2c: String
        let c2s: [VectorMessage]
        let s2c: [VectorMessage]
    }
    func testVectors() throws {
        var (server, client) = try established()
        let app = try key(2), es = try key(4)
        let keys = try client.keys(app: app.publicKey.rawRepresentation, appEphemeral: es.publicKey.rawRepresentation)
        var c2s: [VectorMessage] = [], s2c: [VectorMessage] = []
        for id in 0..<2 {
            let request = BrowserBridgeRequest(id: id, operation: id == 0 ? .status : .matches(origin: "https://example.com"))
            let plaintext = try BrowserBridgeJSON.encode(request)
            let message = try client.send(request)
            let wire = try frame(message)
            c2s.append(VectorMessage(plaintext: String(decoding: plaintext, as: UTF8.self), envelope: message, frameBase64: wire.base64EncodedString()))
            XCTAssertEqual(server.receive(wire).events, [.request(request)])
            let result: BrowserBridgeReply.Result = id == 0 ? .status(app: "1.0", unlocked: 1, locked: 0) : .matches(entries: [], locked: 0)
            let reply = BrowserBridgeReply(id: id, result: result)
            let output = server.reply(result, to: request)
            let response = try envelope(output)
            XCTAssertEqual(try client.receive(response), reply)
            s2c.append(VectorMessage(plaintext: String(decoding: try BrowserBridgeJSON.encode(reply), as: UTF8.self), envelope: response, frameBase64: try XCTUnwrap(output.frames.first).base64EncodedString()))
        }
        let vectors = Vectors(version: 1, inputs: ["C_private": client.key.rawRepresentation.base64EncodedString(), "S_private": app.rawRepresentation.base64EncodedString(), "ec_private": client.ephemeral.rawRepresentation.base64EncodedString(), "es_private": es.rawRepresentation.base64EncodedString(), "C_pub": client.pub.base64EncodedString(), "S_pub": app.publicKey.rawRepresentation.base64EncodedString(), "ec_pub": client.eph.base64EncodedString(), "es_pub": es.publicKey.rawRepresentation.base64EncodedString(), "nonce": client.nonce.base64EncodedString()], clientID: client.id,
            commitment: BrowserBridgeCrypto.commitment(client: client.pub, ephemeral: client.eph, nonce: client.nonce).base64EncodedString(),
            pairingCode: client.code(app: app.publicKey.rawRepresentation, appEphemeral: es.publicKey.rawRepresentation),
            k_c2s: keys.c2s.withUnsafeBytes { Data($0).base64EncodedString() }, k_s2c: keys.s2c.withUnsafeBytes { Data($0).base64EncodedString() }, c2s: c2s, s2c: s2c)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let generated = try encoder.encode(vectors) + Data([10])
        if ProcessInfo.processInfo.environment["BROWSER_BRIDGE_REGENERATE_VECTORS"] == "1" {
            let attachment = XCTAttachment(data: generated, uniformTypeIdentifier: "public.json")
            attachment.name = "vectors.json"; attachment.lifetime = .keepAlways; add(attachment)
        } else {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vectors", withExtension: "json"))
            XCTAssertEqual(try Data(contentsOf: url), generated, "Regenerate vectors using the commands in this file's header.")
        }
    }
}
#endif
