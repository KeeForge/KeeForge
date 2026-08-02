@preconcurrency import AuthenticationServices
import Foundation
import OSLog
import PublicSuffixList

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

#if DEBUG
/// Which channel supplied an enumeration result. DEBUG-only developer-tooling
/// signal for the AutoFill store inspector; production maintenance never
/// branches on it. Raw values match the inspector's `autofill-inspector.source`
/// accessibility value.
enum CredentialIdentitySource: String, Sendable, Hashable {
    /// The enumeration API served the rows (the normal path), or everything was
    /// empty, or enumeration was unavailable (`nil`).
    case api = "api"
    /// The API returned an empty list but the backing `Identities.db` had rows —
    /// the simulator-enumeration-bug fallback (see
    /// `AutoFillIdentitiesDatabaseReader`).
    case fallbackDB = "fallback-db"
}

/// Pure selection helper shared by the seam and its unit tests: given the
/// enumeration API's result, decide whether to serve it or the reconstructed
/// fallback rows. The API always wins when it is non-`nil` and non-empty (and a
/// `nil` result — enumeration unavailable — is passed through as `.api`); only
/// an *empty, non-`nil`* API result yields to a non-empty fallback.
enum CredentialIdentityFallback {
    static func resolve(
        apiIdentities: [any ASCredentialIdentity]?,
        fallback: () -> [any ASCredentialIdentity]
    ) -> (identities: [any ASCredentialIdentity]?, source: CredentialIdentitySource) {
        guard let apiIdentities, apiIdentities.isEmpty else {
            return (apiIdentities, .api)
        }
        let reconstructed = fallback()
        return reconstructed.isEmpty ? (apiIdentities, .api) : (reconstructed, .fallbackDB)
    }
}
#endif

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
    ///
    /// In DEBUG simulator builds this transparently substitutes the backing-DB
    /// fallback when the enumeration API returns empty (see
    /// `credentialIdentitiesWithSource()`), so the app's own store maintenance
    /// behaves device-equivalently on simulators. On device / Release it is the
    /// raw API result.
    func credentialIdentities() async -> [any ASCredentialIdentity]?

    #if DEBUG
    /// Like `credentialIdentities()` but also reports whether the result came
    /// from the enumeration API or the simulator DB fallback. Used only by the
    /// DEBUG store inspector to surface `autofill-inspector.source`; production
    /// maintenance uses `credentialIdentities()`.
    func credentialIdentitiesWithSource() async
        -> (identities: [any ASCredentialIdentity]?, source: CredentialIdentitySource)
    #endif
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
        #if DEBUG
        return await credentialIdentitiesWithSource().identities
        #else
        guard #available(iOS 17.4, macOS 14.4, *) else { return nil }
        return await ASCredentialIdentityStore.shared.credentialIdentities(forService: nil)
        #endif
    }

    #if DEBUG
    func credentialIdentitiesWithSource() async
        -> (identities: [any ASCredentialIdentity]?, source: CredentialIdentitySource) {
        guard #available(iOS 17.4, macOS 14.4, *) else { return (nil, .api) }
        let apiIdentities = await ASCredentialIdentityStore.shared.credentialIdentities(forService: nil)
        #if targetEnvironment(simulator)
        // Simulator enumeration bug: the API returns empty despite persisted
        // writes. Substitute the reconstructed backing-DB rows when the API is
        // empty so `populate` / `removeIdentities(forDatabase:)` see the real
        // store, exactly as they would on a device.
        let reconstructed: [any ASCredentialIdentity] = apiIdentities.isEmpty
            ? await AutoFillIdentitiesDatabaseReader().reconstructedIdentities()
            : []
        return CredentialIdentityFallback.resolve(apiIdentities: apiIdentities) { reconstructed }
        #else
        return (apiIdentities, .api)
        #endif
    }
    #endif
}

// MARK: - Manager

#if DEBUG
private final class CredentialIdentityStoreOverrideStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any CredentialIdentityStoreProviding)?
    private var populateObserver: ((UUID, [KPEntry]) -> Void)?
    private var clearObserver: (() -> Void)?
    private var removeDatabaseObserver: ((UUID, Bool) -> Void)?
    private var removeIdentityObserver: ((String) -> Void)?

    func get() -> (any CredentialIdentityStoreProviding)? {
        lock.withLock { value }
    }

    func set(_ value: (any CredentialIdentityStoreProviding)?) {
        lock.withLock { self.value = value }
    }

    func getPopulateObserver() -> ((UUID, [KPEntry]) -> Void)? {
        lock.withLock { populateObserver }
    }

    func setPopulateObserver(_ observer: ((UUID, [KPEntry]) -> Void)?) {
        lock.withLock { populateObserver = observer }
    }

    func getClearObserver() -> (() -> Void)? {
        lock.withLock { clearObserver }
    }

    func setClearObserver(_ observer: (() -> Void)?) {
        lock.withLock { clearObserver = observer }
    }

    func getRemoveDatabaseObserver() -> ((UUID, Bool) -> Void)? {
        lock.withLock { removeDatabaseObserver }
    }

    func setRemoveDatabaseObserver(_ observer: ((UUID, Bool) -> Void)?) {
        lock.withLock { removeDatabaseObserver = observer }
    }

    func getRemoveIdentityObserver() -> ((String) -> Void)? {
        lock.withLock { removeIdentityObserver }
    }

    func setRemoveIdentityObserver(_ observer: ((String) -> Void)?) {
        lock.withLock { removeIdentityObserver = observer }
    }
}

private final class CredentialIdentityStoreObserverCallback: @unchecked Sendable {
    private let body: @MainActor () -> Void

    init(body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor
    func invoke() {
        body()
    }
}
#endif

/// ASCredentialIdentityStore has no documented transaction boundary around
/// enumerate-then-mutate sequences. A single worker keeps every mutation,
/// including its enumeration snapshot, off the main actor and in invocation
/// order without holding a lock across an async system call.
private final class CredentialIdentityStoreMutationQueue: @unchecked Sendable {
    private typealias Operation = @Sendable () async -> Void
    private let lock = NSLock()
    private var pending: [Operation] = []
    private var isDraining = false

    /// Synchronously admits work so call order is established before any
    /// asynchronous execution can begin. One worker drains the queue instead
    /// of retaining a task chain for every pending operation.
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let shouldStartWorker = lock.withLock {
            pending.append(operation)
            guard !isDraining else { return false }
            isDraining = true
            return true
        }

        if shouldStartWorker {
            Task.detached { [self] in
                await drain()
            }
        }
    }

    private func drain() async {
        while let operation = lock.withLock({ () -> Operation? in
            guard !pending.isEmpty else {
                isDraining = false
                return nil
            }
            return pending.removeFirst()
        }) {
            await operation()
        }
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard isDraining else { return true }
                pending.append {
                    continuation.resume()
                }
                return false
            }

            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

enum CredentialIdentityStoreManager: Sendable {
    private static let logger = Logger(subsystem: "KeeForge", category: "CredentialIdentityStore")
    private static let mutationQueue = CredentialIdentityStoreMutationQueue()

    #if DEBUG
    private static let storeProviderOverrideStorage = CredentialIdentityStoreOverrideStorage()
    private static let observerCallbackQueue = CredentialIdentityStoreMutationQueue()
    #endif

    #if DEBUG
    /// Test hooks, fired on the main actor when the corresponding operation
    /// is invoked (fire-and-forget, before the async store work completes).
    /// `populateObserver` receives the owning database id and the eligible
    /// (non-expired) entries per refresh; `removeDatabaseObserver` receives
    /// the database id passed to targeted removal together with the
    /// `includingLegacyIdentifiers` flag it was invoked with.
    @MainActor static var populateObserver: ((UUID, [KPEntry]) -> Void)? {
        get { storeProviderOverrideStorage.getPopulateObserver() }
        set { storeProviderOverrideStorage.setPopulateObserver(newValue) }
    }
    @MainActor static var clearObserver: (() -> Void)? {
        get { storeProviderOverrideStorage.getClearObserver() }
        set { storeProviderOverrideStorage.setClearObserver(newValue) }
    }
    @MainActor static var removeDatabaseObserver: ((UUID, Bool) -> Void)? {
        get { storeProviderOverrideStorage.getRemoveDatabaseObserver() }
        set { storeProviderOverrideStorage.setRemoveDatabaseObserver(newValue) }
    }
    /// Fires with the exact record-identifier string passed to
    /// `removeIdentity(withRecordIdentifier:)`.
    @MainActor static var removeIdentityObserver: ((String) -> Void)? {
        get { storeProviderOverrideStorage.getRemoveIdentityObserver() }
        set { storeProviderOverrideStorage.setRemoveIdentityObserver(newValue) }
    }
    /// Test seam: when non-nil, every operation runs against this store
    /// instead of the system one. Reset to nil in setUp/tearDown.
    @MainActor static var storeProviderOverride: (any CredentialIdentityStoreProviding)? {
        get { storeProviderOverrideStorage.get() }
        set { storeProviderOverrideStorage.set(newValue) }
    }
    #endif

    private static func currentStore() -> any CredentialIdentityStoreProviding {
        #if DEBUG
        // Capture the lock-backed seam synchronously before enqueueing work.
        if let override = storeProviderOverrideStorage.get() {
            return override
        }
        #endif
        return SystemCredentialIdentityStore()
    }
    private static func enqueueMutation(
        _ operation: @escaping @Sendable (any CredentialIdentityStoreProviding) async -> Void
    ) {
        let store = currentStore()
        mutationQueue.enqueue {
            await operation(store)
        }
    }

    #if DEBUG
    /// Test-only barrier for the process-wide mutation queue.
    static func waitForPendingMutations() async {
        await mutationQueue.waitUntilDrained()
        await observerCallbackQueue.waitUntilDrained()
    }
    #endif

    /// Publishes `entries` as the credential identities of the database with
    /// id `databaseID` (the owning `DatabaseReference.id`). Since slice 04 of
    /// the selectable-AutoFill epic this is a **per-database refresh**, not a
    /// whole-store replace: other enabled databases' identities survive, so
    /// QuickType aggregates suggestions across every enabled database.
    ///
    /// Refresh decision tree:
    /// 1. Enumerate the store.
    /// 2. If enumeration is unavailable (`credentialIdentities()` returns
    ///    nil — macOS 14.0–14.3), or it shows no other database's identities
    ///    (a `.current` tag owned by a different database) and no identity
    ///    lacks a readable runtime `recordIdentifier`, do an atomic whole-store
    ///    `replaceCredentialIdentities` exactly as before aggregation
    ///    (`removeAllCredentialIdentities` when this database has no eligible
    ///    identities). With no other publishers this is equivalent to a
    ///    per-database refresh, and the full replace also purges legacy
    ///    (bare-UUID) and unrecognized identifiers.
    /// 3. If enumeration contains an identity without a readable runtime
    ///    `recordIdentifier`, use the conservative additive path so that
    ///    unknown system identities are never deleted by this refresh.
    /// 4. Otherwise remove the identities this database owns **plus** every
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
    /// The queue serializes calls within this process only. The main app and
    /// extension are separate processes and can still mutate the system store
    /// concurrently (unlock vs. in-extension save); enumerate-then-mutate is
    /// not atomic across that boundary. Worst case is a briefly stale or
    /// duplicate suggestion, corrected by the affected database's next
    /// refresh; no IPC or cross-process lock is layered on top.
    static func populate(with entries: [KPEntry], for databaseID: UUID) {
        let eligibleEntries = entries.filter { !$0.isExpired() }
        #if DEBUG
        let observer = storeProviderOverrideStorage.getPopulateObserver()
        if let observer {
            let callback = CredentialIdentityStoreObserverCallback {
                observer(databaseID, eligibleEntries)
            }
            observerCallbackQueue.enqueue {
                await MainActor.run {
                    callback.invoke()
                }
            }
        }
        #endif

        enqueueMutation { store in
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
                let otcIds = eligibleEntries.flatMap { oneTimeCodeIdentities(for: $0, in: databaseID) }
                databaseIdentities.append(contentsOf: otcIds)
                otcCount = otcIds.count
            }

            let storedIdentities = await store.credentialIdentities()
            let otherDatabaseIdentitiesPresent = storedIdentities?.contains { identity in
                guard let recordIdentifier = recordIdentifier(of: identity),
                      case .current(let parsed) = CredentialRecordIdentifier.parse(recordIdentifier)
                else { return false }
                return parsed.databaseID != databaseID
            } ?? false
            let unattributedIdentitiesPresent = storedIdentities?.contains {
                recordIdentifier(of: $0) == nil
            } ?? false

            do {
                if unattributedIdentitiesPresent {
                    logger.warning("Credential identity refresh preserved system identities without readable record identifiers")
                }
                if let storedIdentities, otherDatabaseIdentitiesPresent || unattributedIdentitiesPresent {
                    // Additive per-database refresh: drop this database's own
                    // (possibly stale) identities plus every legacy bare-UUID
                    // identity, then save the current set. `.unrecognized`
                    // identifiers are left for a later whole-store replace or
                    // `clearStore()` to purge.
                    let identitiesToRemove = storedIdentities.filter { identity in
                        guard let recordIdentifier = recordIdentifier(of: identity) else { return false }
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
        let observer = storeProviderOverrideStorage.getClearObserver()
        if let observer {
            let callback = CredentialIdentityStoreObserverCallback {
                observer()
            }
            observerCallbackQueue.enqueue {
                await MainActor.run {
                    callback.invoke()
                }
            }
        }
        #endif

        enqueueMutation { store in
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
    static func removeIdentities(for entries: [KPEntry], in databaseID: UUID) {
        enqueueMutation { store in
            guard await store.isEnabled() else { return }

            let passwordIds = entries.flatMap { passwordIdentities(for: $0, in: databaseID) }
            let passkeyIds = entries.compactMap { passkeyIdentity(for: $0, in: databaseID) }

            var identitiesToRemove: [any ASCredentialIdentity] = passwordIds
            identitiesToRemove.append(contentsOf: passkeyIds)
            if #available(iOS 18.0, macOS 15.0, *) {
                identitiesToRemove.append(contentsOf: entries.flatMap {
                    oneTimeCodeIdentities(for: $0, in: databaseID)
                })
            }
            guard !identitiesToRemove.isEmpty else { return }

            do {
                try await store.removeCredentialIdentities(identitiesToRemove)
                logger.info("Removed credential identities for entries")
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
        let observer = storeProviderOverrideStorage.getRemoveDatabaseObserver()
        if let observer {
            let callback = CredentialIdentityStoreObserverCallback {
                observer(databaseID, includingLegacyIdentifiers)
            }
            observerCallbackQueue.enqueue {
                await MainActor.run {
                    callback.invoke()
                }
            }
        }
        #endif

        enqueueMutation { store in
            guard await store.isEnabled() else {
                logger.info("Identity store is not enabled; skipping targeted removal")
                return
            }

            guard let storedIdentities = await store.credentialIdentities() else {
                logger.error("Identity-store enumeration unavailable on this OS; targeted removal skipped")
                return
            }

            let identitiesToRemove = storedIdentities.filter { identity in
                guard let recordIdentifier = recordIdentifier(of: identity) else { return false }
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
        let observer = storeProviderOverrideStorage.getRemoveIdentityObserver()
        if let observer {
            let callback = CredentialIdentityStoreObserverCallback {
                observer(recordIdentifier)
            }
            observerCallbackQueue.enqueue {
                await MainActor.run {
                    callback.invoke()
                }
            }
        }
        #endif

        enqueueMutation { store in
            guard await store.isEnabled() else {
                logger.info("Identity store is not enabled; skipping single-identity removal")
                return
            }

            guard let storedIdentities = await store.credentialIdentities() else {
                logger.error("Identity-store enumeration unavailable on this OS; single-identity removal skipped")
                return
            }

            let identitiesToRemove = storedIdentities.filter {
                Self.recordIdentifier(of: $0) == recordIdentifier
            }
            guard !identitiesToRemove.isEmpty else { return }

            do {
                try await store.removeCredentialIdentities(identitiesToRemove)
                logger.info("Removed \(identitiesToRemove.count) stale credential identities for one record identifier")
            } catch {
                logger.error("Failed to remove credential identities: \(error.localizedDescription)")
            }
        }
    }

    /// Some macOS releases return private `SFPasswordCredentialIdentity`
    /// instances from enumeration. They can conform to the public protocol
    /// while omitting its newer Objective-C accessor at runtime. Check the
    /// selector before dispatching through the Swift property.
    static func recordIdentifier(of identity: any ASCredentialIdentity) -> String? {
        guard let object = identity as? NSObject,
              object.responds(to: Selector(("recordIdentifier"))) else {
            return nil
        }
        return identity.recordIdentifier
    }

    // MARK: - One-time code identities

    @available(iOS 18.0, macOS 15.0, *)
    static func oneTimeCodeIdentities(for entry: KPEntry, in databaseID: UUID) -> [ASOneTimeCodeCredentialIdentity] {
        guard entry.hasTOTP else { return [] }

        let allURLs = [entry.url] + entry.additionalURLs
        var seenHosts = Set<String>()
        let hosts = allURLs.compactMap(otpHostFromURLString).filter { seenHosts.insert($0).inserted }

        let label = entry.title.isEmpty ? entry.username : entry.title
        guard !label.isEmpty else { return [] }

        let recordIdentifier = CredentialRecordIdentifier(databaseID: databaseID, entryID: entry.id).encoded
        return hosts.map { host in
            ASOneTimeCodeCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                label: label,
                recordIdentifier: recordIdentifier
            )
        }
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

    /// The exact request host, so an OTP field on `vt.example.com` is not
    /// answered with every entry under `example.com`. Non-web schemes carry no
    /// web host and are dropped rather than coerced into one — notably
    /// `otpauth://`, whose `totp` authority is not a domain.
    ///
    /// Normalization goes through `CredentialMatcher`, so a published host is
    /// always the one the matcher recomputes from the same stored URL.
    private static func otpHostFromURLString(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Retry on a missing host, not a missing scheme: `example.com:8080`
        // parses with `example.com` as its scheme and no host at all.
        let parsedURL = URL(string: trimmed)
        let url = parsedURL?.host == nil ? URL(string: "https://\(trimmed)") : parsedURL

        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host
        else { return nil }

        // The public-suffix lookup does not tolerate a fully-qualified
        // trailing dot, so strip it before validating.
        var host = rawHost
        while host.hasSuffix(".") { host.removeLast() }
        guard registeredDomain(from: host) != nil else { return nil }

        return CredentialMatcher.hostFromURLString(host)
    }

    // MARK: - Registered domain extraction

    /// Extracts the registered domain (eTLD+1) from a host string.
    /// Returns nil for IP addresses, localhost, and single-label hosts.
    static func registeredDomain(from host: String) -> String? {
        let lowered = host.lowercased()
        if lowered.contains(":") { return nil }

        let labels = lowered.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }

        return PublicSuffixList.effectiveTLDPlusOne(lowered)
    }
}
