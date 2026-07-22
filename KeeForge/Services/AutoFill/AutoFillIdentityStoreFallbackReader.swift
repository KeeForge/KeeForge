#if DEBUG && targetEnvironment(simulator)
// DEBUG + simulator-only fallback read channel for the AutoFill credential
// identity store (epic: 2026-07-20-autofill-store-validation-harness). Nothing
// here compiles into Release builds OR onto real devices — the whole file is
// gated `#if DEBUG && targetEnvironment(simulator)`. It reads only OS-store
// *metadata* and *public identifiers*: service identifier, username/label,
// record-identifier tag, numeric identity/service type, and (for passkeys) the
// public credential ID and user handle. It never reads a private key or secret.
//
// Why this exists: on simulator runtimes (verified iOS 18.5 and 26.5)
// `ASCredentialIdentityStore.credentialIdentities(forService:credentialIdentityTypes:)`
// always returns an *empty array* even though `saveCredentialIdentities` /
// `replaceCredentialIdentities` / `removeCredentialIdentities` succeed and the
// identities persist (QuickType consumes them). Because the app's OWN store
// maintenance (`CredentialIdentityStoreManager.populate` /
// `removeIdentities(forDatabase:)`) enumerates-then-mutates, that empty read
// makes per-database disable-removal and multi-database union structurally
// broken on every simulator. This reader restores device-equivalent behavior by
// reading the store's true contents from the SQLite file the OS's
// `CredentialProviderExtensionHelper` writes inside the app's own data
// container:
//
//     <NSHomeDirectory>/SystemData/com.apple.AuthenticationServices/Identities/Identities.db
//
// and *reconstructing byte-faithful* `ASCredentialIdentity` objects (same
// service identifier, user, record identifier, and — for passkeys — credential
// ID / user handle) so the manager's filter-and-remove logic matches the real
// rows. In the AutoFill extension process `NSHomeDirectory()` resolves to the
// extension's own container, which has no such file, so this returns empty
// there (absent file => empty store) and the extension is unaffected.
@preconcurrency import AuthenticationServices
import Foundation
import SQLite3

// MARK: - Raw row

/// One row of the AutoFill store's backing `credential_identities` table.
/// Sendable so it can be read off-actor and carried back; carries only the
/// columns needed to reconstruct a credential identity — no private material.
struct FallbackIdentityRow: Sendable, Hashable {
    /// `identity_type`: `1` = password, `2` = passkey, `4` = one-time-code.
    let identityType: Int64
    /// `service_id`: password/one-time-code service identifier, or passkey RP id.
    let serviceIdentifier: String
    /// `service_id_type`: `ASCredentialServiceIdentifier.IdentifierType` raw
    /// value (`0` = domain, `1` = URL).
    let serviceIdentifierType: Int64
    /// `external_record_id`: KeeForge's `v2:<db-uuid>:<entry-uuid>` tag.
    let recordIdentifier: String
    /// `user`: password username, passkey user name, or one-time-code label.
    let user: String
    /// `credential_id`: base64 public passkey credential ID (nil for non-passkey).
    let credentialIDBase64: String?
    /// `user_handle`: base64 public passkey user handle (nil for non-passkey).
    let userHandleBase64: String?
}

// MARK: - Reader

/// Read-only, metadata-only reader + reconstructor for the credential identity
/// store's backing `Identities.db`. Every read opens fresh, tolerates a briefly
/// busy writer, and treats an absent file / table as an empty store.
struct AutoFillIdentitiesDatabaseReader: Sendable {
    /// Location of the backing store file. Overridable so unit tests can point
    /// at a fixture built in a temp directory.
    let databaseURL: URL

    init(databaseURL: URL = AutoFillIdentitiesDatabaseReader.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// The backing file inside the (app or extension) data container.
    /// `removeAllCredentialIdentities` deletes the whole file, so its absence is
    /// a legitimate empty store.
    static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(
                "SystemData/com.apple.AuthenticationServices/Identities/Identities.db"
            )
    }

    /// The store's contents reconstructed as real `ASCredentialIdentity`
    /// objects, byte-faithful to what KeeForge published. Rows whose type is
    /// unknown, or passkey rows missing their public credential-ID / user-handle
    /// columns, are skipped (never a crash).
    func reconstructedIdentities() async -> [any ASCredentialIdentity] {
        // Read the Sendable rows off-actor, then reconstruct on the current
        // (already off-main) executor — `ASCredentialIdentity` is not Sendable
        // and must not cross the detached-task boundary.
        let rows = await readRows()
        return rows.compactMap(Self.reconstruct)
    }

    /// The raw rows (Sendable) — exposed for tests and reconstruction.
    func readRows() async -> [FallbackIdentityRow] {
        let url = databaseURL
        return await Task.detached(priority: .utility) {
            Self.read(at: url)
        }.value
    }

    // MARK: - Reconstruction

    /// Rebuilds one credential identity from a raw row, or `nil` when the type
    /// is unknown or a passkey row lacks its public identifier columns.
    static func reconstruct(_ row: FallbackIdentityRow) -> (any ASCredentialIdentity)? {
        switch row.identityType {
        case 1:
            return ASPasswordCredentialIdentity(
                serviceIdentifier: serviceIdentifier(row),
                user: row.user,
                recordIdentifier: row.recordIdentifier
            )
        case 2:
            guard
                let credentialBase64 = row.credentialIDBase64,
                let credentialID = Data(base64Encoded: credentialBase64),
                let handleBase64 = row.userHandleBase64,
                let userHandle = Data(base64Encoded: handleBase64)
            else { return nil }
            return ASPasskeyCredentialIdentity(
                relyingPartyIdentifier: row.serviceIdentifier,
                userName: row.user,
                credentialID: credentialID,
                userHandle: userHandle,
                recordIdentifier: row.recordIdentifier
            )
        case 4:
            if #available(iOS 18.0, macOS 15.0, *) {
                return ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: serviceIdentifier(row),
                    label: row.user,
                    recordIdentifier: row.recordIdentifier
                )
            }
            return nil
        default:
            return nil
        }
    }

    private static func serviceIdentifier(_ row: FallbackIdentityRow) -> ASCredentialServiceIdentifier {
        let type = ASCredentialServiceIdentifier.IdentifierType(rawValue: Int(row.serviceIdentifierType)) ?? .domain
        return ASCredentialServiceIdentifier(identifier: row.serviceIdentifier, type: type)
    }

    // MARK: - Off-actor SQLite read

    private static let table = "credential_identities"
    private static let busyRetryLimit = 5
    private static let busyPauseMicroseconds: useconds_t = 50_000

    static func read(at url: URL) -> [FallbackIdentityRow] {
        // Absent file => empty store (not an error). Also the normal case in
        // the extension process, whose container has no Identities.db.
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var handle: OpaquePointer?
        // Read-only URI open: honors the -wal file's committed rows, never
        // mutates the store. NOMUTEX is safe — the connection is single-use.
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            return []
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 200)

        // Select ONLY the columns needed to reconstruct an identity — never a
        // private-key column. Selected by NAME, so extra or reordered columns in
        // the real schema are tolerated.
        let query = """
        SELECT identity_type, service_id, service_id_type, external_record_id, user, credential_id, user_handle \
        FROM \(table);
        """
        var statement: OpaquePointer?
        var prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        var prepareAttempts = 0
        while prepareResult == SQLITE_BUSY, prepareAttempts < busyRetryLimit {
            prepareAttempts += 1
            usleep(busyPauseMicroseconds)
            prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        }
        // Absent table / column mismatch => empty result, never a crash.
        guard prepareResult == SQLITE_OK, let stmt = statement else {
            if let statement { sqlite3_finalize(statement) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [FallbackIdentityRow] = []
        var stepAttempts = 0
        loop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                rows.append(FallbackIdentityRow(
                    identityType: sqlite3_column_int64(stmt, 0),
                    serviceIdentifier: text(stmt, 1) ?? "",
                    serviceIdentifierType: sqlite3_column_int64(stmt, 2),
                    recordIdentifier: text(stmt, 3) ?? "",
                    user: text(stmt, 4) ?? "",
                    credentialIDBase64: text(stmt, 5),
                    userHandleBase64: text(stmt, 6)
                ))
            case SQLITE_BUSY where stepAttempts < busyRetryLimit:
                stepAttempts += 1
                usleep(busyPauseMicroseconds)
            case SQLITE_DONE:
                break loop
            default:
                break loop
            }
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}
#endif
