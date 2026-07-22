#if DEBUG
// DEBUG-only developer tooling for the AutoFill store-validation harness
// (epic: 2026-07-20-autofill-store-validation-harness, slice 01). Nothing in
// this file ships in Release builds, and none of it reads decrypted secrets:
// it inspects only the OS-managed credential identity store's metadata
// (enabled state, counts, parsed record-identifier tags, service identifiers,
// usernames/labels). Display strings are intentionally NOT localized —
// `Text(verbatim:)`-friendly plain strings keep this dev-only surface out of
// the shipped String Catalogs and the German-completeness gate.
@preconcurrency import AuthenticationServices
import Foundation

// MARK: - Display model

/// The kind of a published credential identity, for the inspector's row badge.
enum InspectorIdentityKind: String, Sendable, Hashable {
    case password
    case passkey
    case oneTimeCode
    case other

    /// Non-localized developer-facing label.
    var displayName: String {
        switch self {
        case .password: "Password"
        case .passkey: "Passkey"
        case .oneTimeCode: "One-Time Code"
        case .other: "Other"
        }
    }
}

/// One identity's display metadata. Carries no secrets — only the service
/// identifier, the username/label, and the identity kind.
struct InspectorIdentityRow: Sendable, Hashable {
    let serviceIdentifier: String
    let label: String
    let kind: InspectorIdentityKind
}

/// The `.current`-format identities owned by one database UUID.
struct InspectorDatabaseBucket: Identifiable, Sendable, Hashable {
    /// The owning `DatabaseReference.id` parsed from the record identifier.
    let databaseID: UUID
    /// The database's display name when the UUID is registered in
    /// `DatabaseListStore.databases`, otherwise the raw `UUID.uuidString`.
    let displayName: String
    let rows: [InspectorIdentityRow]

    var id: UUID { databaseID }
    var count: Int { rows.count }
}

/// A fully-parsed, render-ready snapshot of the system credential identity
/// store. Sendable so it can be built off the main actor and handed back.
struct InspectorStoreSnapshot: Sendable {
    let isEnabled: Bool
    let enumerationAvailable: Bool
    let totalCount: Int
    let databaseBuckets: [InspectorDatabaseBucket]
    let legacyRows: [InspectorIdentityRow]
    let unrecognizedRows: [InspectorIdentityRow]
}

// MARK: - Pure grouping helpers

/// Pure, off-actor helpers turning `[any ASCredentialIdentity]` into the
/// inspector's buckets. Kept free of UI and store dependencies so they are
/// directly unit-testable with hand-built identities.
enum AutoFillStoreInspectorGrouping {
    /// Extracts the (secret-free) display metadata for one identity.
    static func row(for identity: any ASCredentialIdentity) -> InspectorIdentityRow {
        if let password = identity as? ASPasswordCredentialIdentity {
            return InspectorIdentityRow(
                serviceIdentifier: password.serviceIdentifier.identifier,
                label: password.user,
                kind: .password
            )
        }
        if let passkey = identity as? ASPasskeyCredentialIdentity {
            return InspectorIdentityRow(
                serviceIdentifier: passkey.relyingPartyIdentifier,
                label: passkey.userName,
                kind: .passkey
            )
        }
        if #available(iOS 18.0, macOS 15.0, *),
           let oneTimeCode = identity as? ASOneTimeCodeCredentialIdentity {
            return InspectorIdentityRow(
                serviceIdentifier: oneTimeCode.serviceIdentifier.identifier,
                label: oneTimeCode.label,
                kind: .oneTimeCode
            )
        }
        return InspectorIdentityRow(serviceIdentifier: "—", label: "", kind: .other)
    }

    /// Buckets `identities` by parsed record identifier:
    /// - `.current` → grouped by owning database UUID (name resolved via
    ///   `databaseName`, falling back to the raw UUID string),
    /// - `.legacy` (bare UUID) → the legacy bucket,
    /// - `.unrecognized` → the unrecognized bucket.
    /// Database buckets are sorted by display name (case-insensitive), then by
    /// UUID string, for deterministic rendering and assertions.
    static func makeBuckets(
        from identities: [any ASCredentialIdentity],
        databaseName: (UUID) -> String?
    ) -> (
        databaseBuckets: [InspectorDatabaseBucket],
        legacyRows: [InspectorIdentityRow],
        unrecognizedRows: [InspectorIdentityRow]
    ) {
        var rowsByDatabase: [UUID: [InspectorIdentityRow]] = [:]
        var legacyRows: [InspectorIdentityRow] = []
        var unrecognizedRows: [InspectorIdentityRow] = []

        for identity in identities {
            let identityRow = row(for: identity)
            switch CredentialRecordIdentifier.parse(identity.recordIdentifier ?? "") {
            case .current(let parsed):
                rowsByDatabase[parsed.databaseID, default: []].append(identityRow)
            case .legacy:
                legacyRows.append(identityRow)
            case .unrecognized:
                unrecognizedRows.append(identityRow)
            }
        }

        let databaseBuckets = rowsByDatabase
            .map { databaseID, rows in
                InspectorDatabaseBucket(
                    databaseID: databaseID,
                    displayName: databaseName(databaseID) ?? databaseID.uuidString,
                    rows: rows
                )
            }
            .sorted { lhs, rhs in
                switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.databaseID.uuidString < rhs.databaseID.uuidString
                }
            }

        return (databaseBuckets, legacyRows, unrecognizedRows)
    }

    /// Wraps `makeBuckets` with the store-level facts. A `nil` `identities`
    /// means enumeration is unavailable (`credentialIdentities()` returned nil):
    /// the snapshot then reports no buckets and a zero total count.
    static func makeSnapshot(
        isEnabled: Bool,
        identities: [any ASCredentialIdentity]?,
        databaseName: (UUID) -> String?
    ) -> InspectorStoreSnapshot {
        guard let identities else {
            return InspectorStoreSnapshot(
                isEnabled: isEnabled,
                enumerationAvailable: false,
                totalCount: 0,
                databaseBuckets: [],
                legacyRows: [],
                unrecognizedRows: []
            )
        }

        let grouped = makeBuckets(from: identities, databaseName: databaseName)
        return InspectorStoreSnapshot(
            isEnabled: isEnabled,
            enumerationAvailable: true,
            totalCount: identities.count,
            databaseBuckets: grouped.databaseBuckets,
            legacyRows: grouped.legacyRows,
            unrecognizedRows: grouped.unrecognizedRows
        )
    }
}

// MARK: - Launch-time status log

/// Emits a single machine-readable status line describing the system
/// credential identity store, gated behind the `-autofill-store-status-log`
/// launch argument. The provisioning script (slice 02) polls stdout / the
/// unified log for this exact line to decide whether the harness simulator is
/// provisioned. The argument composes with `-autofill-store-inspector` and
/// otherwise does not change app behavior.
enum AutoFillStoreStatusLog {
    static let launchArgument = "-autofill-store-status-log"
    static let linePrefix = "KEEFORGE-AUTOFILL-STORE-STATUS"

    /// If the launch argument is present, query the store off the main actor
    /// and emit exactly one status line via both `print()` (captured on stdout
    /// by `simctl launch --console-pty`) and `NSLog` (visible in the unified
    /// log). Format, verbatim:
    ///
    ///     KEEFORGE-AUTOFILL-STORE-STATUS: enabled=<true|false> enumeration=<available|unavailable>
    static func emitIfRequested(
        store: any CredentialIdentityStoreProviding = SystemCredentialIdentityStore()
    ) {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }

        Task.detached {
            let isEnabled = await store.isEnabled()
            let enumerationAvailable = await store.credentialIdentities() != nil
            let line = "\(linePrefix): enabled=\(isEnabled) "
                + "enumeration=\(enumerationAvailable ? "available" : "unavailable")"
            print(line)
            NSLog("%@", line)
        }
    }
}
#endif
