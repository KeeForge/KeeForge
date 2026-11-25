#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class BrowserBridgeRequestHandlerTests: XCTestCase {
    private var sessions: [DatabaseViewModel] = []
    private let key = SymmetricKey(size: .bits256)
    private let origin = "https://example.com"
    private var nextID = 0

    override func tearDown() async throws {
        for session in sessions { session.lockRequest(force: true) }
        sessions = []
        try await super.tearDown()
    }

    private func entry(_ title: String = "Login", url: String = "https://example.com", id: UUID = UUID()) throws -> KPEntry {
        KPEntry(id: id, title: title, username: "user", password: try .encrypt("password-\(title)", using: key), url: url)
    }

    private func makeSession(
        _ entries: [KPEntry], groups: [KPGroup] = [], enabled: Bool = true,
        gate: SecretAccessGate? = nil, databaseID: UUID = UUID()
    ) async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, id: databaseID)
        reference.autoFillEnabled = enabled
        let key = key
        let session = DatabaseViewModel(
            databaseReference: reference,
            reloadOperation: { reference, _ in
                .init(reference: reference, rootGroup: KPGroup(name: "Root", entries: entries, groups: groups),
                      meta: KPMeta(), formatVersion: .kdbx4(minor: 1), sessionKey: key,
                      openTimeSHA512: Data("test-hash".utf8), binaryPool: BinaryPool(rawFields: []))
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            expressUnlockKeySaveOperation: { _, _ in },
            storedKeyPresenceCheck: { _ in false },
            storedKeyStoreOperation: { _, _ in },
            storedKeyDeleteOperation: { _ in },
            deviceOwnerAuthAvailabilityCheck: { false },
            quickUnlockAvailabilityCheck: { false },
            secretAccess: gate ?? SecretAccessGate(isAuthenticationAvailable: { false })
        )
        sessions.append(session)
        await session.unlock(password: "testpassword123")
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(session.state, .unlocked)
        return session
    }

    private func handler(
        gate: @escaping BrowserBridgeRequestHandler.DeviceOwnerAuthenticator = { _, _ in true },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) -> BrowserBridgeRequestHandler {
        BrowserBridgeRequestHandler(sessionsProvider: { [weak self] in self?.sessions ?? [] }, appVersion: "test", authenticateDeviceOwner: gate, now: now)
    }

    private func send(_ op: BrowserBridgeRequest.Operation, to handler: BrowserBridgeRequestHandler) async -> BrowserBridgeReply.Result {
        nextID += 1
        return await handler.response(to: .init(id: nextID, operation: op)).result
    }

    private func matches(_ handler: BrowserBridgeRequestHandler, origin: String = "https://example.com") async throws -> [BrowserBridgeMatch] {
        let result = await send(.matches(origin: origin), to: handler)
        guard case .matches(let entries, _) = result else { XCTFail("Expected matches: \(result)"); return [] }
        return entries
    }

    private func credential(_ entry: KPEntry, _ session: DatabaseViewModel, origin: String = "https://example.com", totp: Bool? = nil) -> BrowserBridgeRequest.Operation {
        .credential(entry: entry.id, db: session.databaseReference.id, origin: origin, totp: totp)
    }

    func testOriginValidation() async {
        let accepted = ["https://example.com", "https://EXAMPLE.COM", "https://192.168.1.1", "https://example.com:8443", "https://example.com:0", "http://localhost:3000", "http://127.0.0.1", "http://[::1]:3000", "https://[2001:db8::1]", "https://xn--bcher-kva.de"]
        let rejected = ["", "https://example.com/", "https://example.com/path", "https://a@example.com", "https://a:b@example.com", "https://example.com?x", "https://example.com#x", "http://example.com", "file://example.com", "example.com", "https://", "https://example.com:", "https://example.com:65536", "https://example.com\\@evil.com", " https://example.com", "https://example.com/%2F", "https://example.com?", "https://example.com#", "https://[google.com]", "https://[invalid::address]",
                        "https://bücher.de", "https://\u{0430}pple.com", "https://example.com\u{202E}", "https://exa\u{200B}mple.com", "https://example.com\u{7F}"]
        var instant = ContinuousClock.now
        // A second apart, under the matches rate limit.
        let handler = handler(now: { instant += .seconds(1); return instant })
        for value in accepted {
            XCTAssertTrue(BrowserBridgeRequestHandler.validOrigin(value), value)
            let reply = await send(.matches(origin: value), to: handler)
            XCTAssertEqual(reply, .failure(.locked), value)
        }
        for value in rejected {
            XCTAssertFalse(BrowserBridgeRequestHandler.validOrigin(value), value)
            let reply = await send(.matches(origin: value), to: handler)
            XCTAssertEqual(reply, .failure(.badOrigin), value)
        }
    }

    func testMatchesFiltersAndOrdersAcrossDatabasesAndContainsOnlyMetadata() async throws {
        let loose = try entry("Loose", url: "https://login.example.com")
        let exact = try entry("Exact")
        let other = try entry("Other", url: "https://other.net")
        let hidden = try entry("Hidden")
        let empty = KPEntry(title: "Empty", url: origin)
        let expired = KPEntry(title: "Expired", password: exact.password, url: origin, expires: true, expiryTime: .distantPast)
        let first = try await makeSession([loose, other, empty, expired], groups: [KPGroup(name: "Excluded", entries: [hidden], searchingEnabled: .disabled)])
        let second = try await makeSession([exact])
        _ = try await makeSession([try entry("Disabled")], enabled: false)
        let handler = handler()
        let rows = try await matches(handler)
        XCTAssertEqual(rows.map(\.title), ["Exact", "Loose"])
        XCTAssertEqual(rows.map(\.exact), [true, false])
        XCTAssertEqual(rows.map(\.db), [second.databaseReference.id, first.databaseReference.id])
        XCTAssertEqual(rows.map(\.dbName), [second.databaseReference.displayName, first.databaseReference.displayName])
        let json = try JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(BrowserBridgeReply(id: 1, result: .matches(entries: rows, locked: 0)))) as! [String: Any]
        for row in json["entries"] as! [[String: Any]] {
            XCTAssertEqual(Set(row.keys), ["entry", "db", "dbName", "title", "username", "hasTotp", "exact"])
        }
        let result = await send(credential(loose, first), to: handler)
        XCTAssertEqual(result, .credential(username: "user", password: "password-Loose"))
    }

    func testFiftyCapAndOnlyReturnedPairsAreOffered() async throws {
        let entries = try (0..<55).map { try entry("\($0)") }
        let session = try await makeSession(entries)
        let handler = handler()
        let rows = try await matches(handler)
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows.map(\.entry), Array(entries.prefix(50)).map(\.id))
        let result = await send(credential(entries[50], session), to: handler)
        XCTAssertEqual(result, .failure(.notOffered))
    }

    func testLongDisplayFieldsAreTruncatedAndRowsDroppedToFitTheFrame() async throws {
        // Unbounded titles used to make the reply too large to seal, closing the connection.
        let long = try (0..<50).map { try entry(String(repeating: "t", count: 30_000) + "\($0)") }
        let first = try await makeSession(long)
        let handler = handler()
        let rows = try await matches(handler)
        XCTAssertEqual(rows.count, 50)
        XCTAssertTrue(rows.allSatisfy { $0.title == String(repeating: "t", count: BrowserBridgeRequestHandler.displayFieldLimit) })
        XCTAssertTrue(rows.allSatisfy { $0.dbName.count <= BrowserBridgeRequestHandler.displayFieldLimit })

        // Each character carries many combining marks, so even cut titles cannot all fit.
        let heavy = String(repeating: "e" + String(repeating: "\u{0301}", count: 60), count: 300)
        let entries = try (0..<50).map { _ in try entry(heavy) }
        first.lockRequest(force: true)
        let session = try await makeSession(entries)
        let fitted = try await matches(handler)
        XCTAssertGreaterThan(fitted.count, 0)
        XCTAssertLessThan(fitted.count, 50)
        XCTAssertEqual(fitted.map(\.entry), Array(entries.prefix(fitted.count)).map(\.id), "Rows are dropped from the end")
        let reply = BrowserBridgeReply(id: 9_007_199_254_740_991, result: .matches(entries: fitted, locked: 1))
        XCTAssertLessThanOrEqual(try BrowserBridgeJSON.encode(reply).count, BrowserBridgeFraming.maximumReplyPlaintext)
        let dropped = await send(credential(entries[fitted.count], session), to: handler)
        XCTAssertEqual(dropped, .failure(.notOffered), "Only returned rows are offered")
        let kept = await send(credential(entries[0], session), to: handler)
        XCTAssertEqual(kept, .credential(username: "user", password: "password-\(heavy)"))
    }

    func testLockedAndPendingSessionsAreCountedAndWithdrawn() async throws {
        let first = try await makeSession([try entry()])
        let second = try await makeSession([try entry()])
        let handler = handler()
        first.holdForQuitPrompt()
        second.lockRequest(force: true)
        let status = await send(.status, to: handler)
        XCTAssertEqual(status, .status(app: "test", unlocked: 0, locked: 2))
        let locked = await send(.matches(origin: origin), to: handler)
        XCTAssertEqual(locked, .failure(.locked))
        first.releaseQuitHold()
        let result = await send(.matches(origin: origin), to: handler)
        guard case .matches(let rows, let lockedCount) = result else { return XCTFail() }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(lockedCount, 1)
    }

    func testDatabaseIdentityAndConnectionOriginOffers() async throws {
        let id = UUID()
        let a = try entry("A", id: id)
        let b = try entry("B", id: id)
        let first = try await makeSession([a])
        let second = try await makeSession([b])
        let handler = handler()
        let unoffered = await send(credential(a, first), to: handler)
        XCTAssertEqual(unoffered, .failure(.notOffered))
        _ = try await matches(handler)
        let otherOrigin = await send(credential(a, first, origin: "https://login.example.com"), to: handler)
        XCTAssertEqual(otherOrigin, .failure(.notOffered))
        let otherConnection = await send(credential(a, first), to: self.handler())
        XCTAssertEqual(otherConnection, .failure(.notOffered))
        let result = await send(credential(b, second), to: handler)
        XCTAssertEqual(result, .credential(username: "user", password: "password-B"))
    }

    func testOfferEvictionAndReplacement() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let handler = handler()
        _ = try await matches(handler)
        for port in 1...8 { _ = try await matches(handler, origin: "https://example.com:\(port)") }
        let evicted = await send(credential(entry, session), to: handler)
        XCTAssertEqual(evicted, .failure(.notOffered))
        let retained = await send(credential(entry, session, origin: "https://example.com:8"), to: handler)
        XCTAssertEqual(retained, .credential(username: "user", password: "password-Login"))
    }

    func testURLChangedAndSessionRemoved() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let handler = handler()
        _ = try await matches(handler)
        try session.applyEntryEdit(.updateEntry(entryID: entry.id, draft: EntryDraftPayload(title: entry.title, username: entry.username, password: "password-Login", url: "https://other.net")))
        let changed = await send(credential(entry, session), to: handler)
        XCTAssertEqual(changed, .failure(.noMatch))
        sessions.removeAll()
        let removed = await send(credential(entry, session), to: handler)
        XCTAssertEqual(removed, .failure(.unavailable))
        session.lockRequest(force: true)
    }

    func testDeniedAndCancelledNeverDecryptPassword() async throws {
        let corrupt = KPEntry(title: "Corrupt", password: EncryptedValue(sealedData: Data([1]), hasValue: true), url: origin)
        let session = try await makeSession([corrupt])
        for cancelled in [false, true] {
            let gate = SecretAccessGate(gracePeriod: { .alwaysAsk }, isAuthenticationAvailable: { true }, prompt: { _ in
                if cancelled { throw CancellationError() }
                throw NSError(domain: "TestDenied", code: 1)
            })
            let handler = handler(gate: { _, reason in await BrowserBridgeRequestHandler.deviceOwnerGate(gate, reason: reason) })
            _ = try await matches(handler)
            let result = await send(credential(corrupt, session), to: handler)
            XCTAssertEqual(result, .failure(.denied))
        }
    }

    func testLockPendingLockRelockAndReplacementDuringGateReleaseNothing() async throws {
        for change in 0..<4 {
            let entry = try entry()
            let session = try await makeSession([entry])
            let handler = handler(gate: { [self] _, _ in
                switch change {
                case 0: session.lockRequest(force: true)
                case 1:
                    session.lockRequest(force: true)
                    await session.unlock(password: "testpassword123")
                    try? await session.reloadDiscardingDraft()
                case 2: session.holdForQuitPrompt()
                default:
                    sessions.removeAll { $0 === session }
                    _ = try? await makeSession([entry], databaseID: session.databaseReference.id)
                }
                return true
            })
            _ = try await matches(handler)
            let result = await send(credential(entry, session), to: handler)
            XCTAssertEqual(result, .failure(.locked), "change \(change)")
            session.lockRequest(force: true)
        }
    }

    func testURLChangedDuringGateIsNoMatch() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let handler = handler(gate: { _, _ in
            try? session.applyEntryEdit(.updateEntry(entryID: entry.id, draft: EntryDraftPayload(title: entry.title, password: "password-Login", url: "https://other.net")))
            return true
        })
        _ = try await matches(handler)
        let result = await send(credential(entry, session), to: handler)
        XCTAssertEqual(result, .failure(.noMatch))
    }

    func testRealSessionGateGracePeriod() async throws {
        var reasons: [String] = []
        var prompts: Int { reasons.count }
        var instant = ContinuousClock.now
        let gate = SecretAccessGate(gracePeriod: { .thirtySeconds }, now: { instant }, isAuthenticationAvailable: { true }, prompt: { reasons.append($0) })
        let entry = try entry()
        let session = try await makeSession([entry], gate: gate)
        gate.invalidate()
        let handler = handler(gate: BrowserBridgeRequestHandler.deviceOwnerGate)
        _ = try await matches(handler)
        for _ in 0..<2 {
            let result = await send(credential(entry, session), to: handler)
            XCTAssertEqual(result, .credential(username: "user", password: "password-Login"))
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(reasons, [String(localized: "Fill “\("Login")” on \("example.com") in your browser")])
        instant += .seconds(30)
        _ = await send(credential(entry, session), to: handler)
        XCTAssertEqual(prompts, 2)
    }

    /// Never Ask releases every fill of the unlocked session without a prompt,
    /// until the session ends the grant.
    func testNeverAskReleasesWithoutAPromptUntilTheGrantEnds() async throws {
        var prompts = 0
        var instant = ContinuousClock.now
        let gate = SecretAccessGate(gracePeriod: { .never }, now: { instant }, isAuthenticationAvailable: { true }, prompt: { _ in prompts += 1 })
        let entry = try entry()
        let session = try await makeSession([entry], gate: gate)
        let handler = handler(gate: BrowserBridgeRequestHandler.deviceOwnerGate)
        _ = try await matches(handler)

        instant += .seconds(24 * 60 * 60)
        let released = await send(credential(entry, session), to: handler)
        XCTAssertEqual(released, .credential(username: "user", password: "password-Login"))
        XCTAssertEqual(prompts, 0)

        gate.invalidate()
        _ = await send(credential(entry, session), to: handler)
        XCTAssertEqual(prompts, 1)
        session.lockRequest(force: true)
    }

    func testUnavailableOwnerAuthenticationReleasesOnlyInsideTheGracePeriod() async throws {
        var corrupt = KPEntry(title: "Corrupt", password: EncryptedValue(sealedData: Data([1]), hasValue: true), url: origin)
        corrupt.totpConfig = TOTPConfig(secret: try .encrypt("JBSWY3DPEHPK3PXP", using: key))
        var prompts = 0
        let alwaysAsk = SecretAccessGate(gracePeriod: { .alwaysAsk }, isAuthenticationAvailable: { false }, prompt: { _ in prompts += 1 })
        let session = try await makeSession([corrupt], gate: alwaysAsk)
        let handler = handler(gate: BrowserBridgeRequestHandler.deviceOwnerGate)
        _ = try await matches(handler)
        // Decrypting the corrupt password would answer bad-request; denied means nothing was decrypted.
        let password = await send(credential(corrupt, session), to: handler)
        XCTAssertEqual(password, .failure(.denied))
        let code = await send(credential(corrupt, session, totp: true), to: handler)
        XCTAssertEqual(code, .failure(.denied))
        XCTAssertEqual(prompts, 0)

        var instant = ContinuousClock.now
        let grace = SecretAccessGate(gracePeriod: { .thirtySeconds }, now: { instant }, isAuthenticationAvailable: { false }, prompt: { _ in prompts += 1 })
        let entry = try entry()
        let unlocked = try await makeSession([entry], gate: grace)
        _ = try await matches(handler)
        let inGrace = await send(credential(entry, unlocked), to: handler)
        XCTAssertEqual(inGrace, .credential(username: "user", password: "password-Login"), "The unlock's grace period still releases")
        instant += .seconds(30)
        let expired = await send(credential(entry, unlocked), to: handler)
        XCTAssertEqual(expired, .failure(.denied))
        XCTAssertEqual(prompts, 0)
    }

    func testFillReasonNamesSanitizedTitleAndHost() {
        func reason(_ title: String, _ host: String) -> String {
            String(localized: "Fill “\(title)” on \(host) in your browser")
        }
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Bank", origin: "https://example.com"), reason("Bank", "example.com"))
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Bank", origin: "https://Login.EXAMPLE.com:8443"), reason("Bank", "login.example.com"))
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Bank", origin: "https://www.example.com"), reason("Bank", "example.com"))
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Bücher", origin: "https://xn--bcher-kva.de"), reason("Bücher", "xn--bcher-kva.de"),
                       "An IDN stays in punycode")
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Dev", origin: "http://[::1]:3000"), reason("Dev", "::1"))
        for title in ["", " \n\t ", "\u{202E}\u{200B}"] {
            XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: title, origin: "https://example.com"),
                           String(localized: "Fill a login on \("example.com") in your browser"))
        }

        let hostile = BrowserBridgeRequestHandler.fillReason(title: "Bank\u{202E}moc.live\n\u{200B}Evil\t\tX\u{2066}", origin: "https://example.com")
        XCTAssertEqual(hostile, reason("Bankmoc.live Evil X", "example.com"))
        let forbidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        XCTAssertFalse(hostile.unicodeScalars.contains { forbidden.contains($0.properties.generalCategory) })

        let longTitle = BrowserBridgeRequestHandler.fillReason(title: String(repeating: "x", count: 300), origin: "https://example.com")
        XCTAssertEqual(longTitle, reason(String(repeating: "x", count: BrowserBridgeRequestHandler.promptFieldLimit), "example.com"))

        let longHost = String(repeating: "a.", count: 100) + "bank.example.com"
        let shownHost = "…" + longHost.suffix(BrowserBridgeRequestHandler.promptFieldLimit - 1)
        XCTAssertEqual(BrowserBridgeRequestHandler.fillReason(title: "Bank", origin: "https://\(longHost)"), reason("Bank", shownHost))
        XCTAssertTrue(shownHost.hasSuffix("bank.example.com"), "The registrable end of the host stays visible")
        XCTAssertEqual(shownHost.count, BrowserBridgeRequestHandler.promptFieldLimit)
    }

    func testMatchesAllowABurstOfTenThenFivePerSecondPerConnection() async throws {
        var instant = ContinuousClock.now
        let handler = handler(now: { instant })
        var results: [BrowserBridgeReply.Result] = []
        for _ in 0..<11 { results.append(await send(.matches(origin: origin), to: handler)) }
        XCTAssertEqual(results, Array(repeating: .failure(.locked), count: 10) + [.failure(.rateLimited)])
        let invalid = await send(.matches(origin: "https://example.com/"), to: handler)
        XCTAssertEqual(invalid, .failure(.rateLimited), "Every matches request spends the allowance")

        let other = await send(.matches(origin: origin), to: self.handler(now: { instant }))
        XCTAssertEqual(other, .failure(.locked), "Each connection has its own allowance")
        let status = await send(.status, to: handler)
        XCTAssertEqual(status, .status(app: "test", unlocked: 0, locked: 0), "Other requests are not limited")
        let credential = await send(.credential(entry: UUID(), db: UUID(), origin: origin, totp: nil), to: handler)
        XCTAssertEqual(credential, .failure(.notOffered))
        let unlock = await send(.unlock(db: nil), to: handler)
        XCTAssertEqual(unlock, .empty)

        instant += .milliseconds(199)
        let early = await send(.matches(origin: origin), to: handler)
        XCTAssertEqual(early, .failure(.rateLimited))
        instant += .milliseconds(1)
        let refilled = await send(.matches(origin: origin), to: handler)
        XCTAssertEqual(refilled, .failure(.locked))
        let again = await send(.matches(origin: origin), to: handler)
        XCTAssertEqual(again, .failure(.rateLimited), "Five per second after the burst")

        instant += .seconds(60)
        results = []
        for _ in 0..<11 { results.append(await send(.matches(origin: origin), to: handler)) }
        XCTAssertEqual(results, Array(repeating: .failure(.locked), count: 10) + [.failure(.rateLimited)], "Idling refills the burst, never beyond 10")
    }

    func testProtectedUsernameAndPasswordReferences() async throws {
        let target = try entry("Target", url: "https://other.net")
        let reference = "{REF:P@I:\(target.id.uuidString.replacingOccurrences(of: "-", with: ""))}"
        var referencing = try entry("Reference")
        referencing.username = reference
        referencing.password = try .encrypt(reference, using: key)
        referencing.totpConfig = TOTPConfig(secret: try .encrypt("JBSWY3DPEHPK3PXP", using: key))
        var publicReference = try entry("PublicReference")
        publicReference.username = "{REF:U@I:\(target.id.uuidString.replacingOccurrences(of: "-", with: ""))}"
        let session = try await makeSession([target, referencing, publicReference])
        let handler = handler()
        let rows = try await matches(handler)
        XCTAssertEqual(rows.first { $0.entry == referencing.id }?.username, "")
        XCTAssertEqual(rows.first { $0.entry == referencing.id }?.hasTotp, true)
        XCTAssertEqual(rows.first { $0.entry == publicReference.id }?.username, "user")
        let result = await send(credential(referencing, session), to: handler)
        XCTAssertEqual(result, .credential(username: "password-Target", password: "password-Target"))
    }

    func testCodeOnlyRequestReturnsOnlyTheCodeAndNeverReadsThePassword() async throws {
        var withCode = try entry("Code")
        // A password this session cannot decrypt: a code-only request must not need it.
        withCode.password = try .encrypt("other-key-password", using: SymmetricKey(size: .bits256))
        withCode.totpConfig = TOTPConfig(secret: try .encrypt("JBSWY3DPEHPK3PXP", using: key))
        let plain = try entry("NoCode")
        let session = try await makeSession([withCode, plain])
        var prompts = 0
        let handler = handler(gate: { _, _ in prompts += 1; return true })
        _ = try await matches(handler)
        let result = await send(credential(withCode, session, totp: true), to: handler)
        guard case .totp(let code) = result else { return XCTFail("Expected a code: \(result)") }
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertEqual(prompts, 1)
        let json = try JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(BrowserBridgeReply(id: 1, result: result))) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["id", "ok", "totp"])
        let noCode = await send(credential(plain, session, totp: true), to: handler)
        XCTAssertEqual(noCode, .failure(.unavailable))
        XCTAssertEqual(prompts, 1)
        let passwordFill = await send(credential(plain, session), to: handler)
        XCTAssertEqual(passwordFill, .credential(username: "user", password: "password-NoCode"))
        let passwordJSON = try JSONSerialization.jsonObject(with: BrowserBridgeJSON.encode(BrowserBridgeReply(id: 2, result: passwordFill))) as! [String: Any]
        XCTAssertEqual(Set(passwordJSON.keys), ["id", "ok", "username", "password"])
    }

    func testRevealAndUnlock() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let db = session.databaseReference.id
        var revealed: [UUID] = []
        var unlocked: [UUID?] = []
        var instant = ContinuousClock.now
        // Each request a second apart, under the reveal and unlock rate limit.
        let handler = BrowserBridgeRequestHandler(sessionsProvider: { self.sessions }, appVersion: "test", reveal: { revealed = [$0, $1] }, unlock: { unlocked.append($0) },
                                                  now: { instant += .seconds(1); return instant })
        let before = await send(.reveal(entry: entry.id, db: db), to: handler)
        XCTAssertEqual(before, .failure(.notOffered))
        _ = try await matches(handler)
        let reveal = await send(.reveal(entry: entry.id, db: db), to: handler)
        XCTAssertEqual(reveal, .empty)
        XCTAssertEqual(revealed, [entry.id, db])
        for id in [db, nil] as [UUID?] {
            let result = await send(.unlock(db: id), to: handler)
            XCTAssertEqual(result, .empty)
        }
        XCTAssertEqual(unlocked, [db, nil])
        let unknown = await send(.unlock(db: UUID()), to: handler)
        XCTAssertEqual(unknown, .failure(.unavailable))
        sessions.removeAll()
        let gone = await send(.reveal(entry: entry.id, db: db), to: handler)
        XCTAssertEqual(gone, .failure(.unavailable))
        session.lockRequest(force: true)
    }

    func testRevealAndUnlockShareABurstOfThreeThenOnePerSecondPerConnection() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let db = session.databaseReference.id
        var instant = ContinuousClock.now
        var fronts = 0
        func make() -> BrowserBridgeRequestHandler {
            BrowserBridgeRequestHandler(sessionsProvider: { self.sessions }, appVersion: "test",
                                        reveal: { _, _ in fronts += 1 }, unlock: { _ in fronts += 1 }, now: { instant })
        }
        let handler = make()
        _ = try await matches(handler)
        let reveal = BrowserBridgeRequest.Operation.reveal(entry: entry.id, db: db)
        var results: [BrowserBridgeReply.Result] = []
        for op in [reveal, .unlock(db: db), .unlock(db: nil), reveal, .unlock(db: nil)] {
            results.append(await send(op, to: handler))
        }
        XCTAssertEqual(results, [.empty, .empty, .empty, .failure(.rateLimited), .failure(.rateLimited)])
        XCTAssertEqual(fronts, 3, "A refused request fronts nothing")

        let other = make()
        let unaffected = await send(.unlock(db: nil), to: other)
        XCTAssertEqual(unaffected, .empty, "Each connection has its own allowance")
        XCTAssertEqual(fronts, 4)

        instant += .milliseconds(999)
        let early = await send(.unlock(db: nil), to: handler)
        XCTAssertEqual(early, .failure(.rateLimited))
        instant += .milliseconds(1)
        let afterOneSecond = await send(reveal, to: handler)
        XCTAssertEqual(afterOneSecond, .empty)
        let again = await send(reveal, to: handler)
        XCTAssertEqual(again, .failure(.rateLimited), "One per second after the burst")

        instant += .seconds(60)
        results = []
        for _ in 0..<4 { results.append(await send(.unlock(db: nil), to: handler)) }
        XCTAssertEqual(results, [.empty, .empty, .empty, .failure(.rateLimited)], "Idling refills the burst, never beyond 3")
        let status = await send(.status, to: handler)
        XCTAssertEqual(status, .status(app: "test", unlocked: 1, locked: 0), "Other requests are not limited")
        XCTAssertEqual(fronts, 8)
    }

    func testOfferedCredentialLocksAndEntryRemovalAreRefused() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let handler = handler()
        _ = try await matches(handler)
        session.holdForQuitPrompt()
        let pending = await send(credential(entry, session), to: handler)
        XCTAssertEqual(pending, .failure(.locked))
        session.releaseQuitHold()
        try session.applyEntryEdit(.deleteEntry(entryID: entry.id, sendToRecycleBin: false))
        let gone = await send(credential(entry, session), to: handler)
        XCTAssertEqual(gone, .failure(.unavailable))
    }

    func testReplacedOfferWithdrawsPreviouslyReturnedPairs() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        let handler = handler()
        _ = try await matches(handler)
        try session.applyEntryEdit(.deleteEntry(entryID: entry.id, sendToRecycleBin: false))
        let rows = try await matches(handler)
        XCTAssertEqual(rows, [])
        let withdrawn = await send(credential(entry, session), to: handler)
        XCTAssertEqual(withdrawn, .failure(.notOffered))
    }

    func testCredentialRateWindowCountsFailuresAndExpires() async throws {
        var instant = ContinuousClock.now
        let handler = handler(now: { instant })
        let op = BrowserBridgeRequest.Operation.credential(entry: UUID(), db: UUID(), origin: origin, totp: nil)
        for _ in 0..<30 {
            let result = await send(op, to: handler)
            XCTAssertEqual(result, .failure(.notOffered))
        }
        let limited = await send(op, to: handler)
        XCTAssertEqual(limited, .failure(.rateLimited))
        instant += .seconds(60)
        let nextWindow = await send(op, to: handler)
        XCTAssertEqual(nextWindow, .failure(.notOffered))
    }

    func testOneCredentialInFlightWhileStatusStillWorks() async throws {
        let entry = try entry()
        let session = try await makeSession([entry])
        var continuation: CheckedContinuation<Bool, Never>?
        let handler = handler(gate: { _, _ in await withCheckedContinuation { continuation = $0 } })
        _ = try await matches(handler)
        let op = credential(entry, session)
        let first = Task { await self.send(op, to: handler) }
        while continuation == nil { await Task.yield() }
        let second = await send(op, to: handler)
        XCTAssertEqual(second, .failure(.rateLimited))
        let status = await send(.status, to: handler)
        XCTAssertEqual(status, .status(app: "test", unlocked: 1, locked: 0))
        continuation?.resume(returning: true)
        let result = await first.value
        XCTAssertEqual(result, .credential(username: "user", password: "password-Login"))
    }

    func testSixteenRequestsInFlightAndMalformedRequests() async {
        let handler = handler()
        let tasks = (0..<40).map { id in Task { await handler.response(to: .init(id: id, operation: .status)).result } }
        var results: [BrowserBridgeReply.Result] = []
        for task in tasks { results.append(await task.value) }
        XCTAssertEqual(results.filter { $0 == .status(app: "test", unlocked: 0, locked: 0) }.count, 16)
        XCTAssertEqual(results.filter { $0 == .failure(.rateLimited) }.count, 24)
        for json in ["{", "{\"id\":42,\"type\":\"credential\"}", "{\"id\":-1,\"type\":\"status\"}"] {
            let result = await handler.response(to: Data(json.utf8))
            XCTAssertEqual(result.result, .failure(.badRequest))
        }
    }
}
#endif
