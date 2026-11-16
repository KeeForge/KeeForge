#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import SiteMatching

/// One connection's offers and authorization. Socket callers await this actor;
/// the main actor must never wait for their socket threads.
@MainActor
final class BrowserBridgeRequestHandler {
    typealias SessionsProvider = @MainActor () -> [DatabaseViewModel]
    typealias DeviceOwnerAuthenticator = @MainActor (SecretAccessGate) async -> Bool

    /// `matches` fields the extension only displays are cut to this many characters.
    static let displayFieldLimit = 256
    /// `reveal` and `unlock` together: a burst of 3, then one per second.
    static let frontBurst = 3
    static let frontInterval: Duration = .seconds(1)

    private struct Pair: Hashable {
        let entry: UUID
        let db: UUID
    }

    private let sessionsProvider: SessionsProvider
    private let appVersion: String
    private let reveal: @MainActor (UUID, UUID) -> Void
    private let unlock: @MainActor (UUID?) -> Void
    private let authenticate: DeviceOwnerAuthenticator
    private let now: @MainActor () -> ContinuousClock.Instant
    private var offers: [String: Set<Pair>] = [:]
    private var origins: [String] = []
    private var activeIDs = Set<Int>()
    private var credentialInFlight = false
    private var credentialTimes: [ContinuousClock.Instant] = []
    /// When the front allowance is next fully spent (GCRA's theoretical arrival time).
    private var frontsDue: ContinuousClock.Instant?

    init(
        sessionsProvider: @escaping SessionsProvider,
        appVersion: String,
        reveal: @escaping @MainActor (UUID, UUID) -> Void = { _, _ in },
        unlock: @escaping @MainActor (UUID?) -> Void = { _ in },
        authenticateDeviceOwner: @escaping DeviceOwnerAuthenticator = BrowserBridgeRequestHandler.deviceOwnerGate,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.sessionsProvider = sessionsProvider
        self.appVersion = appVersion
        self.reveal = reveal
        self.unlock = unlock
        self.authenticate = authenticateDeviceOwner
        self.now = now
    }

    static func deviceOwnerGate(_ gate: SecretAccessGate) async -> Bool {
        guard gate.requiresAuthentication else { return true }
        do {
            try await gate.authenticate(reason: String(localized: "Fill a login in your browser"))
            return true
        } catch { return false }
    }

    /// Malformed bodies without a usable request ID receive ID zero.
    func response(to data: Data) async -> BrowserBridgeReply {
        do { return await response(to: try BrowserBridgeJSON.decode(BrowserBridgeRequest.self, from: data)) }
        catch {
            struct Identifier: Decodable { let id: Int }
            let id = (try? JSONDecoder().decode(Identifier.self, from: data).id) ?? 0
            return BrowserBridgeReply(id: id, result: .failure(.badRequest))
        }
    }

    func response(to request: BrowserBridgeRequest) async -> BrowserBridgeReply {
        func reply(_ result: BrowserBridgeReply.Result) -> BrowserBridgeReply { .init(id: request.id, result: result) }
        guard (0...9_007_199_254_740_991).contains(request.id), !activeIDs.contains(request.id) else {
            return reply(.failure(.badRequest))
        }
        guard activeIDs.count < 16 else { return reply(.failure(.rateLimited)) }
        switch request.operation {
        case .reveal, .unlock: guard admitFront() else { return reply(.failure(.rateLimited)) }
        default: break
        }
        let isCredential: Bool
        if case .credential = request.operation { isCredential = true } else { isCredential = false }
        if isCredential {
            let instant = now()
            credentialTimes.removeAll { instant - $0 >= .seconds(60) }
            guard !credentialInFlight, credentialTimes.count < 30 else { return reply(.failure(.rateLimited)) }
            credentialTimes.append(instant)
            credentialInFlight = true
        }
        activeIDs.insert(request.id)
        defer {
            activeIDs.remove(request.id)
            if isCredential { credentialInFlight = false }
        }
        await Task.yield()
        guard !Task.isCancelled else { return reply(.failure(.badRequest)) }
        return reply(await perform(request.operation))
    }

    private func admitFront() -> Bool {
        let instant = now()
        let due = max(frontsDue ?? instant, instant)
        guard due - instant <= Self.frontInterval * (Self.frontBurst - 1) else { return false }
        frontsDue = due + Self.frontInterval
        return true
    }

    private func perform(_ operation: BrowserBridgeRequest.Operation) async -> BrowserBridgeReply.Result {
        switch operation {
        case .status:
            let sessions = sessionsProvider()
            let unlocked = sessions.filter(Self.isUnlocked).count
            return .status(app: appVersion, unlocked: unlocked, locked: sessions.count - unlocked)
        case .matches(let origin):
            guard Self.validOrigin(origin) else { return .failure(.badOrigin) }
            let sessions = sessionsProvider()
            let unlocked = sessions.filter(Self.isUnlocked)
            guard !unlocked.isEmpty else {
                remember([], for: origin)
                return .failure(.locked)
            }
            var exact: [BrowserBridgeMatch] = []
            var possible: [BrowserBridgeMatch] = []
            for session in unlocked {
                for entry in Self.eligibleEntries(in: session) {
                    let match = CredentialMatcher.interactiveMatches(from: [entry], for: [SiteRequest.url(origin)])
                    guard !match.exact.isEmpty || !match.possible.isEmpty else { continue }
                    let isExact = !match.exact.isEmpty
                    let row = BrowserBridgeMatch(
                        entry: entry.id, db: session.databaseReference.id,
                        dbName: Self.displayField(session.databaseReference.displayName),
                        title: Self.displayField(entry.title),
                        username: Self.displayField(session.fieldReferenceResolution(of: entry.username).value ?? ""),
                        hasTotp: entry.hasTOTP, exact: isExact
                    )
                    if isExact { if exact.count < 50 { exact.append(row) } }
                    else if possible.count < 50 { possible.append(row) }
                }
            }
            let locked = sessions.count - unlocked.count
            let rows = Self.fittingReply(Array((exact + possible).prefix(50)), locked: locked)
            remember(Set(rows.map { Pair(entry: $0.entry, db: $0.db) }), for: origin)
            return .matches(entries: rows, locked: locked)
        case .credential(let entryID, let db, let origin, let totp):
            guard Self.validOrigin(origin) else { return .failure(.badOrigin) }
            guard offers[origin]?.contains(Pair(entry: entryID, db: db)) == true else { return .failure(.notOffered) }
            guard let source = session(db) else { return .failure(.unavailable) }
            guard Self.isUnlocked(source) else { return .failure(.locked) }
            guard source.entry(withID: entryID) != nil else { return .failure(.unavailable) }
            guard let offered = matchingEntry(entryID, in: source, origin: origin) else { return .failure(.noMatch) }
            let codeOnly = totp == true
            guard !codeOnly || offered.hasTOTP else { return .failure(.unavailable) }
            let cycle = source.lockCycleID
            let authorized = await authenticate(source.secretAccess)
            guard session(db) === source, Self.isUnlocked(source), source.lockCycleID == cycle else { return .failure(.locked) }
            guard authorized, !Task.isCancelled else { return .failure(.denied) }
            guard let entry = matchingEntry(entryID, in: source, origin: origin) else { return .failure(.noMatch) }
            guard let key = source.sessionKey else { return .failure(.locked) }
            let revision = source.contentRevision
            let entries = source.currentRootGroup?.allEntries ?? []
            // Capture encrypted values only; plaintext is created after authorization, off the main actor.
            let result = await Task.detached {
                if codeOnly {
                    guard let config = entry.totpConfig else { return BrowserBridgeReply.Result.failure(.unavailable) }
                    return .totp(TOTPGenerator.generateCode(config: config, sessionKey: key))
                }
                let resolver = FieldReferenceResolver(entries: entries, sessionKey: key)
                let username = resolver.resolve(entry.username, clearance: .protectedValues).value ?? ""
                guard let password = try? entry.password.decrypt(using: key) else {
                    return BrowserBridgeReply.Result.failure(.badRequest)
                }
                let resolvedPassword = resolver.resolve(password, clearance: .protectedValues).value ?? password
                return .credential(username: username, password: resolvedPassword)
            }.value
            guard !Task.isCancelled, session(db) === source, Self.isUnlocked(source), source.lockCycleID == cycle else {
                return .failure(.locked)
            }
            guard matchingEntry(entryID, in: source, origin: origin) != nil else { return .failure(.noMatch) }
            guard source.contentRevision == revision else { return .failure(.locked) }
            return result
        case .reveal(let entry, let db):
            guard session(db) != nil else { return .failure(.unavailable) }
            guard offers.values.contains(where: { $0.contains(Pair(entry: entry, db: db)) }) else { return .failure(.notOffered) }
            reveal(entry, db)
            return .empty
        case .unlock(let db):
            if let db, session(db) == nil { return .failure(.unavailable) }
            unlock(db)
            return .empty
        }
    }

    private static func displayField(_ value: String) -> String {
        String(value.prefix(displayFieldLimit))
    }

    /// The leading rows whose `matches` reply, sealed, fits the frame cap toward the extension.
    private static func fittingReply(_ rows: [BrowserBridgeMatch], locked: Int) -> [BrowserBridgeMatch] {
        // The largest request ID gives the longest encoding; rows encode the same alone as inside the array.
        let reply = BrowserBridgeReply(id: 9_007_199_254_740_991, result: .matches(entries: [], locked: locked))
        guard var size = try? BrowserBridgeJSON.encode(reply).count else { return [] }
        var count = 0
        for row in rows {
            guard let rowSize = try? BrowserBridgeJSON.encode(row).count else { break }
            size += rowSize + (count == 0 ? 0 : 1)
            guard size <= BrowserBridgeFraming.maximumReplyPlaintext else { break }
            count += 1
        }
        return Array(rows.prefix(count))
    }

    private func session(_ id: UUID) -> DatabaseViewModel? {
        sessionsProvider().first { $0.databaseReference.id == id }
    }

    private static func isUnlocked(_ session: DatabaseViewModel) -> Bool {
        session.state == .unlocked && !session.isLockPending
    }

    private static func eligibleEntries(in session: DatabaseViewModel) -> [KPEntry] {
        guard session.databaseReference.autoFillEnabled, let root = session.currentRootGroup else { return [] }
        return root.autoFillEntries(excludingGroupID: root.recycleBinUUID).filter { $0.hasPassword || $0.hasTOTP }
    }

    private func matchingEntry(_ id: UUID, in session: DatabaseViewModel, origin: String) -> KPEntry? {
        guard let entry = Self.eligibleEntries(in: session).first(where: { $0.id == id }) else { return nil }
        let match = CredentialMatcher.interactiveMatches(from: [entry], for: [SiteRequest.url(origin)])
        return match.exact.isEmpty && match.possible.isEmpty ? nil : entry
    }

    private func remember(_ pairs: Set<Pair>, for origin: String) {
        origins.removeAll { $0 == origin }
        origins.append(origin)
        offers[origin] = pairs
        if origins.count > 8 { offers.removeValue(forKey: origins.removeFirst()) }
    }

    static func validOrigin(_ origin: String) -> Bool {
        guard !origin.isEmpty, !origin.contains(where: { $0.isWhitespace || $0.isNewline }),
              !origin.contains("\\"), !origin.contains("%"),
              let components = URLComponents(string: origin),
              let scheme = components.scheme, ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              components.port.map({ (0...65535).contains($0) }) ?? true,
              let url = components.url, url.host != nil
        else { return false }
        let authority = String(origin.dropFirst(scheme.count + 3))
        guard origin.hasPrefix(scheme + "://"), !authority.hasSuffix(":"),
              !host.contains(":") || (host.hasPrefix("[") && host.hasSuffix("]")) else { return false }
        if host.hasPrefix("[") {
            var address = in6_addr()
            guard host.hasSuffix("]"), String(host.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        }
        return scheme == "https" || ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased())
    }
}
#endif
