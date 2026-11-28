#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import SiteMatching

/// What the app's save alert shows for a login a browser proposes. Every
/// string came from the page or the vault, so it is shown only as plain text.
struct BrowserBridgeSaveProposal: Equatable, Sendable {
    struct Destination: Equatable, Sendable {
        let db: UUID
        let dbName: String
        let groupName: String
    }
    /// Never empty; the first is preselected.
    let destinations: [Destination]
    let title: String
    let host: String
    let username: String
}

enum BrowserBridgeSaveAnswer: Equatable, Sendable {
    case save(db: UUID)
    case declined
    /// Another save alert is already waiting for an answer.
    case busy
}

/// One connection's offers and authorization. Socket callers await this actor;
/// the main actor must never wait for their socket threads.
@MainActor
final class BrowserBridgeRequestHandler {
    typealias SessionsProvider = @MainActor () -> [DatabaseViewModel]
    /// Takes the session's gate and the prompt's reason; true only for a release the owner authorized.
    typealias DeviceOwnerAuthenticator = @MainActor (SecretAccessGate, _ reason: String) async -> Bool
    /// Asks the user whether to save a proposed login, and where. Cancelling the task withdraws the question.
    typealias SaveConfirmer = @MainActor (BrowserBridgeSaveProposal) async -> BrowserBridgeSaveAnswer
    typealias PasswordSource = @MainActor () async -> String

    /// `matches` fields the extension only displays are cut to this many characters.
    static let displayFieldLimit = 256
    /// `reveal` and `unlock` together: a burst of 3, then one per second.
    static let frontBurst = 3
    static let frontInterval: Duration = .seconds(1)
    /// `matches`: a burst of 10, then 5 per second.
    static let matchesBurst = 10
    static let matchesInterval: Duration = .milliseconds(200)
    /// Longer titles and hosts are cut in the device-owner prompt.
    static let promptFieldLimit = 64
    /// `generate`: a burst of 3, then one per second.
    static let generateBurst = 3
    static let generateInterval: Duration = .seconds(1)
    /// `save`: a burst of 3, then one per 12 seconds, and one at a time.
    static let saveBurst = 3
    static let saveInterval: Duration = .seconds(12)

    private struct Pair: Hashable {
        let entry: UUID
        let db: UUID
    }

    /// A GCRA allowance: `burst` requests at once, then one per `interval`.
    private struct Allowance {
        let burst: Int
        let interval: Duration
        /// When the allowance is next fully spent (GCRA's theoretical arrival time).
        private var due: ContinuousClock.Instant?

        init(burst: Int, interval: Duration) {
            self.burst = burst
            self.interval = interval
        }

        mutating func admit(at instant: ContinuousClock.Instant) -> Bool {
            let next = max(due ?? instant, instant)
            guard next - instant <= interval * (burst - 1) else { return false }
            due = next + interval
            return true
        }
    }

    private let sessionsProvider: SessionsProvider
    private let appVersion: String
    private let reveal: @MainActor (UUID, UUID) -> Void
    private let unlock: @MainActor (UUID?) -> Void
    private let authenticate: DeviceOwnerAuthenticator
    private let confirmSave: SaveConfirmer
    private let generatePassword: PasswordSource
    private let now: @MainActor () -> ContinuousClock.Instant
    private var offers: [String: Set<Pair>] = [:]
    private var origins: [String] = []
    private var activeIDs = Set<Int>()
    private var credentialInFlight = false
    private var credentialTimes: [ContinuousClock.Instant] = []
    private var fronts = Allowance(burst: frontBurst, interval: frontInterval)
    private var matchScans = Allowance(burst: matchesBurst, interval: matchesInterval)
    private var generations = Allowance(burst: generateBurst, interval: generateInterval)
    private var saves = Allowance(burst: saveBurst, interval: saveInterval)
    private var saveInFlight = false

    init(
        sessionsProvider: @escaping SessionsProvider,
        appVersion: String,
        reveal: @escaping @MainActor (UUID, UUID) -> Void = { _, _ in },
        unlock: @escaping @MainActor (UUID?) -> Void = { _ in },
        authenticateDeviceOwner: @escaping DeviceOwnerAuthenticator = BrowserBridgeRequestHandler.deviceOwnerGate,
        confirmSave: @escaping SaveConfirmer = { _ in .declined },
        generatePassword: @escaping PasswordSource = BrowserBridgeRequestHandler.generatedPassword,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.sessionsProvider = sessionsProvider
        self.appVersion = appVersion
        self.reveal = reveal
        self.unlock = unlock
        self.authenticate = authenticateDeviceOwner
        self.confirmSave = confirmSave
        self.generatePassword = generatePassword
        self.now = now
    }

    /// A password made with the generator settings the user chose in the app, off the main actor.
    static func generatedPassword() async -> String {
        let options = SettingsService.passwordGeneratorOptions
        return await Task.detached { PasswordGenerator.generate(options: options) }.value
    }

    /// Unlike Copy Password, a Mac that cannot authenticate its owner releases
    /// nothing outside the grace period: only a grant or a prompt authorizes.
    static func deviceOwnerGate(_ gate: SecretAccessGate, reason: String) async -> Bool {
        if gate.isWithinGracePeriod { return true }
        guard gate.canAuthenticateDeviceOwner else { return false }
        do {
            try await gate.authenticate(reason: reason)
            return true
        } catch { return false }
    }

    /// The device-owner prompt's reason for releasing `title` to `origin`, a
    /// valid origin. Both are sanitized like browser names and capped.
    static func fillReason(title: String, origin: String) -> String {
        let host = promptHost(origin)
        let title = String(BrowserPairingStore.sanitizedName(title).prefix(promptFieldLimit))
        return title.isEmpty
            ? String(localized: "Fill a login on \(host) in your browser")
            : String(localized: "Fill “\(title)” on \(host) in your browser")
    }

    /// The device-owner prompt's reason for saving a login for `origin`, a valid origin.
    static func saveReason(origin: String) -> String {
        String(localized: "Save a login for \(promptHost(origin)) from your browser")
    }

    /// The host as the site matcher compares it: lowercased, IDNs in punycode
    /// (`URLComponents` would decode them), no port, no leading `www.`. A long
    /// host keeps its end, where the registrable domain is.
    private static func promptHost(_ origin: String) -> String {
        let host = SiteHost(origin)?.name ?? origin
        guard host.count > promptFieldLimit else { return host }
        return "…" + host.suffix(promptFieldLimit - 1)
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
        case .reveal, .unlock: guard fronts.admit(at: now()) else { return reply(.failure(.rateLimited)) }
        case .matches: guard matchScans.admit(at: now()) else { return reply(.failure(.rateLimited)) }
        case .generate: guard generations.admit(at: now()) else { return reply(.failure(.rateLimited)) }
        case .save:
            guard !saveInFlight, saves.admit(at: now()) else { return reply(.failure(.rateLimited)) }
        default: break
        }
        let isSave: Bool
        if case .save = request.operation { isSave = true } else { isSave = false }
        if isSave { saveInFlight = true }
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
            if isSave { saveInFlight = false }
        }
        await Task.yield()
        guard !Task.isCancelled else { return reply(.failure(.badRequest)) }
        return reply(await perform(request.operation))
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
            let authorized = await authenticate(source.secretAccess, Self.fillReason(title: offered.title, origin: origin))
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
        case .generate(let origin):
            guard Self.validOrigin(origin) else { return .failure(.badOrigin) }
            // A password the user cannot save would lock them out of the new account.
            if let refusal = destinationRefusal() { return .failure(refusal) }
            let password = await generatePassword()
            guard !Task.isCancelled else { return .failure(.badRequest) }
            return .password(password)
        case .save(let origin, let username, let password):
            return await save(origin: origin, username: username, password: password)
        }
    }

    /// Why no open database can take a new login now, or nil when one can.
    private func destinationRefusal() -> BrowserBridgeRequestError? {
        let unlocked = sessionsProvider().filter(Self.isUnlocked)
        guard !unlocked.isEmpty else { return .locked }
        return unlocked.contains(where: Self.canTakeNewLogin) ? nil : .unavailable
    }

    /// Nothing is written unless the user picks Save in the app's alert and then
    /// passes the device-owner gate; the entry then goes through the session's normal save.
    private func save(origin: String, username: String, password: String) async -> BrowserBridgeReply.Result {
        guard Self.validOrigin(origin) else { return .failure(.badOrigin) }
        if let refusal = destinationRefusal() { return .failure(refusal) }
        guard !hasLogin(for: origin, username: username) else { return .failure(.exists) }
        let candidates = sessionsProvider().filter(Self.canTakeNewLogin)
            .sorted { ($0.databaseReference.lastOpenedAt ?? .distantPast) > ($1.databaseReference.lastOpenedAt ?? .distantPast) }
        let destinations = candidates.compactMap { session -> BrowserBridgeSaveProposal.Destination? in
            guard let root = session.currentRootGroup else { return nil }
            let group = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: session.databaseReference.autoFillDestinationGroupID)
            return .init(db: session.databaseReference.id,
                         dbName: Self.alertField(session.databaseReference.displayName),
                         groupName: Self.alertField(group.name))
        }
        guard !destinations.isEmpty else { return .failure(.unavailable) }
        let title = Self.entryTitle(origin)
        let proposal = BrowserBridgeSaveProposal(destinations: destinations, title: Self.alertField(title),
                                                 host: Self.promptHost(origin), username: Self.alertField(username))
        let answer = await confirmSave(proposal)
        guard !Task.isCancelled else { return .failure(.declined) }
        let db: UUID
        switch answer {
        case .save(let chosen) where destinations.contains(where: { $0.db == chosen }): db = chosen
        case .busy: return .failure(.rateLimited)
        case .save, .declined: return .failure(.declined)
        }
        guard let target = session(db), Self.canTakeNewLogin(target) else { return .failure(.locked) }
        let cycle = target.lockCycleID
        let authorized = await authenticate(target.secretAccess, Self.saveReason(origin: origin))
        guard session(db) === target, target.lockCycleID == cycle, Self.canTakeNewLogin(target) else { return .failure(.locked) }
        guard authorized, !Task.isCancelled else { return .failure(.denied) }
        guard !hasLogin(for: origin, username: username) else { return .failure(.exists) }
        guard let root = target.currentRootGroup else { return .failure(.locked) }
        let group = AutoFillSaveCoordinator.destinationGroup(in: root, preferredGroupID: target.databaseReference.autoFillDestinationGroupID)
        let draft = Self.newLoginDraft(origin: origin, username: username, password: password)
        // Once the user has confirmed, closing the connection must not interrupt the write.
        let outcome = await Task { @MainActor in try? await target.importEntries([draft], into: group.id) }.value
        return outcome == .saved ? .empty : .failure(.saveFailed)
    }

    /// Whether an unlocked database already holds a login for this site and user
    /// name; an empty user name matches any login for the site.
    private func hasLogin(for origin: String, username: String) -> Bool {
        let wanted = username.trimmingCharacters(in: .whitespacesAndNewlines)
        for session in sessionsProvider().filter(Self.isUnlocked) {
            guard session.databaseReference.autoFillEnabled, let root = session.currentRootGroup else { continue }
            for entry in root.autoFillEntries(excludingGroupID: root.recycleBinUUID) {
                let match = CredentialMatcher.interactiveMatches(from: [entry], for: [SiteRequest.url(origin)])
                guard !match.exact.isEmpty || !match.possible.isEmpty else { continue }
                let stored = (session.fieldReferenceResolution(of: entry.username).value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if wanted.isEmpty || stored.caseInsensitiveCompare(wanted) == .orderedSame { return true }
            }
        }
        return false
    }

    /// The new entry's title: the host, as the site matcher compares it.
    private static func entryTitle(_ origin: String) -> String {
        SiteHost(origin)?.name ?? origin
    }

    /// The entry a confirmed `save` adds: the site's host as title, the origin as URL, and the user name as the site received it.
    static func newLoginDraft(origin: String, username: String, password: String) -> EntryDraftPayload {
        EntryDraftPayload(title: entryTitle(origin), username: username, password: password, url: origin)
    }

    private static func alertField(_ value: String) -> String {
        BrowserPairingStore.sanitizedName(value)
    }

    private static func canTakeNewLogin(_ session: DatabaseViewModel) -> Bool {
        // A pending edit would be written along with the new login.
        isUnlocked(session) && session.databaseReference.autoFillEnabled && !session.isReadOnly
            && !session.isSaving && !session.isDirty && !session.hasUnsavedEditor && session.currentRootGroup != nil
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
        // Browsers serialize origins in ASCII, IDNs in punycode.
        guard !origin.isEmpty, origin.unicodeScalars.allSatisfy({ (0x21..<0x7F).contains($0.value) }),
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
