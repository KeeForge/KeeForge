// In-memory `CredentialIdentityStoreProviding` fake shared by the
// CredentialIdentityStoreManager / DatabaseListStore / DatabaseViewModel suites.
//
// Install it via `CredentialIdentityStoreManager.storeProviderOverride`
// (a `@MainActor` static — assign with `await MainActor.run { … }` from
// non-main contexts) and reset the override to nil in setUp/tearDown.
// The manager's operations are fire-and-forget `Task`s, so positive
// assertions await an expectation fulfilled from `onMutation`; negative
// assertions install an `XCTFail`-ing hook and sleep ~100 ms.
//
// A lock-guarded class is deliberately preferred over an actor: the
// protocol's `[any ASCredentialIdentity]` parameters are non-Sendable
// AuthenticationServices types, and a lock-based `@unchecked Sendable`
// class avoids sending them across an actor boundary.
@preconcurrency import AuthenticationServices
import Foundation
@testable import KeeForge

final class FakeCredentialIdentityStore: CredentialIdentityStoreProviding, @unchecked Sendable {
    private let lock = NSLock()

    private var _isEnabledValue = true
    private var _enumerationUnavailable = false
    private var _stored: [any ASCredentialIdentity] = []
    private var _calls: [String] = []
    private var _onMutation: (@Sendable () -> Void)?
    private var _onEnumerate: (@Sendable () -> Void)?
    private var _reportedSource: CredentialIdentitySource = .api

    /// Mirrors `ASCredentialIdentityStore.state().isEnabled`. Set false to
    /// simulate the provider being disabled in system AutoFill settings.
    var isEnabledValue: Bool {
        get { lock.withLock { _isEnabledValue } }
        set { lock.withLock { _isEnabledValue = newValue } }
    }

    /// When true, `credentialIdentities()` returns nil — the macOS 14.0–14.3
    /// "store enumeration unavailable" simulation.
    var enumerationUnavailable: Bool {
        get { lock.withLock { _enumerationUnavailable } }
        set { lock.withLock { _enumerationUnavailable = newValue } }
    }

    /// The store contents. Settable so tests can seed multi-database state
    /// directly (e.g. identities built by the real builders plus hand-made
    /// legacy/garbage-identifier identities).
    var stored: [any ASCredentialIdentity] {
        get { lock.withLock { _stored } }
        set { lock.withLock { _stored = newValue } }
    }

    /// Names of the mutating store methods, in call order:
    /// "replaceCredentialIdentities", "saveCredentialIdentities",
    /// "removeCredentialIdentities", "removeAllCredentialIdentities".
    /// (`isEnabled()` and `credentialIdentities()` are not recorded, so call
    /// sequences of mutations can be asserted exactly.)
    var calls: [String] {
        lock.withLock { _calls }
    }

    /// Invoked after every mutating call (replace/save/remove/removeAll),
    /// outside the lock. Fulfill an expectation here for positive
    /// assertions; `XCTFail` here for negative ones.
    var onMutation: (@Sendable () -> Void)? {
        get { lock.withLock { _onMutation } }
        set { lock.withLock { _onMutation = newValue } }
    }

    /// Invoked inside `credentialIdentities()` after the enumeration
    /// snapshot is taken but before it is returned, outside the lock —
    /// mutating `stored` from this hook simulates the store being changed
    /// externally between enumerate and mutate (the caller still sees the
    /// stale, pre-hook snapshot).
    var onEnumerate: (@Sendable () -> Void)? {
        get { lock.withLock { _onEnumerate } }
        set { lock.withLock { _onEnumerate = newValue } }
    }

    /// The source the DEBUG `credentialIdentitiesWithSource()` reports, so the
    /// inspector's pass-through of the seam's source signal is testable. The
    /// real seam sets `.fallbackDB` only when the DB fallback served rows; tests
    /// set this to simulate that outcome.
    var reportedSource: CredentialIdentitySource {
        get { lock.withLock { _reportedSource } }
        set { lock.withLock { _reportedSource = newValue } }
    }

    // MARK: - CredentialIdentityStoreProviding

    func isEnabled() async -> Bool {
        isEnabledValue
    }

    func replaceCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        let hook = lock.withLock {
            _calls.append("replaceCredentialIdentities")
            _stored = identities
            return _onMutation
        }
        hook?()
    }

    func saveCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        let hook = lock.withLock {
            _calls.append("saveCredentialIdentities")
            // Append-or-overwrite: an incoming identity replaces a stored one
            // with the same identity key (type + record identifier + service
            // scope), mirroring the system store's save semantics closely
            // enough for refresh tests.
            let incomingKeys = Set(identities.map(Self.identityKey))
            _stored.removeAll { incomingKeys.contains(Self.identityKey($0)) }
            _stored.append(contentsOf: identities)
            return _onMutation
        }
        hook?()
    }

    func removeCredentialIdentities(_ identities: [any ASCredentialIdentity]) async throws {
        let hook = lock.withLock {
            _calls.append("removeCredentialIdentities")
            // Drop stored identities carrying any of the removed identities'
            // record identifiers (all of the manager's removal paths key on
            // the record identifier).
            let removedIdentifiers = Set(identities.compactMap(\.recordIdentifier))
            _stored.removeAll { identity in
                guard let recordIdentifier = identity.recordIdentifier else { return false }
                return removedIdentifiers.contains(recordIdentifier)
            }
            return _onMutation
        }
        hook?()
    }

    func removeAllCredentialIdentities() async throws {
        let hook = lock.withLock {
            _calls.append("removeAllCredentialIdentities")
            _stored = []
            return _onMutation
        }
        hook?()
    }

    func credentialIdentities() async -> [any ASCredentialIdentity]? {
        let (unavailable, snapshot, hook) = lock.withLock {
            (_enumerationUnavailable, _stored, _onEnumerate)
        }
        hook?()
        return unavailable ? nil : snapshot
    }

    func credentialIdentitiesWithSource() async
        -> (identities: [any ASCredentialIdentity]?, source: CredentialIdentitySource) {
        let (unavailable, snapshot, source, hook) = lock.withLock {
            (_enumerationUnavailable, _stored, _reportedSource, _onEnumerate)
        }
        hook?()
        return (unavailable ? nil : snapshot, source)
    }

    // MARK: - Helpers

    /// Composite key identifying one stored identity for save-overwrite
    /// purposes. Includes the service scope because one entry publishes
    /// several password identities (one per domain) under a single record
    /// identifier.
    private static func identityKey(_ identity: any ASCredentialIdentity) -> String {
        let recordIdentifier = identity.recordIdentifier ?? ""
        if let password = identity as? ASPasswordCredentialIdentity {
            return "password|\(password.serviceIdentifier.identifier)|\(password.user)|\(recordIdentifier)"
        }
        if let passkey = identity as? ASPasskeyCredentialIdentity {
            return "passkey|\(passkey.relyingPartyIdentifier)|\(passkey.userName)|\(recordIdentifier)"
        }
        if #available(iOS 18.0, macOS 15.0, *),
           let oneTimeCode = identity as? ASOneTimeCodeCredentialIdentity {
            return "otc|\(oneTimeCode.serviceIdentifier.identifier)|\(oneTimeCode.label)|\(recordIdentifier)"
        }
        return "other|\(type(of: identity))|\(recordIdentifier)"
    }
}
