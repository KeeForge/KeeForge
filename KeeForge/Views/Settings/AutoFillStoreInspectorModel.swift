#if DEBUG
// DEBUG-only inspector for the OS credential identity store's metadata; it
// reads no decrypted secrets. Display strings are deliberately unlocalized so
// this dev-only surface stays out of the shipped catalogs and the German gate.
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
        bucketize(
            identities.map {
                (row(for: $0), CredentialIdentityStoreManager.recordIdentifier(of: $0) ?? "")
            },
            databaseName: databaseName
        )
    }

    /// Shared bucketing core: classifies each `(row, recordIdentifier)` pair by
    /// parsed record identifier and sorts the database buckets deterministically.
    private static func bucketize(
        _ pairs: [(row: InspectorIdentityRow, recordIdentifier: String)],
        databaseName: (UUID) -> String?
    ) -> (
        databaseBuckets: [InspectorDatabaseBucket],
        legacyRows: [InspectorIdentityRow],
        unrecognizedRows: [InspectorIdentityRow]
    ) {
        var rowsByDatabase: [UUID: [InspectorIdentityRow]] = [:]
        var legacyRows: [InspectorIdentityRow] = []
        var unrecognizedRows: [InspectorIdentityRow] = []

        for pair in pairs {
            switch CredentialRecordIdentifier.parse(pair.recordIdentifier) {
            case .current(let parsed):
                rowsByDatabase[parsed.databaseID, default: []].append(pair.row)
            case .legacy:
                legacyRows.append(pair.row)
            case .unrecognized:
                unrecognizedRows.append(pair.row)
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

    /// Wraps `makeBuckets` with the store-level facts.
    static func makeSnapshot(
        isEnabled: Bool,
        identities: [any ASCredentialIdentity],
        databaseName: (UUID) -> String?
    ) -> InspectorStoreSnapshot {
        let grouped = makeBuckets(from: identities, databaseName: databaseName)
        return InspectorStoreSnapshot(
            isEnabled: isEnabled,
            totalCount: identities.count,
            databaseBuckets: grouped.databaseBuckets,
            legacyRows: grouped.legacyRows,
            unrecognizedRows: grouped.unrecognizedRows
        )
    }
}
#endif
