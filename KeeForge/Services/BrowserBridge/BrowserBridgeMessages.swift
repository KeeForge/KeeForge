#if os(macOS)
import Foundation

enum BrowserBridgeErrorCode: String, Codable, CaseIterable, Sendable, Error {
    case unsupportedVersion = "unsupported-version", badRequest = "bad-request"
    case unpaired, badHandshake = "bad-handshake", pairingDeclined = "pairing-declined"
    case pairingBusy = "pairing-busy", disabled
}

enum BrowserBridgeRequestError: String, Codable, CaseIterable, Sendable {
    case badRequest = "bad-request", badOrigin = "bad-origin", locked
    case notOffered = "not-offered", noMatch = "no-match", denied, unavailable
    case rateLimited = "rate-limited"
}

enum BrowserBridgeDecodingError: Error, Equatable {
    case unsupportedVersion, unknownType(String), missingField(String), wrongType(String), invalidField(String)
    case invalidJSON, invalidFrame, oversizedFrame

    var protocolCode: BrowserBridgeErrorCode {
        self == .unsupportedVersion ? .unsupportedVersion : .badRequest
    }
}

struct BrowserBridgeField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == BrowserBridgeField {
    func field<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        guard contains(Key(name)) else { throw BrowserBridgeDecodingError.missingField(name) }
        do { return try decode(type, forKey: Key(name)) }
        catch let error as BrowserBridgeDecodingError { throw error }
        catch { throw BrowserBridgeDecodingError.wrongType(name) }
    }

    func optional<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T? {
        contains(Key(name)) ? try field(name, as: type) : nil
    }

    func binary(_ name: String, length: Int? = nil) throws -> Data {
        let encoded: String = try field(name)
        guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
              length == nil || bytes.count == length else { throw BrowserBridgeDecodingError.invalidField(name) }
        return bytes
    }
}

extension KeyedEncodingContainer where Key == BrowserBridgeField {
    mutating func field<T: Encodable>(_ name: String, _ value: T) throws { try encode(value, forKey: Key(name)) }
}

enum BrowserBridgeJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decodeReply(from data: Data, for operation: BrowserBridgeRequest.Operation) throws -> BrowserBridgeReply {
        let decoder = JSONDecoder()
        guard let key = CodingUserInfoKey(rawValue: "browserBridgeReplyOperation") else { throw BrowserBridgeDecodingError.invalidJSON }
        decoder.userInfo[key] = operation
        do { return try decoder.decode(BrowserBridgeReply.self, from: data) }
        catch let error as BrowserBridgeDecodingError { throw error }
        catch { throw BrowserBridgeDecodingError.invalidJSON }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as BrowserBridgeDecodingError { throw error }
        catch { throw BrowserBridgeDecodingError.invalidJSON }
    }
}

enum BrowserBridgeEnvelope: Codable, Equatable {
    case pairCommit(commit: Data, name: String)
    case pairKey(pub: Data, eph: Data)
    case pairReveal(pub: Data, eph: Data, nonce: Data)
    case pairResult(ok: Bool)
    case clientHello(client: String, eph: Data)
    case serverHello(eph: Data, app: String)
    case message(n: UInt64, c: Data)
    case error(BrowserBridgeErrorCode)
    case host

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserBridgeField.self)
        let version: Int = try c.field("v")
        guard version == 1 else { throw BrowserBridgeDecodingError.unsupportedVersion }
        let type: String = try c.field("t")
        switch type {
        case "pair-commit":
            let name: String = try c.field("name")
            guard name.count <= 64 else { throw BrowserBridgeDecodingError.invalidField("name") }
            self = .pairCommit(commit: try c.binary("commit", length: 32), name: name)
        case "pair-key": self = .pairKey(pub: try c.binary("pub", length: 32), eph: try c.binary("eph", length: 32))
        case "pair-reveal": self = .pairReveal(pub: try c.binary("pub", length: 32), eph: try c.binary("eph", length: 32), nonce: try c.binary("nonce", length: 32))
        case "pair-result": self = .pairResult(ok: try c.field("ok"))
        case "hello":
            if c.contains(BrowserBridgeField("client")) {
                let client: String = try c.field("client")
                guard client.count == 32, client.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw BrowserBridgeDecodingError.invalidField("client")
                }
                self = .clientHello(client: client, eph: try c.binary("eph", length: 32))
            } else if c.contains(BrowserBridgeField("app")) {
                self = .serverHello(eph: try c.binary("eph", length: 32), app: try c.field("app"))
            } else { throw BrowserBridgeDecodingError.missingField("client") }
        case "msg": self = .message(n: try c.field("n"), c: try c.binary("c"))
        case "error":
            let code: String = try c.field("code")
            guard let value = BrowserBridgeErrorCode(rawValue: code) else { throw BrowserBridgeDecodingError.invalidField("code") }
            self = .error(value)
        case "host": self = .host
        default: throw BrowserBridgeDecodingError.unknownType(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BrowserBridgeField.self)
        try c.field("v", 1)
        switch self {
        case .pairCommit(let commit, let name):
            try c.field("t", "pair-commit"); try c.field("commit", commit.base64EncodedString()); try c.field("name", name)
        case .pairKey(let pub, let eph):
            try c.field("t", "pair-key"); try c.field("pub", pub.base64EncodedString()); try c.field("eph", eph.base64EncodedString())
        case .pairReveal(let pub, let eph, let nonce):
            try c.field("t", "pair-reveal"); try c.field("pub", pub.base64EncodedString()); try c.field("eph", eph.base64EncodedString()); try c.field("nonce", nonce.base64EncodedString())
        case .pairResult(let ok): try c.field("t", "pair-result"); try c.field("ok", ok)
        case .clientHello(let client, let eph):
            try c.field("t", "hello"); try c.field("client", client); try c.field("eph", eph.base64EncodedString())
        case .serverHello(let eph, let app):
            try c.field("t", "hello"); try c.field("eph", eph.base64EncodedString()); try c.field("app", app)
        case .message(let n, let ciphertext):
            try c.field("t", "msg"); try c.field("n", n); try c.field("c", ciphertext.base64EncodedString())
        case .error(let code): try c.field("t", "error"); try c.field("code", code)
        case .host: try c.field("t", "host")
        }
    }
}

struct BrowserBridgeRequest: Codable, Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case status
        case matches(origin: String)
        case credential(entry: UUID, db: UUID, origin: String, totp: Bool?)
        case reveal(entry: UUID, db: UUID)
        case unlock(db: UUID?)
    }
    let id: Int
    let operation: Operation

    init(id: Int, operation: Operation) { self.id = id; self.operation = operation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserBridgeField.self)
        id = try c.field("id")
        let type: String = try c.field("type")
        switch type {
        case "status": operation = .status
        case "matches": operation = .matches(origin: try c.field("origin"))
        case "credential": operation = .credential(entry: try c.field("entry"), db: try c.field("db"), origin: try c.field("origin"), totp: try c.optional("totp"))
        case "reveal": operation = .reveal(entry: try c.field("entry"), db: try c.field("db"))
        case "unlock": operation = .unlock(db: try c.optional("db"))
        default: throw BrowserBridgeDecodingError.unknownType(type)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BrowserBridgeField.self)
        try c.field("id", id)
        switch operation {
        case .status: try c.field("type", "status")
        case .matches(let origin): try c.field("type", "matches"); try c.field("origin", origin)
        case .credential(let entry, let db, let origin, let totp):
            try c.field("type", "credential"); try c.field("entry", entry); try c.field("db", db); try c.field("origin", origin)
            if let totp { try c.field("totp", totp) }
        case .reveal(let entry, let db): try c.field("type", "reveal"); try c.field("entry", entry); try c.field("db", db)
        case .unlock(let db): try c.field("type", "unlock"); if let db { try c.field("db", db) }
        }
    }
}

struct BrowserBridgeMatch: Codable, Equatable, Sendable {
    let entry: UUID
    let db: UUID
    let dbName: String
    let title: String
    let username: String
    let hasTotp: Bool
    let exact: Bool
}

struct BrowserBridgeReply: Codable, Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case status(app: String, unlocked: Int, locked: Int)
        case matches(entries: [BrowserBridgeMatch], locked: Int)
        case credential(username: String, password: String)
        /// The reply to a code-only `credential` request: the current code and nothing else.
        case totp(String)
        case empty
        case failure(BrowserBridgeRequestError)
    }
    let id: Int
    let result: Result
    init(id: Int, result: Result) { self.id = id; self.result = result }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserBridgeField.self)
        id = try c.field("id")
        let ok: Bool = try c.field("ok")
        if !ok {
            let error: String = try c.field("error")
            guard let value = BrowserBridgeRequestError(rawValue: error) else { throw BrowserBridgeDecodingError.invalidField("error") }
            result = .failure(value)
        } else {
            // Successful replies have no discriminator; their request supplies the required field set.
            guard let operation = decoder.userInfo.first(where: { $0.key.rawValue == "browserBridgeReplyOperation" })?.value as? BrowserBridgeRequest.Operation else {
                throw BrowserBridgeDecodingError.invalidField("reply context")
            }
            switch operation {
            case .status: result = .status(app: try c.field("app"), unlocked: try c.field("unlocked"), locked: try c.field("locked"))
            case .matches: result = .matches(entries: try c.field("entries"), locked: try c.field("locked"))
            case .credential(_, _, _, let totp) where totp == true: result = .totp(try c.field("totp"))
            case .credential: result = .credential(username: try c.field("username"), password: try c.field("password"))
            case .reveal, .unlock: result = .empty
            }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BrowserBridgeField.self)
        try c.field("id", id)
        if case .failure(let error) = result { try c.field("ok", false); try c.field("error", error); return }
        try c.field("ok", true)
        switch result {
        case .status(let app, let unlocked, let locked): try c.field("app", app); try c.field("unlocked", unlocked); try c.field("locked", locked)
        case .matches(let entries, let locked): try c.field("entries", entries); try c.field("locked", locked)
        case .credential(let username, let password): try c.field("username", username); try c.field("password", password)
        case .totp(let code): try c.field("totp", code)
        case .empty, .failure: break
        }
    }
}
#endif
