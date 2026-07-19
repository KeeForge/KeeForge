@preconcurrency import AuthenticationServices
import OSLog

// MARK: - Record identifier

/// The record identifier KeeForge attaches to every credential identity it
/// publishes to the system credential identity store — password, passkey, and
/// one-time-code identities alike. This type is the ONLY place the identifier
/// format is encoded or parsed; every call site (publication, targeted
/// removal, and the extension's entry lookup) goes through it.
///
/// Wire format (current, version `v2`):
///
///     v2:<database-uuid>:<entry-uuid>
///
/// A colon-joined, version-prefixed compact string (KeePassium-style, not
/// JSON) where `<database-uuid>` is the owning `DatabaseReference.id` and
/// `<entry-uuid>` is the KeePass entry's UUID, both in `UUID.uuidString`
/// form. A colon can never appear inside a UUID string, so the join is
/// unambiguous. Parsing classifies three shapes:
///
/// - `.current` — the tagged `v2:` format above.
/// - `.legacy` — a bare entry UUID, published by pre-feature builds
///   (implicitly "v1"). It means "entry in the active AutoFill database" and
///   keeps pre-update QuickType suggestions filling until the next full-store
///   refresh replaces them with tagged identities.
/// - `.unrecognized` — anything else (garbage, unknown version prefix,
///   truncated or malformed fields); treated as stale, so callers fall back
///   to their existing not-found / interactive paths.
struct CredentialRecordIdentifier: Hashable, Sendable {
    /// `DatabaseReference.id` of the database that owns the entry.
    let databaseID: UUID
    /// UUID of the KeePass entry inside that database.
    let entryID: UUID

    private static let versionPrefix = "v2"
    private static let separator: Character = ":"

    /// The string stored in `ASCredentialIdentity.recordIdentifier`.
    var encoded: String {
        "\(Self.versionPrefix)\(Self.separator)\(databaseID.uuidString)\(Self.separator)\(entryID.uuidString)"
    }

    /// Classification of a record identifier read back from the system store.
    enum ParseResult: Hashable, Sendable {
        case current(CredentialRecordIdentifier)
        case legacy(entryID: UUID)
        case unrecognized

        /// The entry UUID for both resolvable formats; `nil` for stale strings.
        var entryID: UUID? {
            switch self {
            case .current(let identifier): identifier.entryID
            case .legacy(let entryID): entryID
            case .unrecognized: nil
            }
        }

        /// The owning database for the current format only. Legacy
        /// identifiers carry no attribution — whether they belong to a given
        /// database (via the active pointer) is the caller's decision.
        var databaseID: UUID? {
            switch self {
            case .current(let identifier): identifier.databaseID
            case .legacy, .unrecognized: nil
            }
        }
    }

    static func parse(_ rawValue: String) -> ParseResult {
        if let bareEntryID = UUID(uuidString: rawValue) {
            return .legacy(entryID: bareEntryID)
        }

        let parts = rawValue.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 3,
              String(parts[0]) == versionPrefix,
              let databaseID = UUID(uuidString: String(parts[1])),
              let entryID = UUID(uuidString: String(parts[2]))
        else {
            return .unrecognized
        }

        return .current(CredentialRecordIdentifier(databaseID: databaseID, entryID: entryID))
    }
}

// MARK: - Store seam

/// Abstraction over the `ASCredentialIdentityStore` operations
/// `CredentialIdentityStoreManager` uses, so unit tests can drive the
/// populate / enumerate / filter / remove logic against an in-memory fake
/// (an `actor` conformance satisfies the async requirements naturally).
/// Production uses `SystemCredentialIdentityStore`, and tests swap the store
/// via `CredentialIdentityStoreManager.storeProviderOverride`.
protocol CredentialIdentityStoreProviding: Sendable {
    /// Mirrors `ASCredentialIdentityStore.state().isEnabled`: whether the
    /// user has enabled this provider in the system AutoFill settings.
    func isEnabled() async -> Bool
    func replaceCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws
    func saveCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws
    func removeCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws
    func removeAllCredentialIdentities() async throws
    /// Every identity this app has published, or `nil` where store
    /// enumeration is unavailable:
    /// `credentialIdentities(forService:credentialIdentityTypes:)` needs
    /// iOS 17.4 / macOS 14.4, and within KeeForge's deployment targets
    /// (iOS 18.0, macOS 14.0) only macOS 14.0–14.3 falls short.
    func credentialIdentities() async -> [any ASCredentialIdentity]?
}

/// Production conformance wrapping `ASCredentialIdentityStore.shared`.
struct SystemCredentialIdentityStore: CredentialIdentityStoreProviding {
    func isEnabled() async -> Bool {
        await ASCredentialIdentityStore.shared.state().isEnabled
    }

    func replaceCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    func saveCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        try await ASCredentialIdentityStore.shared.saveCredentialIdentities(identities)
    }

    func removeCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        try await ASCredentialIdentityStore.shared.removeCredentialIdentities(identities)
    }

    func removeAllCredentialIdentities() async throws {
        try await ASCredentialIdentityStore.shared.removeAllCredentialIdentities()
    }

    func credentialIdentities() async -> [any ASCredentialIdentity]? {
        guard #available(iOS 17.4, macOS 14.4, *) else { return nil }
        return await ASCredentialIdentityStore.shared.credentialIdentities(forService: nil)
    }
}

// MARK: - Manager

enum CredentialIdentityStoreManager: Sendable {
    private static let logger = Logger(subsystem: "KeeForge", category: "CredentialIdentityStore")

    #if DEBUG
    /// Test hooks, fired on the main actor when the corresponding operation
    /// is invoked (fire-and-forget, before the async store work completes).
    /// `populateObserver` receives the owning database id and the eligible
    /// (non-expired) entries per refresh; `removeDatabaseObserver` receives
    /// the database id passed to targeted removal together with the
    /// `includingLegacyIdentifiers` flag it was invoked with.
    @MainActor static var populateObserver: ((UUID, [KPEntry]) -> Void)?
    @MainActor static var clearObserver: (() -> Void)?
    @MainActor static var removeDatabaseObserver: ((UUID, Bool) -> Void)?
    /// Fires with the exact record-identifier string passed to
    /// `removeIdentity(withRecordIdentifier:)`.
    @MainActor static var removeIdentityObserver: ((String) -> Void)?
    /// Test seam: when non-nil, every operation runs against this store
    /// instead of the system one. Reset to nil in setUp/tearDown.
    @MainActor static var storeProviderOverride: (any CredentialIdentityStoreProviding)?
    #endif

    private static func currentStore() async -> any CredentialIdentityStoreProviding {
        #if DEBUG
        if let override = await MainActor.run(body: { storeProviderOverride }) {
            return override
        }
        #endif
        return SystemCredentialIdentityStore()
    }

    /// Publishes `entries` as the credential identities of the database with
    /// id `databaseID` (the owning `DatabaseReference.id`). Since slice 04 of
    /// the selectable-AutoFill epic this is a **per-database refresh**, not a
    /// whole-store replace: other enabled databases' identities survive, so
    /// QuickType aggregates suggestions across every enabled database.
    ///
    /// Refresh decision tree:
    /// 1. Enumerate the store.
    /// 2. If enumeration is unavailable (`credentialIdentities()` returns
    ///    nil — macOS 14.0–14.3) **or** it shows no other database's
    ///    identities (a `.current` tag owned by a different database), do an
    ///    atomic whole-store `replaceCredentialIdentities` exactly as before
    ///    aggregation (`removeAllCredentialIdentities` when this database has
    ///    no eligible identities). With no other publishers this is
    ///    equivalent to a per-database refresh, and the full replace also
    ///    purges legacy (bare-UUID) and unrecognized identifiers.
    /// 3. Otherwise remove the identities this database owns **plus** every
    ///    legacy-format identity (pre-tagging publications, only ever made by
    ///    the then-active database and superseded by this refresh), then
    ///    additively `saveCredentialIdentities` the current set. When the
    ///    current set is empty only the removal happens — other databases'
    ///    identities are kept, never wiped.
    ///
    /// Because each refresh first drops the database's own stale identities,
    /// a deleted entry can never linger past its database's next refresh; no
    /// Strongbox-style periodic full clear is needed.
    ///
    /// macOS 14.0–14.3 consequence of step 2's fallback: without enumeration
    /// every refresh is a full replace, so other databases' suggestions
    /// vanish until their next unlock repopulates them (KeePassium-style lazy
    /// repopulation — the pre-aggregation single-active behavior, and the
    /// only option without an enumeration API).
    ///
    /// Accepted cross-process race (see the epic's cross-slice notes): the
    /// main app and the extension can both mutate the store (unlock vs.
    /// in-extension save), and enumerate-then-mutate is not atomic. Worst
    /// case is a briefly stale or duplicate suggestion, corrected by the
    /// affected database's next refresh; no IPC or locking is layered on top.
    static func populate(with entries: [KPEntry], for databaseID: UUID) {
        let eligibleEntries = entries.filter { !$0.isExpired() }

        #if DEBUG
        Task { @MainActor in
            populateObserver?(databaseID, eligibleEntries)
        }
        #endif

        Task {
            let store = await currentStore()
            guard await store.isEnabled() else {
                logger.info("Identity store is not enabled; skipping populate")
                return
            }

            let passwordIds = eligibleEntries.flatMap { passwordIdentities(for: $0, in: databaseID) }
            let passkeyIds = eligibleEntries.compactMap { passkeyIdentity(for: $0, in: databaseID) }

            var databaseIdentities: [any ASCredentialIdentity] = passwordIds
            databaseIdentities.append(contentsOf: passkeyIds)

            var otcCount = 0
            if #available(iOS 18.0, macOS 15.0, *) {
                let otcIds = eligibleEntries.compactMap { oneTimeCodeIdentity(for: $0, in: databaseID) }
                databaseIdentities.append(contentsOf: otcIds)
                otcCount = otcIds.count
            }

            let storedIdentities = await store.credentialIdentities()
            let otherDatabaseIdentitiesPresent = storedIdentities?.contains { identity in
                guard let recordIdentifier = identity.recordIdentifier,
                      case .current(let parsed) = CredentialRecordIdentifier.parse(recordIdentifier)
                else { return false }
                return parsed.databaseID != databaseID
            } ?? false

            do {
                if let storedIdentities, otherDatabaseIdentitiesPresent {
                    // Additive per-database refresh: drop this database's own
                    // (possibly stale) identities plus every legacy bare-UUID
                    // identity, then save the current set. `.unrecognized`
                    // identifiers are left for a later whole-store replace or
                    // `clearStore()` to purge.
                    let identitiesToRemove = storedIdentities.filter { identity in
                        guard let recordIdentifier = identity.recordIdentifier else { return false }
                        switch CredentialRecordIdentifier.parse(recordIdentifier) {
                        case .current(let parsed):
                            return parsed.databaseID == databaseID
                        case .legacy:
                            return true
                        case .unrecognized:
                            return false
                        }
                    }
                    if !identitiesToRemove.isEmpty {
                        try await store.removeCredentialIdentities(identitiesToRemove)
                    }
                    if !databaseIdentities.isEmpty {
                        try await store.saveCredentialIdentities(databaseIdentities)
                    }
                    logger.info("Refreshed one database's identities: removed \(identitiesToRemove.count) stale, saved \(passwordIds.count) password + \(passkeyIds.count) passkey + \(otcCount) OTC identities")
                } else if databaseIdentities.isEmpty {
                    try await store.removeAllCredentialIdentities()
                    logger.info("Cleared identity store because no eligible credentials remain")
                } else {
                    try await store.replaceCredentialIdentities(databaseIdentities)
                    logger.info("Populated identity store with \(passwordIds.count) password + \(passkeyIds.count) passkey + \(otcCount) OTC identities")
                }
            } catch {
                logger.error("Failed to refresh credential identities: \(error.localizedDescription)")
            }
        }
    }

    /// Wipe-everything primitive: empties the entire identity store (global
    /// Quick AutoFill toggle off, the extension's stale legacy/unrecognized-
    /// identifier cleanup, and the Clear AutoFill Entries action).
    static func clearStore() {
        #if DEBUG
        Task { @MainActor in
            clearObserver?()
        }
        #endif

        Task {
            let store = await currentStore()
            guard await store.isEnabled() else { return }

            do {
                try await store.removeAllCredentialIdentities()
                logger.info("Cleared all credential identities")
            } catch {
                logger.error("Failed to clear credential identities: \(error.localizedDescription)")
            }
        }
    }

    /// Removes the identities that `populate` would publish for `entries`.
    ///
    /// Callers must pass the id of the database the entries live in.
    /// `removeCredentialIdentities(_:)`'s matching semantics are not formally
    /// documented by Apple (empirically, password identities are keyed on
    /// service identifier + user), so the only contract-safe approach is to
    /// rebuild the identities byte-identical to what was published —
    /// including the database-tagged record identifier — and every caller of
    /// this API has the open database at hand, so the id costs nothing.
    /// One-time-code identities are intentionally not rebuilt here (matching
    /// today's behavior); they are cleaned up by the owning database's next
    /// full-store refresh.
    static func removeIdentities(for entries: [KPEntry], in databaseID: UUID) {
        Task {
            let store = await currentStore()
            guard await store.isEnabled() else { return }

            let passwordIds = entries.flatMap { passwordIdentities(for: $0, in: databaseID) }
            let passkeyIds = entries.compactMap { passkeyIdentity(for: $0, in: databaseID) }

            var identitiesToRemove: [any ASCredentialIdentity] = passwordIds
            identitiesToRemove.append(contentsOf: passkeyIds)
            guard !identitiesToRemove.isEmpty else { return }

            do {
                try await store.removeCredentialIdentities(identitiesToRemove)
            } catch {
                logger.error("Failed to remove credential identities: \(error.localizedDescription)")
            }
        }
    }

    /// Targeted per-database removal: enumerates the system store and removes
    /// exactly the identities whose record identifier is tagged with
    /// `databaseID`. Works with every database locked — enumeration reads
    /// only the OS-managed store; no entry data or decryption is involved.
    ///
    /// Legacy bare-UUID identifiers carry no database attribution, so they
    /// are skipped by default; pass `includingLegacyIdentifiers: true` when
    /// the caller knows the store's legacy identities belong to `databaseID`
    /// (they can only have been published by the active database — e.g.
    /// slice 04's per-database refresh, or disabling the active database).
    /// `.unrecognized` (stale) identifiers are left untouched; a later
    /// whole-store replace (a refresh that finds no other database's
    /// identities, or `clearStore()`) purges them.
    ///
    /// On macOS 14.0–14.3 store enumeration is unavailable
    /// (`credentialIdentities()` returns nil); this logs and removes nothing,
    /// so callers needing a hard guarantee there must fall back to
    /// `clearStore()` + lazy repopulation. The slice 04 lifecycle callers
    /// (`DatabaseListStore.setAutoFillEnabled` / `remove(id:)`) deliberately
    /// do not: on that OS every `populate` is a whole-store replace anyway,
    /// so a disabled/removed database's stale suggestions linger only until
    /// any enabled database's next refresh, and the extension already treats
    /// them as stale on tap.
    static func removeIdentities(forDatabase databaseID: UUID, includingLegacyIdentifiers: Bool = false) {
        #if DEBUG
        Task { @MainActor in
            removeDatabaseObserver?(databaseID, includingLegacyIdentifiers)
        }
        #endif

        Task {
            let store = await currentStore()
            guard await store.isEnabled() else {
                logger.info("Identity store is not enabled; skipping targeted removal")
                return
            }

            guard let storedIdentities = await store.credentialIdentities() else {
                logger.error("Identity-store enumeration unavailable on this OS; targeted removal skipped")
                return
            }

            let identitiesToRemove = storedIdentities.filter { identity in
                guard let recordIdentifier = identity.recordIdentifier else { return false }
                switch CredentialRecordIdentifier.parse(recordIdentifier) {
                case .current(let parsed):
                    return parsed.databaseID == databaseID
                case .legacy:
                    return includingLegacyIdentifiers
                case .unrecognized:
                    return false
                }
            }

            guard !identitiesToRemove.isEmpty else { return }

            do {
                try await store.removeCredentialIdentities(identitiesToRemove)
                logger.info("Removed \(identitiesToRemove.count) credential identities for one database")
            } catch {
                logger.error("Failed to remove credential identities: \(error.localizedDescription)")
            }
        }
    }

    /// Removes every published identity whose `recordIdentifier` equals the
    /// given string exactly. An entry publishes its password, passkey, and
    /// one-time-code identities under one identifier string, so this removes
    /// all suggestion types for exactly one entry — used by the extension when
    /// a tapped suggestion's entry no longer exists in its successfully
    /// unlocked database: the single stale suggestion disappears without
    /// touching the rest of the store.
    ///
    /// Like `removeIdentities(forDatabase:)` this works purely by store
    /// enumeration, so it needs no entry data and works while every database
    /// is locked. On macOS 14.0–14.3 (no enumeration API) it logs and removes
    /// nothing; the stale identity dies at the owning database's next
    /// full-store refresh instead.
    static func removeIdentity(withRecordIdentifier recordIdentifier: String) {
        #if DEBUG
        Task { @MainActor in
            removeIdentityObserver?(recordIdentifier)
        }
        #endif

        Task {
            let store = await currentStore()
            guard await store.isEnabled() else {
                logger.info("Identity store is not enabled; skipping single-identity removal")
                return
            }

            guard let storedIdentities = await store.credentialIdentities() else {
                logger.error("Identity-store enumeration unavailable on this OS; single-identity removal skipped")
                return
            }

            let identitiesToRemove = storedIdentities.filter { $0.recordIdentifier == recordIdentifier }
            guard !identitiesToRemove.isEmpty else { return }

            do {
                try await store.removeCredentialIdentities(identitiesToRemove)
                logger.info("Removed \(identitiesToRemove.count) stale credential identities for one record identifier")
            } catch {
                logger.error("Failed to remove credential identities: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - One-time code identities

    @available(iOS 18.0, macOS 15.0, *)
    static func oneTimeCodeIdentity(for entry: KPEntry, in databaseID: UUID) -> ASOneTimeCodeCredentialIdentity? {
        guard entry.hasTOTP else { return nil }

        let allURLs = [entry.url] + entry.additionalURLs
        let domain = allURLs.compactMap(domainFromURLString).first
        guard let domain else { return nil }

        let label = entry.title.isEmpty ? entry.username : entry.title
        guard !label.isEmpty else { return nil }

        let serviceIdentifier = ASCredentialServiceIdentifier(identifier: domain, type: .domain)
        return ASOneTimeCodeCredentialIdentity(
            serviceIdentifier: serviceIdentifier,
            label: label,
            recordIdentifier: CredentialRecordIdentifier(databaseID: databaseID, entryID: entry.id).encoded
        )
    }

    // MARK: - Passkey identities

    static func passkeyIdentity(for entry: KPEntry, in databaseID: UUID) -> ASPasskeyCredentialIdentity? {
        guard let passkey = entry.passkeyCredential,
              let credentialIDData = passkey.credentialIDData,
              let userHandleData = passkey.userHandleData
        else { return nil }

        let rpID = passkey.relyingParty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !rpID.isEmpty else { return nil }

        return ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: rpID,
            userName: passkey.username,
            credentialID: credentialIDData,
            userHandle: userHandleData,
            recordIdentifier: CredentialRecordIdentifier(databaseID: databaseID, entryID: entry.id).encoded
        )
    }

    static func normalizedRelyingPartyIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let host = CredentialMatcher.hostFromURLString(trimmed) ?? trimmed
        let lowered = host.lowercased()

        if lowered.hasPrefix("www.") {
            return String(lowered.dropFirst(4))
        }

        return lowered
    }

    // MARK: - Internal (visible to tests via @testable import)

    static func passwordIdentities(for entry: KPEntry, in databaseID: UUID) -> [ASPasswordCredentialIdentity] {
        let username = entry.username.isEmpty ? entry.title : entry.username
        guard !username.isEmpty else { return [] }
        guard entry.hasPassword else { return [] }

        let allURLs = [entry.url] + entry.additionalURLs
        let domains = Set(allURLs.compactMap(domainFromURLString))
        guard !domains.isEmpty else { return [] }

        return domains.sorted().map { domain in
            let serviceIdentifier = ASCredentialServiceIdentifier(identifier: domain, type: .domain)
            return ASPasswordCredentialIdentity(
                serviceIdentifier: serviceIdentifier,
                user: username,
                recordIdentifier: CredentialRecordIdentifier(databaseID: databaseID, entryID: entry.id).encoded
            )
        }
    }

    static func domainFromURLString(_ urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }

        let host: String?
        if let h = URL(string: urlString)?.host {
            host = h
        } else {
            host = URL(string: "https://\(urlString)")?.host
        }

        guard let host else { return nil }
        return registeredDomain(from: host)
    }

    // MARK: - Registered domain extraction

    /// Extracts the registered domain (eTLD+1) from a host string.
    /// Strips `www.` prefix and collapses subdomains to the base domain.
    /// Returns nil for IP addresses, localhost, and single-label hosts.
    static func registeredDomain(from host: String) -> String? {
        let lowered = host.lowercased()

        // Skip IPv6
        if lowered.contains(":") { return nil }

        let labels = lowered.split(separator: ".").map(String.init)

        // Skip single-label hosts (localhost, etc.)
        guard labels.count >= 2 else { return nil }

        // Skip IP addresses (all labels are numeric)
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }

        // Strip www prefix
        var effective = labels
        if effective.first == "www" {
            effective.removeFirst()
        }
        guard effective.count >= 2 else { return nil }

        // Check for known multi-part TLDs (co.uk, com.au, etc.)
        let lastTwo = effective.suffix(2).joined(separator: ".")
        if Self.knownMultiPartTLDs.contains(lastTwo) {
            guard effective.count >= 3 else { return nil }
            return effective.suffix(3).joined(separator: ".")
        }

        return effective.suffix(2).joined(separator: ".")
    }

    private static let knownMultiPartTLDs: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.au", "org.au", "net.au", "edu.au",
        "co.nz", "org.nz", "net.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp",
        "com.br", "org.br", "net.br",
        "co.in", "org.in", "net.in",
        "co.za", "org.za", "net.za",
        "com.mx", "org.mx",
        "co.kr", "or.kr",
        "com.cn", "org.cn", "net.cn",
        "com.tw", "org.tw", "net.tw",
        "co.il", "org.il",
        "com.sg", "org.sg",
        "com.hk", "org.hk",
        "co.th", "or.th",
        "com.tr", "org.tr",
        "com.ar", "org.ar",
        "co.id",
        "com.ph",
        "com.my",
        "com.ng",
        "co.ke",
    ]
}
