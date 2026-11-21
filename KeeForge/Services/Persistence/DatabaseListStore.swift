import Darwin

import CryptoKit
import Foundation

enum DatabaseListStore {
    enum AddDatabaseError: Error, LocalizedError, Equatable {
        case duplicateFile(existingReferenceID: UUID, filename: String)
        case duplicateCreatedFilename(filename: String)
        case unresolvedCloudUpload

        var errorDescription: String? {
            switch self {
            case .duplicateFile(_, let filename):
                return String(localized: "“\(filename)” is already in your database list.")
            case .duplicateCreatedFilename(let filename):
                return String(localized: "“\(filename)” is already used by a KeeForge-only database.")
            case .unresolvedCloudUpload:
                return String(localized: "This file has an unconfirmed upload. You can export the encrypted copy in Cloud Recovery.")
            }
        }
    }

    private static let databaseListFilename = "database-list.json"
    private static let applicationSupportPathComponent = "Library/Application Support"
    private static let backupsDirectoryName = "backups"
    private static let activeAutoFillDatabaseIDKey = "activeAutoFillDatabaseID"
    private static let migrationVersionKey = "databaseListMigrationVersion"
    private static let currentMigrationVersion = 1
    #if DEBUG
    private static let uiTestingLaunchArg = "-ui-testing"
    private static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
    private static let uiTestCloudDatabasesJSONEnv = "UI_TEST_CLOUD_DATABASES_JSON"
    private static let uiTestCloudAccountsJSONEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let uiTestLocalSaveConflictCountEnv = "UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"
    private static let uiTestLocalSaveConflictDivergesPoolEnv = "UI_TEST_LOCAL_SAVE_CONFLICT_DIVERGES_POOL"
    private static let uiTestDatabaseReadOnlyEnv = "UI_TEST_DATABASE_READ_ONLY"
    private static let uiTestEnableQuickLaunchEnv = "UI_TEST_ENABLE_QUICK_LAUNCH"
    #endif
    private static let cloudAccountsStorageKey = "KeeForge.cloudAccounts"

    private static var sharedDefaults: UserDefaults {
        AppGroupContainer.defaults
    }

    private static var sharedContainerURL: URL {
        AppGroupContainer.url
    }

    private static var databaseListURL: URL {
        sharedContainerURL.appendingPathComponent(databaseListFilename, isDirectory: false)
    }

    /// Test hook: replaces the app-sandbox Documents directory used for
    /// Documents-resident classification and rebinding. Set only from tests,
    /// before any store call, matching the UI-test statics above.
    nonisolated(unsafe) static var documentsDirectoryOverride: URL?

    static var documentsDirectoryURL: URL {
        documentsDirectoryOverride ?? URL.documentsDirectory
    }

    #if DEBUG
    private nonisolated(unsafe) static var didBootstrapUITesting = false
    private static let uiTestBootstrapLock = NSLock()
    private nonisolated(unsafe) static var remainingUITestLocalSaveConflicts: Int?
    private nonisolated(unsafe) static var consumedUITestLocalSaveConflicts = 0
    #endif

    // Legacy writers still use this process-local lock; coordinated accessors must try it.
    private static let stateLock = NSRecursiveLock()

    private static func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private enum RegistryDecision<T> {
        case write(T), noop(T), rejected, missing
    }

    private enum RegistryResult<T> {
        case durable(T), noop(T), rejected, missing, notPublished(Error), visibleUnconfirmed(T, Error)
    }

    private static func readRegistry(at url: URL) throws -> [DatabaseReference]? {
        do {
            return normalized(try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: url)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func readDatabasesStrict() throws -> [DatabaseReference] {
        guard let rows = try readRegistry(at: databaseListURL) else { throw CocoaError(.fileReadNoSuchFile) }
        return rows
    }

    private static func mutateRegistry<T>(onMissing: (() -> [DatabaseReference])? = nil, io: DurableFileWriteIO = .init(),
                                          confirmUnchanged: Bool = false,
                                          readingTarget: URL? = nil, validateTarget: ((URL) throws -> Bool)? = nil,
                                          authorize: (((() throws -> RegistryResult<T>) throws -> RegistryResult<T>))? = nil,
                                          _ body: (inout [DatabaseReference]) throws -> RegistryDecision<T>) -> RegistryResult<T> {
        return withoutActuallyEscaping(body) { body in
            guard let anchor = AppGroupContainer.resolvedURL else { return .notPublished(CocoaError(.fileWriteNoPermission)) }
            var coordinationError: NSError?
            var result: RegistryResult<T>?
            func access(_ url: URL, _ target: URL?) {
                guard stateLock.try() else { result = .notPublished(PendingLocalSaveStore.OwnershipError.recoveryRequired); return }
                defer { stateLock.unlock() }
                do {
                    let mutate = { () throws -> RegistryResult<T> in
                        if let validateTarget {
                            guard let target, try validateTarget(target) else { return .rejected }
                        }
                        var rows: [DatabaseReference]
                        if let existing = try readRegistry(at: url) { rows = existing }
                        else if let onMissing { rows = onMissing() }
                        else { return .missing }
                        switch try body(&rows) {
                        case .noop(let value):
                            if confirmUnchanged {
                                let handle = try FileHandle(forUpdating: url)
                                defer { try? handle.close() }
                                try io.synchronizeFile(handle.fileDescriptor)
                                try io.synchronizeParent(url.deletingLastPathComponent())
                            }
                            return .noop(value)
                        case .rejected: return .rejected
                        case .missing: return .missing
                        case .write(let value):
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            let bytes = try encoder.encode(normalized(rows))
                            switch writeWithDurabilityOutcome(bytes, to: url, directoryAnchor: anchor, io: io) {
                            case .durable: return .durable(value)
                            case .notPublished(let error): return .notPublished(error)
                            case .publishedWithoutConfirmedDurability(let error): return .visibleUnconfirmed(value, error)
                            }
                        }
                    }
                    result = try authorize?(mutate) ?? mutate()
                } catch { result = .notPublished(error) }
            }
            let coordinator = NSFileCoordinator()
            if let readingTarget {
                coordinator.coordinate(readingItemAt: readingTarget, options: [], writingItemAt: databaseListURL, options: [], error: &coordinationError) { target, url in access(url, target) }
            } else {
                coordinator.coordinate(writingItemAt: databaseListURL, options: [], error: &coordinationError) { url in access(url, nil) }
            }
            if let error = coordinationError {
                if case .durable(let value) = result { return .visibleUnconfirmed(value, error) }
                if case .noop = result { return .notPublished(error) }
                if let result { return result }
                return .notPublished(error)
            }
            return result ?? .notPublished(CocoaError(.fileWriteUnknown))
        }
    }

    private static func succeeded<T>(_ result: RegistryResult<T>) -> Bool {
        switch result { case .durable, .noop: return true; default: return false }
    }

    enum RegistryWriteError: Error {
        case unavailable
        case visibleUnconfirmed(Error)
        case appOnlyCacheUnconfirmed(id: UUID, sha512: Data, underlying: Error)
        case appOnlyCacheInstalled(id: UUID, sha512: Data, underlying: Error)
        case appOnlyRegistryUnconfirmed(id: UUID, sha512: Data, underlying: Error)
    }

    private enum AppOnlyResult {
        case durable, rejected, notPublished(Error), cacheUnconfirmed(Error), cacheInstalled(Error), registryUnconfirmed(Error)
    }

    private static func requireRegistryInitialization() throws {
        switch initializeRegistry() {
        case .initialized, .alreadyPresent: return
        case .notPublished(let error): throw error
        case .visibleUnconfirmed(let error): throw RegistryWriteError.visibleUnconfirmed(error)
        }
    }

    @discardableResult
    static func setNickname(_ nickname: String?, for id: UUID) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return .missing }
            guard rows[index].nickname != nickname else { return .noop(()) }
            rows[index].nickname = nickname
            return .write(())
        })
    }

    @discardableResult
    static func setQuickLaunch(_ enabled: Bool, for id: UUID, observed: Bool) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return .missing }
            guard rows[index].isQuickLaunch == observed else { return .rejected }
            if !enabled && !observed { return .noop(()) }
            for i in rows.indices { rows[i].isQuickLaunch = enabled && i == index }
            return .write(())
        })
    }

    #if DEBUG
    private struct UITestDatabasePayload: Decodable {
        let filename: String
        let base64: String
        let disposition: UITestDatabaseDisposition?
    }

    /// Where a UI-test fixture database lands and how it is registered.
    /// Absent = the historical behavior: a per-launch tmp directory, registered.
    private enum UITestDatabaseDisposition: String, Decodable {
        /// Top-level Documents file, registered (`isDocumentsResident == true`).
        case documents
        /// Top-level Documents file, NOT registered — `DocumentsVaultScanner`
        /// must discover it through the normal launch scan.
        case documentsUnregistered = "documents-unregistered"
        /// Registered as Documents-resident, then the file is deleted so the
        /// reference points at a missing resident file.
        case documentsMissing = "documents-missing"
    }

    private struct UITestCloudDatabasePayload: Decodable {
        let provider: String
        let accountId: String
        let file: UITestCloudFilePayload
    }

    private struct UITestCloudFilePayload: Decodable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let modifiedDate: Date?
        let size: Int64?
    }
    #endif

    static var databases: [DatabaseReference] {
        loadDatabases()
    }

    static var quickLaunchDatabase: DatabaseReference? {
        loadDatabases().first(where: \.isQuickLaunch)
    }

    static var activeAutoFillDatabaseID: UUID? {
        get {
            guard let rawValue = sharedDefaults.string(forKey: activeAutoFillDatabaseIDKey) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            withStateLock {
                if let newValue {
                    // A database with AutoFill disabled can never become the
                    // active AutoFill database; refuse the write and keep the
                    // current pointer. IDs unknown to the persisted registry
                    // pass through unchanged (e.g. references that have not
                    // been saved to the list yet).
                    let knownReference = decodeStoredDatabases().first { $0.id == newValue }
                    if knownReference?.autoFillEnabled == false {
                        return
                    }
                    sharedDefaults.set(newValue.uuidString, forKey: activeAutoFillDatabaseIDKey)
                } else {
                    sharedDefaults.removeObject(forKey: activeAutoFillDatabaseIDKey)
                }
            }
        }
    }

    static var activeAutoFillDatabase: DatabaseReference? {
        activeAutoFillDatabase(in: loadDatabases())
    }

    /// The extension's default database for AutoFill flows that carry no
    /// record identifier — manual credential search, the one-time-code list,
    /// passkey parameter requests, and in-extension save (slice 03 of the
    /// selectable-AutoFill epic): the active pointer's reference when it is
    /// AutoFill-enabled (including the legacy keychain-filename fallback,
    /// exactly like `activeAutoFillDatabase`), else the most recently opened
    /// AutoFill-enabled database, else nil. Never returns a database with
    /// AutoFill disabled.
    static var defaultAutoFillDatabase: DatabaseReference? {
        defaultAutoFillDatabase(in: loadDatabases())
    }

    static func defaultAutoFillDatabase(in currentDatabases: [DatabaseReference]) -> DatabaseReference? {
        if let activeReference = activeAutoFillDatabase(in: currentDatabases) {
            return activeReference
        }

        return currentDatabases
            .filter { $0.autoFillEnabled && $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    /// Databases that participate in AutoFill. Only these may publish
    /// credential identities or become the active AutoFill database.
    static var autoFillEnabledDatabases: [DatabaseReference] {
        loadDatabases().filter(\.autoFillEnabled)
    }

    static func databaseBackupDirectoryURL(for reference: DatabaseReference) -> URL {
        backupsRootURL.appendingPathComponent(reference.id.uuidString, isDirectory: true)
    }

    static func recentBackups(for reference: DatabaseReference) -> [URL] {
        let directoryURL = databaseBackupDirectoryURL(for: reference)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                guard url.pathExtension.lowercased() == "kdbx" else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    @discardableResult
    static func add(url: URL) throws -> DatabaseReference {
        let reference = try makeReference(from: url)
        try registerLocalReference(reference, target: url)
        cacheInitialCopyIfPossible(from: url, for: reference.id)
        return reference
    }

    /// `DocumentsVaultScanner`'s registration: nil for a Documents file the
    /// user removed from the list and that has not changed since.
    @discardableResult
    static func addDiscoveredDocumentsFile(url: URL) throws -> DatabaseReference? {
        let reference = try makeReference(from: url)
        // Read before the registry lock: hashing a vault there would fail concurrent mutations.
        let snapshot = documentsFileSnapshot(for: url)
        let contentDigest = snapshot.flatMap { snapshot in
            removedDocumentsFiles.contains { $0.matches(snapshot) } ? nil : contentDigestIfRemoved(url, snapshot)
        }
        guard try registerLocalReference(
            reference, target: url, skippingRemovedDocumentsFile: RemovalCheck(snapshot: snapshot, contentDigest: contentDigest)
        ) else { return nil }
        cacheInitialCopyIfPossible(from: url, for: reference.id)
        return reference
    }

    @discardableResult
    static func addCloud(
        provider: String,
        accountId: String,
        file: CloudFile,
        io: DurableFileWriteIO = .init()
    ) throws -> DatabaseReference {
        try requireRegistryInitialization()
        let reference = DatabaseReference(
                id: UUID(),
                nickname: nil,
                filename: file.name,
                bookmarkData: nil,
                keyFileBookmarkData: nil,
                keyFileFilename: nil,
                isQuickLaunch: false,
                lastOpenedAt: nil,
                addedAt: .now,
                colorTag: nil,
                legacyKeychainFilename: nil,
                source: .cloud(
                    CloudSyncMetadata(
                        provider: provider,
                        accountId: accountId,
                        fileId: file.id,
                        displayPath: file.path,
                        remoteContentHash: nil,
                        remoteModifiedAt: file.modifiedDate,
                        lastSyncedAt: nil,
                        lastSyncIssue: nil
                    )
                )
            )
        let result = mutateRegistry(io: io) { rows -> RegistryDecision<DatabaseReference> in
            if let existing = rows.first(where: {
                guard let metadata = $0.cloudSyncMetadata else { return false }
                return metadata.provider == provider && metadata.accountId == accountId && metadata.fileId == file.id
            }) { return .noop(existing) }
            try requireNoDetachedUpload(provider: provider, accountID: accountId, fileID: file.id, in: rows)
            guard !rows.contains(where: { $0.id == reference.id }) else { return .rejected }
            rows.append(reference)
            return .write(reference)
        }
        switch result {
        case .durable(let value), .noop(let value): return value
        case .notPublished(let error): throw error
        case .visibleUnconfirmed(_, let error): throw RegistryWriteError.visibleUnconfirmed(error)
        case .missing, .rejected: throw RegistryWriteError.unavailable
        }
    }

    static func addCreatedLocal(_ reference: DatabaseReference) throws {
        let target = reference.bookmarkData.flatMap { SecurityScopedBookmarkManager.resolveURL(from: $0)?.url }
        try registerLocalReference(reference, target: target)
    }

    /// False only when `skippingRemovedDocumentsFile` found the file's removal
    /// record. The record is read and cleared under the registry lock, so a
    /// concurrent removal cannot slip in between. An explicit add that cannot
    /// clear it fails, and one whose row is not published restores it.
    @discardableResult
    private static func registerLocalReference(
        _ reference: DatabaseReference, target: URL?,
        skippingRemovedDocumentsFile removalCheck: RemovalCheck? = nil
    ) throws -> Bool {
        let accessed = target?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { target?.stopAccessingSecurityScopedResource() } }
        try requireRegistryInitialization()
        guard let observed = try readRegistry(at: databaseListURL) else { throw RegistryWriteError.unavailable }
        let duplicate = target.flatMap { existingLocalReference(matching: $0, in: observed) }
        let forgetsRemoval = removalCheck == nil && target.map(isTopLevelDocumentsFile) == true
        let result = mutateRegistry(authorize: { mutate in
            let forgotten = forgetsRemoval ? try target.map(forgetRemovedDocumentsFile(at:)) ?? [] : []
            var published = false
            defer { if !published { restoreRemovedDocumentsFiles(forgotten) } }
            let result = try mutate()
            if case .durable(true) = result { published = true }
            if case .visibleUnconfirmed(true, _) = result { published = true }
            return result
        }) { rows -> RegistryDecision<Bool> in
            guard rows.count == observed.count, zip(rows, observed).allSatisfy({ current, previous in
                current.id == previous.id && current.bookmarkData == previous.bookmarkData && current.isCloudBacked == previous.isCloudBacked
            }) else { return .rejected }
            guard !rows.contains(where: { $0.id == reference.id }) else { return .rejected }
            if let duplicate {
                throw AddDatabaseError.duplicateFile(existingReferenceID: duplicate.id, filename: duplicate.displayName)
            }
            if reference.bookmarkData == nil { try validateAppOnlyCreatedLocal(reference, in: rows) }
            if let removalCheck, let target, isTopLevelDocumentsFile(target),
               isRemovedDocumentsFile(target, checkedAs: removalCheck) { return .noop(false) }
            rows.append(reference)
            return .write(true)
        }
        switch result {
        case .durable(let registered), .noop(let registered): return registered
        case .notPublished(let error): throw error
        case .visibleUnconfirmed(_, let error): throw RegistryWriteError.visibleUnconfirmed(error)
        case .missing, .rejected: throw RegistryWriteError.unavailable
        }
    }

    static func addAppOnlyCreatedLocal(_ reference: DatabaseReference, encryptedBytes: Data,
                                       cacheIO: DurableFileWriteIO = .init(), registryIO: DurableFileWriteIO = .init()) throws {
        guard !reference.isCloudBacked, reference.bookmarkData == nil else { throw RegistryWriteError.unavailable }
        try requireRegistryInitialization()
        guard let anchor = AppGroupContainer.resolvedURL else { throw CocoaError(.fileWriteNoPermission) }
        let lease = try PendingLocalSaveStore.captureCacheReadLease(for: reference)
        let cache = cacheLocation(for: reference)
        try createDurableDirectory(at: cache.deletingLastPathComponent(), anchor: anchor)
        let sha = FileDigest.sha512(encryptedBytes)
        var coordinationError: NSError?
        var result: AppOnlyResult?
        NSFileCoordinator().coordinate(writingItemAt: cache, options: [], writingItemAt: databaseListURL, options: [], error: &coordinationError) { target, registry in
            guard stateLock.try() else { result = .notPublished(PendingLocalSaveStore.OwnershipError.recoveryRequired); return }
            defer { stateLock.unlock() }
            do {
                guard var rows = try readRegistry(at: registry) else { result = .rejected; return }
                guard !rows.contains(where: { $0.id == reference.id }) else { result = .registryUnconfirmed(CocoaError(.fileWriteUnknown)); return }
                try validateAppOnlyCreatedLocal(reference, in: rows)
                rows.append(reference)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let registryBytes = try encoder.encode(normalized(rows))
                result = try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: sha, lease: lease, nonBlocking: true) {
                    if FileManager.default.fileExists(atPath: target.path) { return .cacheUnconfirmed(CocoaError(.fileWriteFileExists)) }
                    switch writeWithDurabilityOutcome(encryptedBytes, to: target, directoryAnchor: anchor, publication: .exclusive, io: cacheIO) {
                    case .notPublished(let error):
                        if let posix = error as? POSIXError, posix.code == .EEXIST { return .cacheUnconfirmed(error) }
                        return .notPublished(error)
                    case .publishedWithoutConfirmedDurability(let error): return .cacheUnconfirmed(error)
                    case .durable:
                        switch writeWithDurabilityOutcome(registryBytes, to: registry, directoryAnchor: anchor, io: registryIO) {
                        case .durable: return .durable
                        case .notPublished(let error): return .cacheInstalled(error)
                        case .publishedWithoutConfirmedDurability(let error): return .registryUnconfirmed(error)
                        }
                    }
                }
            } catch { result = .notPublished(error) }
        }
        if let error = coordinationError {
            switch result {
            case .durable, .registryUnconfirmed: throw RegistryWriteError.appOnlyRegistryUnconfirmed(id: reference.id, sha512: sha, underlying: error)
            case .cacheInstalled: throw RegistryWriteError.appOnlyCacheInstalled(id: reference.id, sha512: sha, underlying: error)
            case .cacheUnconfirmed: throw RegistryWriteError.appOnlyCacheUnconfirmed(id: reference.id, sha512: sha, underlying: error)
            default: throw error
            }
        }
        switch result {
        case .durable: return
        case .notPublished(let error): throw error
        case .cacheUnconfirmed(let error): throw RegistryWriteError.appOnlyCacheUnconfirmed(id: reference.id, sha512: sha, underlying: error)
        case .cacheInstalled(let error): throw RegistryWriteError.appOnlyCacheInstalled(id: reference.id, sha512: sha, underlying: error)
        case .registryUnconfirmed(let error): throw RegistryWriteError.appOnlyRegistryUnconfirmed(id: reference.id, sha512: sha, underlying: error)
        default: throw RegistryWriteError.unavailable
        }
    }

    static func validateCreatedLocal(_ reference: DatabaseReference) throws {
        try validateCreatedLocal(reference, in: loadDatabases())
    }

    static func validateAppOnlyCreatedLocal(_ reference: DatabaseReference) throws {
        try validateAppOnlyCreatedLocal(reference, in: loadDatabases())
    }

    /// Refuses a new database's destination when a listed database already lives there.
    static func validateCreatedLocalDestination(_ url: URL) throws {
        if let duplicate = existingLocalReference(matching: url, in: loadDatabases()) {
            throw AddDatabaseError.duplicateFile(existingReferenceID: duplicate.id, filename: duplicate.displayName)
        }
    }

    static func validateCreatedCloud(
        provider: String,
        accountId: String,
        fileId: String,
        filename: String
    ) throws {
        try validateCreatedCloud(
            provider: provider,
            accountId: accountId,
            fileId: fileId,
            filename: filename,
            in: loadDatabases()
        )
    }

    enum RemovalOutcome: Sendable, Equatable {
        case removed, alreadyMissing, rejected, notPublished, revocationUnconfirmed
        case recoveryRequired, revokedRegistryNotPublished, visibleUnconfirmed
        case cloudRecoveryRequired(canKeepRecoveryCopies: Bool)
    }

    private struct RemovalReceipt {
        let reference: DatabaseReference
        let wasActive: Bool
        let sharedLegacy: Bool
    }

    @discardableResult
    static func remove(observed: DatabaseReference, keepingUnconfirmedCloudUploads: Bool = false,
                       io: DurableFileWriteIO = .init()) -> RemovalOutcome {
        var revocationAttempted = false
        var revocationObserved = false
        var recoveryRequired = false
        var cloudRecoveryCanKeepCopies: Bool?
        var rowMissing = false
        var recordedFile: RemovedDocumentsFile?
        let removedFile = removedDocumentsFileRecord(for: observed)
        do {
            return try PendingUploadQueue.withCommitLock(for: observed.id, nonBlocking: true) {
                let result = mutateRegistry(io: io, authorize: { mutate in
                    var published = false
                    defer {
                        if !published, let recordedFile { forgetRemovedDocumentsFiles([recordedFile]) }
                    }
                    let result = try mutate()
                    switch result {
                    case .durable, .visibleUnconfirmed: published = true
                    default: break
                    }
                    return result
                }) { rows -> RegistryDecision<RemovalReceipt> in
                    guard let index = rows.firstIndex(where: { $0.id == observed.id }) else { rowMissing = true; return .missing }
                    let current = rows[index]
                    guard PendingLocalSaveStore.PreferenceObservation(observed).matches(current),
                          current.hardwareKey == observed.hardwareKey,
                          current.autoFillEnabled == observed.autoFillEnabled,
                          current.legacyKeychainFilename == observed.legacyKeychainFilename,
                          current.cloudSyncMetadata?.localHeadOperationID == observed.cloudSyncMetadata?.localHeadOperationID,
                          current.cloudSyncMetadata?.keyEpoch == observed.cloudSyncMetadata?.keyEpoch,
                          current.cloudSyncMetadata?.remoteRev == observed.cloudSyncMetadata?.remoteRev,
                          current.cloudSyncMetadata?.remoteContentHash == observed.cloudSyncMetadata?.remoteContentHash else { return .rejected }
                    var recoveryCopies: [PendingUploadQueue.StoredMarker] = []
                    if let metadata = current.cloudSyncMetadata {
                        let journal = try PendingUploadQueue.readJournal(for: current.id)
                        if !journal.isEmpty {
                            let hasAnotherReference = rows.contains { other in
                                guard other.id != current.id, let source = other.cloudSyncMetadata else { return false }
                                return sameCloudFile(metadata.provider, metadata.accountId, metadata.fileId,
                                    source.provider, source.accountId, source.fileId)
                            }
                            let recoverable = !hasAnotherReference && journal.allSatisfy { entry in
                                let marker = entry.marker
                                return CloudJournalDecision.state(of: marker) == .attempting
                                    && marker.keyChange == nil && marker.isPayloadFinalized == true
                                    && PendingUploadQueue.hasBoundAuthority(entry, reference: current)
                                    && (try? PendingUploadQueue.readImmutablePayload(entry)) != nil
                            }
                            guard recoverable && keepingUnconfirmedCloudUploads else {
                                cloudRecoveryCanKeepCopies = recoverable
                                return .rejected
                            }
                            recoveryCopies = journal
                        }
                    }
                    // Durable before the list write: a crash right after it must not re-list the file.
                    guard removedFile.isCurrent(for: current) else { return .rejected }
                    for var copy in recoveryCopies {
                        copy.marker.detachedFilename = current.filename
                        _ = try PendingUploadQueue.update(copy)
                    }
                    recordedFile = try rememberRemovedDocumentsFile(removedFile.file)
                    revocationAttempted = true
                    let ready = try PendingLocalSaveStore.revokeForRemoval(current.id, nonBlocking: true)
                    revocationObserved = true
                    guard ready else { recoveryRequired = true; return .rejected }
                    let sharedLegacy = current.legacyKeychainFilename.map { name in
                        rows.contains { $0.id != current.id && $0.legacyKeychainFilename == name }
                    } ?? false
                    let receipt = RemovalReceipt(reference: current, wasActive: activeAutoFillDatabase(in: rows)?.id == current.id, sharedLegacy: sharedLegacy)
                    rows.remove(at: index)
                    return .write(receipt)
                }
                switch result {
                case .durable(let receipt):
                    let removed = receipt.reference
                    KeychainService.deleteCompositeKey(for: removed.id)
                    if let legacy = removed.legacyKeychainFilename, !receipt.sharedLegacy { KeychainService.deleteLegacyCompositeKey(forFilename: legacy) }
                    QuickUnlockKeychain.removeMasterKeyEntry(for: removed.id)
                    try? FileManager.default.removeItem(at: cacheLocation(for: removed))
                    try? FileManager.default.removeItem(at: databaseBackupDirectoryURL(for: removed))
                    if activeAutoFillDatabaseID == removed.id { activeAutoFillDatabaseID = nil }
                    CredentialIdentityStoreManager.removeIdentities(forDatabase: removed.id, includingLegacyIdentifiers: receipt.wasActive)
                    return .removed
                case .visibleUnconfirmed: return .visibleUnconfirmed
                case .missing: return rowMissing ? .alreadyMissing : .notPublished
                case .rejected:
                    if let cloudRecoveryCanKeepCopies {
                        return .cloudRecoveryRequired(canKeepRecoveryCopies: cloudRecoveryCanKeepCopies)
                    }
                    return recoveryRequired ? .recoveryRequired : .rejected
                case .notPublished:
                    if revocationObserved { return .revokedRegistryNotPublished }
                    return revocationAttempted ? .revocationUnconfirmed : .notPublished
                case .noop: return .rejected
                }
            }
        } catch { return .notPublished }
    }

    #if DEBUG
    @discardableResult
    static func remove(id: UUID) -> Bool {
        guard AppGroupContainer.isRedirectedForTesting else { return false }
        guard let rows = try? readDatabasesStrict() else { return false }
        guard let reference = rows.first(where: { $0.id == id }) else { return true }
        let outcome = remove(observed: reference)
        return outcome == .removed || outcome == .alreadyMissing
    }
    #endif

    #if DEBUG
    static func testUpsert(_ reference: DatabaseReference) {
        guard AppGroupContainer.isRedirectedForTesting, !PendingLocalSaveStore.isRevoked(reference.id) else { return }
        let result = mutateRegistry(onMissing: { [] }) { rows -> RegistryDecision<[DatabaseReference]> in
            if let index = rows.firstIndex(where: { $0.id == reference.id }) { rows[index] = reference }
            else { rows.append(reference) }
            return .write(rows)
        }
        if case .durable(let rows) = result, let active = activeAutoFillDatabaseID,
           !rows.contains(where: { $0.id == active && $0.autoFillEnabled }) { activeAutoFillDatabaseID = nil }
    }
    #endif

    struct DurableKeyFileAssociationReceipt: Sendable {
        let databaseID: UUID
        let operationID: UUID
        let association: PendingLocalSaveStore.KeyFileAssociation
        let registrySHA512: Data
        fileprivate init(databaseID: UUID, operationID: UUID, association: PendingLocalSaveStore.KeyFileAssociation, registrySHA512: Data) {
            self.databaseID = databaseID
            self.operationID = operationID
            self.association = association
            self.registrySHA512 = registrySHA512
        }
    }

    enum KeyFileAssociationPublication: Sendable {
        case durable(DurableKeyFileAssociationReceipt)
        case publishedWithoutConfirmedDurability
        case notPublished
    }

    static func publishKeyFileAssociation(
        for id: UUID, operationID: UUID, association: PendingLocalSaveStore.KeyFileAssociation,
        expectedTarget: PendingLocalSaveStore.TargetIdentity? = nil,
        expectedWitness: PendingLocalSaveStore.KeyEpochEvidence? = nil, expectedAssociationVersion: UUID? = nil,
        io: DurableFileWriteIO = .init()
    ) -> KeyFileAssociationPublication {
        withStateLock {
            guard let anchor = AppGroupContainer.resolvedURL,
                  let observed = try? JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL))
                    .first(where: { $0.id == id }) else { return .notPublished }
            let target: URL
            if let bookmark = observed.bookmarkData {
                guard let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmark) else { return .notPublished }
                target = resolved.url
            } else { target = cacheLocation(for: observed) }
            let access = observed.bookmarkData != nil && target.startAccessingSecurityScopedResource()
            defer { if access { target.stopAccessingSecurityScopedResource() } }
            guard let expectedTarget = expectedTarget ?? (try? PendingLocalSaveStore.targetIdentity(at: target)) else { return .notPublished }
            var coordinatorError: NSError?
            var outcome: DurableWriteOutcome?
            var publishedBytes: Data?
            // List lock -> target/registry coordination -> owner flock, with both resources held through publication.
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], writingItemAt: databaseListURL,
                options: .forReplacing, error: &coordinatorError) { protectedTarget, registry in
                do {
                    var references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let index = references.firstIndex(where: { $0.id == id }),
                          references[index].bookmarkData == observed.bookmarkData,
                          references[index].keyFileBookmarkData == observed.keyFileBookmarkData,
                          references[index].keyFileFilename == observed.keyFileFilename,
                          references[index].lastMasterKeyChangeAt == observed.lastMasterKeyChangeAt else {
                        throw PendingLocalSaveStore.OwnershipError.sourceChanged
                    }
                    references[index].keyFileBookmarkData = association.bookmarkData
                    references[index].keyFileFilename = association.filename
                    references[index].lastMasterKeyChangeAt = association.changedAt
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let bytes = try encoder.encode(references)
                    outcome = try PendingLocalSaveStore.withAssociationPublicationAuthorization(
                        for: id, operationID: operationID, association: association,
                        expectedWitness: expectedWitness, expectedAssociationVersion: expectedAssociationVersion, nonBlocking: true, observeTarget: {
                            let identity = try PendingLocalSaveStore.targetIdentity(at: protectedTarget)
                            guard identity == expectedTarget else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                            return (identity, FileDigest.sha512(try Data(contentsOf: protectedTarget)))
                        }
                    ) { writeWithDurabilityOutcome(bytes, to: registry, directoryAnchor: anchor, io: io) }
                    publishedBytes = bytes
                } catch { outcome = .notPublished(error) }
            }
            switch outcome {
            case .durable?:
                guard coordinatorError == nil, let bytes = publishedBytes else { return .publishedWithoutConfirmedDurability }
                return .durable(DurableKeyFileAssociationReceipt(databaseID: id, operationID: operationID,
                    association: association, registrySHA512: FileDigest.sha512(bytes)))
            case .publishedWithoutConfirmedDurability?: return .publishedWithoutConfirmedDurability
            case .notPublished?, nil: return .notPublished
            }
        }
    }

    static func certifySettledKeyWitness(
        for expected: DatabaseReference, evidence: PendingLocalSaveStore.KeyEpochEvidence,
        io: PendingLocalSaveStore.StorageIO = .init()
    ) -> PendingLocalSaveStore.ResolutionOutcome {
        withStateLock {
            guard let anchor = AppGroupContainer.resolvedURL, let target = LocalDatabaseSaver.resolveLocation(for: expected, renewBookmark: false)?.url else { return .retainedForRecovery }
            let access = target.startAccessingSecurityScopedResource()
            defer { if access { target.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            var resolution = PendingLocalSaveStore.ResolutionOutcome.retainedForRecovery
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], writingItemAt: databaseListURL,
                options: [], error: &error) { original, registry in
                do {
                    let data = try Data(contentsOf: registry)
                    let references = try JSONDecoder().decode([DatabaseReference].self, from: data)
                    guard let current = references.first(where: { $0.id == expected.id }),
                          PendingLocalSaveStore.PreferenceObservation(expected).matches(current),
                          current.keyFileBookmarkData == evidence.association.bookmarkData,
                          current.keyFileFilename == evidence.association.filename,
                          current.lastMasterKeyChangeAt == evidence.association.changedAt else { return }
                    let handle = try FileHandle(forUpdating: registry)
                    defer { try? handle.close() }
                    try handle.synchronize()
                    try createDurableDirectory(at: registry.deletingLastPathComponent(), anchor: anchor)
                    let proof = DurableKeyFileAssociationReceipt(databaseID: expected.id, operationID: evidence.epochID,
                        association: evidence.association, registrySHA512: FileDigest.sha512(data))
                    resolution = PendingLocalSaveStore.certifySettledWitness(evidence, for: expected.id, associationProof: proof,
                        observeTarget: { (try PendingLocalSaveStore.targetIdentity(at: original), FileDigest.sha512(try Data(contentsOf: original))) }, io: io)
                } catch {}
            }
            return error != nil && resolution == .resolved ? .resolvedVisibleWithoutConfirmedDurability : resolution
        }
    }

    enum KeyFilePreferenceOutcome: Sendable, Equatable {
        case saved, notPublished, recoveryRequired, cloudRecoveryRequired, publishedWithoutConfirmedDurability, rejected
    }
    struct KeyFilePreferenceError: Error, LocalizedError {
        let outcome: KeyFilePreferenceOutcome
        var errorDescription: String? {
            switch outcome {
            case .saved: nil
            case .notPublished: String(localized: "The key-file preference was not changed. The database master key is unchanged. Review Database Details before trying again.")
            case .rejected: String(localized: "This key-file preference is out of date or blocked by local recovery. Review Database Details before choosing again.")
            case .recoveryRequired: String(localized: "Confirm the intended key-file preference in Database Details. The database master key is unchanged.")
            case .cloudRecoveryRequired: String(localized: "This cloud operation needs recovery. Keep both the original and new keys if you changed them. Export the encrypted copy from Settings → Cloud → Cloud Recovery before trying another operation. An uncertain request will not be sent again automatically.")
            case .publishedWithoutConfirmedDurability: String(localized: "The key-file preference was published, but its record is not fully confirmed. Review Database Details before another selection. The database master key is unchanged.")
            }
        }
    }
    struct KeyFilePreferenceIO: Sendable {
        var registry = DurableFileWriteIO()
        var owner = PendingLocalSaveStore.StorageIO()
    }
    struct DurablePreferenceReceipt: Sendable {
        let intent: PendingLocalSaveStore.PreferenceIntent
        let registrySHA512: Data
        fileprivate init(intent: PendingLocalSaveStore.PreferenceIntent, registrySHA512: Data) {
            self.intent = intent
            self.registrySHA512 = registrySHA512
        }
    }

    static func localReferenceEqualityDiagnostic(_ expected: DatabaseReference, current: DatabaseReference?) -> String {
        guard let current else { return "registered=false id=false bookmark=false date=false keyBookmark=false keyFilename=false cloud=false hardware=false filename=false legacy=false" }
        let observed = PendingLocalSaveStore.PreferenceObservation(current)
        let before = PendingLocalSaveStore.PreferenceObservation(expected)
        return "registered=true id=\(current.id == expected.id) bookmark=\(current.bookmarkData == expected.bookmarkData) date=\(current.lastMasterKeyChangeAt == expected.lastMasterKeyChangeAt) keyBookmark=\(current.keyFileBookmarkData == expected.keyFileBookmarkData) keyFilename=\(current.keyFileFilename == expected.keyFileFilename) cloud=\(observed.cloudIdentity == before.cloudIdentity) hardware=\(current.hardwareKey == expected.hardwareKey) filename=\(current.filename == expected.filename) legacy=\(current.legacyKeychainFilename == expected.legacyKeychainFilename)"
    }

    static func currentSameEpochPreference(for reference: DatabaseReference,
        onFailure: (String, Error) -> Void = { _, _ in }
    ) throws -> PendingLocalSaveStore.KeyFilePreference {
        var phase = "same-epoch-owner"
        do {
            let owner = try PendingLocalSaveStore.recovery(for: reference.id)
            guard !owner.ownerUnavailable, !owner.isRevoked else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
            if owner.keyEvidence == nil {
                let current = databases.first(where: { $0.id == reference.id })
                phase = "same-epoch-reference " + localReferenceEqualityDiagnostic(reference, current: current)
                    + " ownerUnavailable=\(owner.ownerUnavailable) revoked=\(owner.isRevoked) unresolved=\(owner.needsRecovery)"
                guard let current else { return PendingLocalSaveStore.KeyFilePreference(reference) }
                let preference = PendingLocalSaveStore.KeyFilePreference(current)
                guard PendingLocalSaveStore.PreferenceObservation(reference).matches(current, preference: preference) else {
                    throw PendingLocalSaveStore.OwnershipError.sourceChanged
                }
                return preference
            }
            phase = "same-epoch-registry"
            return try withStateLock {
                var error: NSError?
                var result: Result<PendingLocalSaveStore.KeyFilePreference, Error>?
                NSFileCoordinator().coordinate(readingItemAt: databaseListURL, options: [], error: &error) { url in
                    result = Result {
                        let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: url))
                        let current = references.first(where: { $0.id == reference.id })
                        phase = "same-epoch-accessor " + localReferenceEqualityDiagnostic(reference, current: current)
                        guard let current, PendingLocalSaveStore.PreferenceObservation(reference).matches(current,
                                  preference: PendingLocalSaveStore.KeyFilePreference(current)) else {
                            throw PendingLocalSaveStore.OwnershipError.sourceChanged
                        }
                        try PendingLocalSaveStore.validateReferenceAssociation(current)
                        return PendingLocalSaveStore.KeyFilePreference(current)
                    }
                }
                if let error {
                    switch result {
                    case .success?: phase = "same-epoch-coordination-after-success"
                    case .failure?: phase = "same-epoch-coordination-after-failure"
                    case nil: phase = "same-epoch-coordination-before-accessor"
                    }
                    throw error
                }
                guard let result else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                return try result.get()
            }
        } catch { onFailure(phase, error); throw error }
    }

    static func publishRegistryKeyFilePreference(
        for expected: DatabaseReference, desired: PendingLocalSaveStore.KeyFilePreference,
        io: DurableFileWriteIO = .init(), localToken: PendingLocalSaveStore.PreferenceToken? = nil,
        canPublish: @Sendable () -> Bool = { true }
    ) -> KeyFilePreferenceOutcome {
        guard expected.isCloudBacked || localToken != nil, let anchor = AppGroupContainer.resolvedURL else { return .rejected }
        do {
            var error: NSError?
            var outcome: DurableWriteOutcome?
            var unchanged = false
            NSFileCoordinator().coordinate(writingItemAt: databaseListURL, options: .forReplacing, error: &error) { registry in
                guard stateLock.try() else { return }
                defer { stateLock.unlock() }
                do {
                    guard canPublish() else { return }
                    var references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let index = references.firstIndex(where: { $0.id == expected.id }),
                          PendingLocalSaveStore.PreferenceObservation(expected).matches(references[index]) else { return }
                    if references[index].keyFileBookmarkData == desired.bookmarkData && references[index].keyFileFilename == desired.filename {
                        if let localToken {
                            try PendingLocalSaveStore.withIdlePreferenceAuthorization(localToken, nonBlocking: true) {
                                guard canPublish() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                            }
                        }
                        unchanged = true
                        return
                    }
                    references[index].keyFileBookmarkData = desired.bookmarkData
                    references[index].keyFileFilename = desired.filename
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let bytes = try encoder.encode(references)
                    if let localToken {
                        outcome = try PendingLocalSaveStore.withIdlePreferenceAuthorization(localToken, nonBlocking: true) {
                            writeWithDurabilityOutcome(bytes, to: registry, directoryAnchor: anchor, io: io)
                        }
                    } else { outcome = writeWithDurabilityOutcome(bytes, to: registry, directoryAnchor: anchor, io: io) }
                } catch { outcome = .notPublished(error) }
            }
            if unchanged { return error == nil ? .saved : .notPublished }
            switch outcome {
            case .durable?: return error == nil ? .saved : .publishedWithoutConfirmedDurability
            case .publishedWithoutConfirmedDurability?: return .publishedWithoutConfirmedDurability
            case .notPublished?: return .notPublished
            case nil: return .rejected
            }
        }
    }

    static func publishCloudKeyFilePreference(
        for expected: DatabaseReference, desired: PendingLocalSaveStore.KeyFilePreference,
        io: DurableFileWriteIO = .init(), queue: PendingUploadQueue.Environment = .live,
        canPublish: @Sendable () -> Bool = { true }
    ) -> KeyFilePreferenceOutcome {
        guard expected.isCloudBacked else { return .rejected }
        do {
            return try PendingUploadQueue.withCommitLock(for: expected.id, environment: queue, nonBlocking: true) {
                guard canPublish(), let current = try readDatabasesStrict().first(where: { $0.id == expected.id }),
                      PendingLocalSaveStore.PreferenceObservation(expected).matches(current) else { return .rejected }
                let records = try PendingUploadQueue.readJournal(for: current.id, environment: queue)
                if PendingLocalSaveStore.KeyFilePreference(current) == desired {
                    if records.contains(where: { $0.marker.binding?.alternatePreferenceFingerprint != nil }) {
                        return .publishedWithoutConfirmedDurability
                    }
                    return publishRegistryKeyFilePreference(for: current, desired: desired, io: io, canPublish: canPublish)
                }
                guard !records.contains(where: { $0.marker.binding?.alternatePreferenceFingerprint != nil }) else {
                    return .cloudRecoveryRequired
                }
                var target = current
                target.keyFileBookmarkData = desired.bookmarkData
                target.keyFileFilename = desired.filename
                guard records.allSatisfy({ $0.marker.keyChange == nil && CloudJournalDecision.state(of: $0.marker) == .ready
                    && PendingUploadQueue.hasBoundAuthority($0, reference: current) }) else { return .cloudRecoveryRequired }
                var rebound: [PendingUploadQueue.StoredMarker] = []
                for var stored in records {
                    guard canPublish(), let binding = stored.marker.binding else { return .rejected }
                    _ = try PendingUploadQueue.readImmutablePayload(stored, environment: queue)
                    stored.marker.binding = try binding.authorizingPreferenceChange(from: current, to: target, operationID: stored.id)
                    rebound.append(try PendingUploadQueue.update(stored, environment: queue))
                }
                guard canPublish() else { return .rejected }
                let outcome = publishRegistryKeyFilePreference(for: current, desired: desired, io: io, canPublish: canPublish)
                guard outcome == .saved else { return outcome }
                do {
                    for var stored in rebound {
                        guard let binding = stored.marker.binding else { throw SaveError.saveContextUnavailable }
                        stored.marker.binding = try binding.finalizingPreferenceChange(reference: target, operationID: stored.id)
                        _ = try PendingUploadQueue.update(stored, environment: queue)
                    }
                } catch { return .publishedWithoutConfirmedDurability }
                return .saved
            }
        } catch { return .notPublished }
    }

    // Caller holds the cloud commit lock while confirming the registry and retiring the transition.
    static func recoverCloudKeyFilePreference(for databaseID: UUID, queue: PendingUploadQueue.Environment = .live,
                                              io: DurableFileWriteIO = .init()) throws {
        let records = try PendingUploadQueue.readJournal(for: databaseID, environment: queue)
        let pending = records.filter { $0.marker.binding?.alternatePreferenceFingerprint != nil }
        guard !pending.isEmpty else { return }
        guard pending.allSatisfy({ $0.marker.keyChange == nil && $0.marker.confirmedAt == nil
            && $0.marker.isPayloadFinalized == true && $0.marker.requiresLocalRecovery != true
            && ($0.marker.uploadAttemptID == nil || $0.marker.attemptIsFenced == true) }) else {
            throw SaveError.saveContextUnavailable
        }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: databaseListURL, options: [], error: &coordinationError) { registry in
            result = Result {
                guard stateLock.try() else { throw SaveError.saveContextUnavailable }
                defer { stateLock.unlock() }
                let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                guard let current = references.first(where: { $0.id == databaseID }), current.isCloudBacked,
                      pending.allSatisfy({ PendingUploadQueue.hasBoundAuthority($0, reference: current) }) else {
                    throw SaveError.saveContextUnavailable
                }
                let handle = try FileHandle(forUpdating: registry)
                defer { try? handle.close() }
                try io.synchronizeFile(handle.fileDescriptor)
                try io.synchronizeParent(registry.deletingLastPathComponent())
                for var stored in pending {
                    guard let binding = stored.marker.binding else { throw SaveError.saveContextUnavailable }
                    _ = try PendingUploadQueue.readImmutablePayload(stored, environment: queue)
                    stored.marker.binding = try binding.finalizingPreferenceChange(reference: current, operationID: stored.id)
                    _ = try PendingUploadQueue.update(stored, environment: queue)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SaveError.saveContextUnavailable }
        try result.get()
    }

    static func prepareKeyFilePreference(for reference: DatabaseReference) throws -> PendingLocalSaveStore.PreferenceToken {
        guard !reference.isCloudBacked else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
        do {
            var error: NSError?
            var result: Result<PendingLocalSaveStore.PreferenceToken, Error>?
            NSFileCoordinator().coordinate(readingItemAt: databaseListURL, options: [], error: &error) { url in
                result = Result {
                    guard stateLock.try() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    defer { stateLock.unlock() }
                    let observed = PendingLocalSaveStore.PreferenceObservation(reference)
                    let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: url))
                    guard let current = references.first(where: { $0.id == reference.id }), observed.matches(current) else {
                        throw PendingLocalSaveStore.OwnershipError.sourceChanged
                    }
                    return try PendingLocalSaveStore.capturePreference(observed, nonBlocking: true)
                }
            }
            if let error { throw error }
            guard let result else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
            return try result.get()
        }
    }

    static func recoverKeyFilePreference(
        _ intent: PendingLocalSaveStore.PreferenceIntent, io: KeyFilePreferenceIO = .init()
    ) -> KeyFilePreferenceOutcome {
        do {
            let token = try PendingLocalSaveStore.recoverPreferenceToken(intent)
            return publishKeyFilePreference(token, desired: intent.desired, recovering: true, io: io)
        } catch { return .rejected }
    }

    static func publishKeyFilePreference(
        _ token: PendingLocalSaveStore.PreferenceToken, desired: PendingLocalSaveStore.KeyFilePreference,
        recovering: Bool = false, io: KeyFilePreferenceIO = .init(), canPublish: @Sendable () -> Bool = { true }
    ) -> KeyFilePreferenceOutcome {
        if token.witness == nil {
            guard let reference = databases.first(where: { token.observation.matches($0) }) else { return .rejected }
            return publishRegistryKeyFilePreference(for: reference, desired: desired, io: io.registry, localToken: token, canPublish: canPublish)
        }
        do {
            guard let anchor = AppGroupContainer.resolvedURL else { return .rejected }
            let target: URL?
            if token.witness != nil {
                if let bookmark = token.observation.targetBookmarkData {
                    guard let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmark) else { return .rejected }
                    target = resolved.url
                } else { target = cacheURL(for: token.observation.databaseID) }
            } else { target = nil }
            let access = target.map { token.observation.targetBookmarkData != nil && $0.startAccessingSecurityScopedResource() } ?? false
            defer { if access { target?.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            var attempt: PendingLocalSaveStore.PreferencePublication?
            var rejected = false
            func publish(target: URL?, registry: URL) {
                guard stateLock.try() else { rejected = true; return }
                defer { stateLock.unlock() }
                do {
                    guard canPublish() else { rejected = true; return }
                    var references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let index = references.firstIndex(where: { $0.id == token.observation.databaseID }),
                          token.observation.matches(references[index]) || (recovering && token.observation.matches(references[index], preference: desired)) else {
                        throw PendingLocalSaveStore.OwnershipError.sourceChanged
                    }
                    references[index].keyFileBookmarkData = desired.bookmarkData
                    references[index].keyFileFilename = desired.filename
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let bytes = try encoder.encode(references)
                    attempt = try PendingLocalSaveStore.withPreferencePublication(token, desired: desired, observeTarget: {
                        guard let target else { return nil }
                        return (try PendingLocalSaveStore.targetIdentity(at: target), FileDigest.sha512(try Data(contentsOf: target)))
                    }, io: io.owner, nonBlocking: true) { writeWithDurabilityOutcome(bytes, to: registry, directoryAnchor: anchor, io: io.registry) }
                } catch { rejected = true }
            }
            let coordinator = NSFileCoordinator()
            if let target {
                coordinator.coordinate(readingItemAt: target, options: [], writingItemAt: databaseListURL,
                    options: .forReplacing, error: &error) { target, registry in publish(target: target, registry: registry) }
            } else {
                coordinator.coordinate(writingItemAt: databaseListURL, options: .forReplacing, error: &error) { publish(target: nil, registry: $0) }
            }
            if rejected { return .rejected }
            guard let attempt else { return .notPublished }
            switch attempt {
            case .notStarted: return .notPublished
            case .intentUnconfirmed: return .recoveryRequired
            case .registry(let outcome, let intent):
                switch outcome {
                case .notPublished:
                    return PendingLocalSaveStore.releaseUnpublishedPreference(intent, io: io.owner) == .resolved ? .notPublished : .recoveryRequired
                case .publishedWithoutConfirmedDurability: return .publishedWithoutConfirmedDurability
                case .durable:
                    guard error == nil else { return .publishedWithoutConfirmedDurability }
                    var completionError: NSError?
                    var completion = PendingLocalSaveStore.ResolutionOutcome.retainedForRecovery
                    coordinator.coordinate(readingItemAt: databaseListURL, options: [], error: &completionError) { registry in
                        guard stateLock.try() else { return }
                        defer { stateLock.unlock() }
                        do {
                            let data = try Data(contentsOf: registry)
                            let references = try JSONDecoder().decode([DatabaseReference].self, from: data)
                            guard let current = references.first(where: { $0.id == token.observation.databaseID }),
                                  token.observation.matches(current, preference: desired) else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
                            let handle = try FileHandle(forUpdating: registry)
                            defer { try? handle.close() }
                            try handle.synchronize()
                            try createDurableDirectory(at: registry.deletingLastPathComponent(), anchor: anchor)
                            let proof = DurablePreferenceReceipt(intent: intent, registrySHA512: FileDigest.sha512(data))
                            completion = PendingLocalSaveStore.finishPreference(token, proof: proof, io: io.owner, nonBlocking: true)
                        } catch {}
                    }
                    return completion == .resolved && completionError == nil ? .saved : .publishedWithoutConfirmedDurability
                }
            }
        }
    }

    @discardableResult
    static func setKeyFileAssociation(
        for expected: DatabaseReference, bookmarkData: Data?, filename: String?, masterKeyChangedAt: Date,
        io: DurableFileWriteIO = .init()
    ) -> KeyFilePreferenceOutcome {
        guard let token = try? PendingLocalSaveStore.capturePreference(.init(expected)) else { return .recoveryRequired }
        let result = mutateRegistry(io: io, authorize: { operation in
            try PendingLocalSaveStore.withIdlePreferenceAuthorization(token, nonBlocking: true, operation)
        }) { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == expected.id }) else { return .missing }
            guard token.observation.matches(rows[index]), rows[index].hardwareKey == expected.hardwareKey,
                  rows[index].legacyKeychainFilename == expected.legacyKeychainFilename else { return .rejected }
            if rows[index].keyFileBookmarkData == bookmarkData, rows[index].keyFileFilename == filename,
               rows[index].lastMasterKeyChangeAt == masterKeyChangedAt { return .noop(()) }
            rows[index].keyFileBookmarkData = bookmarkData
            rows[index].keyFileFilename = filename
            rows[index].lastMasterKeyChangeAt = masterKeyChangedAt
            return .write(())
        }
        switch result {
        case .durable, .noop: return .saved
        case .notPublished: return .notPublished
        case .visibleUnconfirmed: return .publishedWithoutConfirmedDurability
        case .missing, .rejected: return .rejected
        }
    }

    /// Applies `mutate` to the cloud sync metadata of the *currently stored*
    /// copy, leaving every other stored field alone. Anything that learns
    /// cloud state across an `await` must use this instead of `update(_:)`,
    /// which writes back a whole pre-round-trip reference and so rolls back a
    /// save or drain that completed inside the window.
    ///
    /// If the stored state has moved past `observed`, nothing is written and
    /// the newer stored reference is returned to adopt. Nil when the database
    /// is unlisted, not cloud-backed, or the list failed to persist — a
    /// revision that never reached disk must not be acted on.
    @discardableResult
    static func updateCloudSyncMetadata(for id: UUID, ifUnchangedFrom observed: CloudSyncMetadata,
        observedReference: DatabaseReference,
        mutate: (inout CloudSyncMetadata) -> Void) -> DatabaseReference? {
        switch compareAndUpdateCloudSyncMetadata(for: id, ifUnchangedFrom: observed, observedReference: observedReference, mutate: mutate) {
        case .published(let reference), .mismatch(let reference): reference
        case .removed, .writeFailed, .visibleUnconfirmed: nil
        }
    }

    static func addCreatedCloud(_ reference: DatabaseReference) throws {
        try requireRegistryInitialization()
        let result = mutateRegistry { rows -> RegistryDecision<Void> in
            guard !rows.contains(where: { $0.id == reference.id }) else { return .rejected }
            try validateCreatedCloud(reference, in: rows)
            rows.append(reference)
            return .write(())
        }
        switch result {
        case .durable, .noop: return
        case .notPublished(let error): throw error
        case .visibleUnconfirmed(_, let error): throw RegistryWriteError.visibleUnconfirmed(error)
        case .missing, .rejected: throw RegistryWriteError.unavailable
        }
    }

    enum CloudCreationRegistrationOutcome {
        case durable, rejected, notPublished(Error), visibleUnconfirmed(Error)
    }

    static func registerCloudCreation(_ snapshot: PendingUploadQueue.StoredCreation, bytes: Data,
        queue: PendingUploadQueue.Environment = .live, registryIO: DurableFileWriteIO = .init()) -> CloudCreationRegistrationOutcome {
        guard snapshot.intent.phase == .confirmed, let reference = snapshot.intent.receipt,
              FileDigest.sha512(bytes) == snapshot.intent.payloadSHA512,
              reference.cloudSyncMetadata?.localHeadOperationID == snapshot.intent.operationID else { return .rejected }
        do {
            try requireRegistryInitialization()
            guard let anchor = AppGroupContainer.resolvedURL else { return .notPublished(CocoaError(.fileWriteNoPermission)) }
            let lease = try PendingLocalSaveStore.captureCacheReadLease(for: reference)
            let cache = cacheLocation(for: reference)
            let stage = PendingUploadQueue.creationStageURL(snapshot.intent.operationID, queue)
            try createDurableDirectory(at: cache.deletingLastPathComponent(), anchor: anchor)
            return try PendingUploadQueue.withConfirmedCreation(snapshot, environment: queue) {
                var coordinationError: NSError?
                var outcome: CloudCreationRegistrationOutcome = .rejected
                var cacheOwned = false
                NSFileCoordinator().coordinate(writingItemAt: cache, options: [], writingItemAt: databaseListURL, options: [], error: &coordinationError) { target, registry in
                    guard stateLock.try() else { outcome = .rejected; return }
                    defer { stateLock.unlock() }
                    do {
                        guard var rows = try readRegistry(at: registry) else { return }
                        let existing = rows.first(where: { $0.id == reference.id })
                        if var existing {
                            existing.nickname = reference.nickname
                            existing.colorTag = reference.colorTag
                            existing.lastOpenedAt = reference.lastOpenedAt
                            guard existing == reference else { return }
                        }
                        guard !rows.contains(where: { $0.id != reference.id && cacheLocation(for: $0).standardizedFileURL == cache.standardizedFileURL }) else { return }
                        if existing == nil { try validateCreatedCloud(reference, in: rows) }
                        outcome = try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: snapshot.intent.payloadSHA512, lease: lease, nonBlocking: true) {
                            guard try Data(contentsOf: stage) == bytes else { return .rejected }
                            let linkResult = Darwin.link(stage.path, target.path)
                            if linkResult != 0 && errno != EEXIST { return .notPublished(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
                            if linkResult == 0 { cacheOwned = true }
                            let stagedAttributes = try FileManager.default.attributesOfItem(atPath: stage.path)
                            let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
                            guard let stageDevice = stagedAttributes[.systemNumber] as? NSNumber,
                                  let stageInode = stagedAttributes[.systemFileNumber] as? NSNumber,
                                  stageDevice == targetAttributes[.systemNumber] as? NSNumber,
                                  stageInode == targetAttributes[.systemFileNumber] as? NSNumber,
                                  try Data(contentsOf: target) == bytes else { return .rejected }
                            cacheOwned = true
                            let handle = try FileHandle(forUpdating: target)
                            defer { try? handle.close() }
                            try registryIO.synchronizeFile(handle.fileDescriptor)
                            try registryIO.synchronizeParent(target.deletingLastPathComponent())
                            if existing == nil { rows.append(reference) }
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            switch writeWithDurabilityOutcome(try encoder.encode(normalized(rows)), to: registry, directoryAnchor: anchor, io: registryIO) {
                            case .durable: return .durable
                            case .notPublished(let error): return .visibleUnconfirmed(error)
                            case .publishedWithoutConfirmedDurability(let error): return .visibleUnconfirmed(error)
                            }
                        }
                    } catch { outcome = cacheOwned ? .visibleUnconfirmed(error) : .notPublished(error) }
                }
                if let error = coordinationError {
                    switch outcome { case .durable, .visibleUnconfirmed: return .visibleUnconfirmed(error); default: return .notPublished(error) }
                }
                return outcome
            }
        } catch { return .notPublished(error) }
    }

    enum CloudMetadataUpdateResult { case published(DatabaseReference), mismatch(DatabaseReference), removed, writeFailed, visibleUnconfirmed(DatabaseReference) }
    static func compareAndUpdateCloudSyncMetadata(
        for id: UUID,
        ifUnchangedFrom observed: CloudSyncMetadata,
        observedReference: DatabaseReference,
        confirmUnchanged: Bool = false,
        io: DurableFileWriteIO = .init(),
        mutate: (inout CloudSyncMetadata) -> Void
    ) -> CloudMetadataUpdateResult {
        var mismatched: DatabaseReference?
        let result = mutateRegistry(io: io, confirmUnchanged: confirmUnchanged) { rows -> RegistryDecision<DatabaseReference> in
            guard let index = rows.firstIndex(where: { $0.id == id }), let stored = rows[index].cloudSyncMetadata else { return .missing }
            guard stored.provider == observed.provider, stored.accountId == observed.accountId, stored.fileId == observed.fileId,
                  stored.remoteRev == observed.remoteRev, stored.remoteContentHash == observed.remoteContentHash,
                  stored.localHeadOperationID == observed.localHeadOperationID, stored.keyEpoch == observed.keyEpoch,
                  observedReference.id == id, PendingLocalSaveStore.PreferenceObservation(observedReference).matches(rows[index]),
                  observedReference.hardwareKey == rows[index].hardwareKey,
                  observedReference.legacyKeychainFilename == rows[index].legacyKeychainFilename else {
                mismatched = rows[index]
                return .rejected
            }
            rows[index].updateCloudSyncMetadata(mutate)
            guard let updated = rows[index].cloudSyncMetadata else { return .rejected }
            if updated == stored { return .noop(rows[index]) }
            return .write(rows[index])
        }
        switch result {
        case .durable(let reference), .noop(let reference): return .published(reference)
        case .visibleUnconfirmed(let reference, _): return .visibleUnconfirmed(reference)
        case .missing: return .removed
        case .rejected: return mismatched.map(CloudMetadataUpdateResult.mismatch) ?? .writeFailed
        case .notPublished: return .writeFailed
        }
    }

    /// Caller holds the database commit lock; only local publication fields may change.
    static func publishCloudLocalCommit(
        for id: UUID, operationID: UUID, binding: PendingUploadQueue.JournalBinding, io: DurableFileWriteIO = .init()
    ) -> CloudMetadataUpdateResult {
        var mismatch: DatabaseReference?
        let result = mutateRegistry(io: io, confirmUnchanged: true) { rows -> RegistryDecision<DatabaseReference> in
            guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isCloudBacked else { return .missing }
            let current = rows[index]
            guard binding.databaseID == id, binding.operationID == operationID,
                  let baseline = binding.baseline else {
                mismatch = current; return .rejected
            }
            if current.cloudSyncMetadata?.localHeadOperationID == operationID {
                guard binding.matchesOrdinaryAuthority(reference: current, operationID: operationID) else { mismatch = current; return .rejected }
                return .noop(current)
            }
            guard binding.matchesAuthority(reference: current, operationID: operationID) else { mismatch = current; return .rejected }
            guard current.cloudSyncMetadata?.localHeadOperationID == baseline.headOperationID else { mismatch = current; return .rejected }
            rows[index].updateCloudSyncMetadata {
                $0.localHeadOperationID = operationID
                $0.lastSyncedAt = nil
            }
            return .write(rows[index])
        }
        switch result {
        case .durable(let reference), .noop(let reference): return .published(reference)
        case .visibleUnconfirmed(let reference, _): return .visibleUnconfirmed(reference)
        case .missing: return .removed
        case .rejected: return mismatch.map(CloudMetadataUpdateResult.mismatch) ?? .writeFailed
        case .notPublished: return .writeFailed
        }
    }

    enum CloudRekeyPublication {
        case durable(DatabaseReference)
        case rejected(Error)
        case cacheUnconfirmed(Error)
        case registryNotPublished(Error)
        case registryUnconfirmed(Error)
        case retirementUnconfirmed(DatabaseReference)
    }

    /// The marker snapshot is captured before coordination and reread under the commit lock.
    static func publishConfirmedCloudRekey(
        _ snapshot: PendingUploadQueue.StoredMarker, cache: URL, bytes: Data,
        queue: PendingUploadQueue.Environment = .live, registryIO: DurableFileWriteIO = .init(),
        replacementIO: LocalDatabaseSaver.ReplacementIO = .init(),
        backup: (DatabaseReference, Data) throws -> Void,
        deleteOldKeys: (DatabaseReference) -> Void
    ) -> CloudRekeyPublication {
        guard let anchor = AppGroupContainer.resolvedURL,
              let binding = snapshot.marker.binding, binding.isRecognized, binding.intendedPreferenceFingerprint != nil,
              let rekey = snapshot.marker.keyChange, let committedAt = snapshot.marker.confirmedAt,
              let intendedSHA = snapshot.marker.intendedPayloadSHA512,
              FileDigest.sha512(bytes) == intendedSHA else { return .rejected(SaveError.saveContextUnavailable) }
        let lease: PendingLocalSaveStore.CacheReadLease
        let rekeyRecovery: PendingLocalSaveStore.CloudRekeyRecoveryEpoch?
        do {
            guard let observed = try readDatabasesStrict().first(where: { $0.id == snapshot.marker.databaseId }) else {
                return .rejected(SaveError.saveContextUnavailable)
            }
            let initial = binding.matchesOriginal(reference: observed, operationID: snapshot.id)
            let installed = binding.matchesInstalled(reference: observed, operationID: snapshot.id, keyChange: rekey, committedAt: committedAt)
            guard initial || installed else { return .rejected(SaveError.saveContextUnavailable) }
            rekeyRecovery = installed ? PendingLocalSaveStore.CloudRekeyRecoveryEpoch(binding: binding, reference: observed,
                operationID: snapshot.id, change: rekey, committedAt: committedAt) : nil
            lease = try PendingLocalSaveStore.captureCacheReadLease(for: observed, rekeyRecovery: rekeyRecovery)
        } catch { return .rejected(error) }
        var coordinationError: NSError?
        var result: CloudRekeyPublication?
        var effectStarted = false
        NSFileCoordinator().coordinate(writingItemAt: cache, options: [], writingItemAt: databaseListURL, options: [], error: &coordinationError) { target, registry in
            guard stateLock.try() else { result = .rejected(SaveError.saveContextUnavailable); return }
            defer { stateLock.unlock() }
            do {
                result = try PendingUploadQueue.withCommitLock(for: snapshot.marker.databaseId, environment: queue, nonBlocking: true) {
                    guard let exact = try PendingUploadQueue.readJournal(for: snapshot.marker.databaseId, environment: queue).first(where: { $0.id == snapshot.id }),
                          exact.marker == snapshot.marker, binding.databaseID == snapshot.marker.databaseId,
                          binding.operationID == snapshot.id, binding.baseline == snapshot.marker.localCommitBaseline,
                          try PendingUploadQueue.readImmutablePayload(exact, environment: queue) == bytes,
                          var rows = try readRegistry(at: registry),
                          let index = rows.firstIndex(where: { $0.id == snapshot.marker.databaseId }) else {
                        return .rejected(SaveError.saveContextUnavailable)
                    }
                    let current = rows[index]
                    guard cache.standardizedFileURL == cacheLocation(for: current).standardizedFileURL,
                          !rows.contains(where: { $0.id != current.id && cacheLocation(for: $0).standardizedFileURL == cache.standardizedFileURL }) else {
                        return .rejected(SaveError.saveContextUnavailable)
                    }
                    let initial = binding.matchesOriginal(reference: current, operationID: snapshot.id)
                    let installed = binding.matchesInstalled(reference: current, operationID: snapshot.id,
                                                              keyChange: rekey, committedAt: committedAt)
                    guard (initial || installed), lease.reference.matches(current) else { return .rejected(SaveError.saveContextUnavailable) }
                    if installed { effectStarted = true }
                    return try PendingLocalSaveStore.withCloudRekeyPublicationAuthorization(for: current.id, sha512: intendedSHA,
                        lease: lease, rekeyRecovery: rekeyRecovery, binding: binding, operationID: snapshot.id,
                        change: rekey, committedAt: committedAt) { handoff in
                        let oldBytes: Data?
                        do { oldBytes = try Data(contentsOf: target) }
                        catch let error as CocoaError where error.code == .fileReadNoSuchFile { oldBytes = nil }
                        let oldSHA = oldBytes.map(FileDigest.sha512)
                        if installed, oldSHA != intendedSHA { return .rejected(SaveError.saveContextUnavailable) }
                        guard oldSHA == nil || oldSHA == snapshot.marker.predecessorSHA512 || oldSHA == intendedSHA else {
                            return .rejected(SaveError.saveContextUnavailable)
                        }
                        if let oldBytes, oldSHA != intendedSHA { try backup(current, oldBytes) }
                        if !installed && oldSHA != intendedSHA {
                            switch LocalDatabaseSaver.replaceAlreadyCoordinated(bytes, at: target, expectedSHA512: oldSHA, io: replacementIO,
                                beforeReplacement: { effectStarted = true; deleteOldKeys(current) }) {
                            case .durable: break
                            case .notPublished(let error): return .rejected(error)
                            case .publishedWithoutConfirmedDurability(let error): return .cacheUnconfirmed(error)
                            }
                        } else if !installed {
                            effectStarted = true
                            deleteOldKeys(current)
                        }
                        if oldSHA == intendedSHA {
                            let handle = try FileHandle(forUpdating: target)
                            defer { try? handle.close() }
                            try registryIO.synchronizeFile(handle.fileDescriptor)
                            try registryIO.synchronizeParent(target.deletingLastPathComponent())
                        }
                        guard try PendingUploadQueue.readJournal(for: current.id, environment: queue).contains(where: {
                            $0.id == snapshot.id && $0.marker == snapshot.marker
                        }), try Data(contentsOf: target) == bytes else {
                            return .cacheUnconfirmed(SaveError.saveContextUnavailable)
                        }
                        let remaining = try PendingUploadQueue.readJournal(for: current.id, environment: queue).filter { $0.id != snapshot.id }
                        var ancestors = Set(snapshot.marker.absorbedOperationIDs ?? [])
                        if let predecessor = snapshot.marker.predecessorOperationID { ancestors.insert(predecessor) }
                        ancestors.remove(snapshot.id)
                        guard ancestors.isDisjoint(with: Set(remaining.map(\.id))) else {
                            return .retirementUnconfirmed(current)
                        }
                        rows[index].updateCloudSyncMetadata {
                            $0.localHeadOperationID = snapshot.id
                            $0.keyEpoch = rekey.epoch
                            if let rev = snapshot.marker.confirmedRemoteRev { $0.remoteRev = rev }
                            if let hash = snapshot.marker.confirmedRemoteHash { $0.remoteContentHash = hash }
                            $0.remoteModifiedAt = committedAt
                            $0.lastSyncedAt = remaining.isEmpty ? committedAt : nil
                            $0.lastSyncIssue = nil
                        }
                        rows[index].keyFileBookmarkData = rekey.keyFileBookmarkData
                        rows[index].keyFileFilename = rekey.keyFileFilename
                        rows[index].lastMasterKeyChangeAt = committedAt
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let registryBytes = try encoder.encode(normalized(rows))
                        switch writeWithDurabilityOutcome(registryBytes, to: registry, directoryAnchor: anchor, io: registryIO) {
                        case .durable:
                            let published = rows[index]
                            guard let durableRow = try readRegistry(at: registry)?.first(where: { $0.id == current.id }),
                                  durableRow == published,
                                  binding.matchesInstalled(reference: durableRow, operationID: snapshot.id, keyChange: rekey, committedAt: committedAt),
                                  try Data(contentsOf: target) == bytes,
                                  try PendingUploadQueue.readJournal(for: current.id, environment: queue).contains(where: {
                                      $0.id == snapshot.id && $0.marker == snapshot.marker
                                  }) else { return .retirementUnconfirmed(published) }
                            do {
                                try handoff(durableRow)
                                guard try PendingUploadQueue.dropIfUnchanged(snapshot, environment: queue) else {
                                    return .retirementUnconfirmed(published)
                                }
                            } catch { return .retirementUnconfirmed(published) }
                            return .durable(published)
                        case .notPublished(let error): return .registryNotPublished(error)
                        case .publishedWithoutConfirmedDurability(let error): return .registryUnconfirmed(error)
                        }
                    }
                }
            } catch {
                result = effectStarted ? .cacheUnconfirmed(error) : .rejected(error)
            }
        }
        if let coordinationError {
            switch result {
            case .durable, .registryUnconfirmed: return .registryUnconfirmed(coordinationError)
            case .registryNotPublished: return .registryNotPublished(coordinationError)
            case .cacheUnconfirmed: return .cacheUnconfirmed(coordinationError)
            case .retirementUnconfirmed(let reference): return .retirementUnconfirmed(reference)
            default: return effectStarted ? .cacheUnconfirmed(coordinationError) : .rejected(coordinationError)
            }
        }
        return result ?? .rejected(CocoaError(.fileWriteUnknown))
    }

    @discardableResult
    static func setReadOnly(_ isReadOnly: Bool, for reference: DatabaseReference) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == reference.id }) else { return .missing }
            guard PendingLocalSaveStore.PreferenceObservation(reference).matches(rows[index]),
                  rows[index].hardwareKey == reference.hardwareKey else { return .rejected }
            guard rows[index].isReadOnly != isReadOnly else { return .noop(()) }
            rows[index].isReadOnly = isReadOnly
            return .write(())
        })
    }

    @discardableResult
    static func setCloudSyncPolicy(_ policy: CloudSyncPolicy, for reference: DatabaseReference) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == reference.id }) else { return .missing }
            guard rows[index].cloudSyncPolicy != policy else { return .noop(()) }
            rows[index].cloudSyncPolicy = policy
            return .write(())
        })
    }

    @discardableResult
    static func setAutoFillDestinationGroupID(_ groupID: UUID, for reference: DatabaseReference) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == reference.id }) else { return .missing }
            guard rows[index].autoFillDestinationGroupID != groupID else { return .noop(()) }
            rows[index].autoFillDestinationGroupID = groupID
            return .write(())
        })
    }

    /// Adding or removing the hardware key changes what the stored Quick
    /// Launch key means (composite key vs. pre-key), so that key is dropped
    /// and the next successful unlock stores the right one.
    enum HardwarePreferenceOutcome: Equatable, Sendable {
        case saved, unchanged, rejected, notPublished, visibleUnconfirmed, keyEffectUnconfirmed
    }

    @discardableResult
    static func setHardwareKey(_ hardwareKey: HardwareKeyConfiguration?, for reference: DatabaseReference,
                               io: DurableFileWriteIO = .init(),
                               deleteKeys: (UUID, String?) -> Void = { id, legacy in
                                   KeychainService.deleteCompositeKey(for: id)
                                   if let legacy { KeychainService.deleteLegacyCompositeKey(forFilename: legacy) }
                               }) -> HardwarePreferenceOutcome {
        guard let token = try? PendingLocalSaveStore.capturePreference(.init(reference)) else { return .rejected }
        var keyEffect = false
        let result = mutateRegistry(io: io, authorize: { operation in
            try PendingLocalSaveStore.withIdlePreferenceAuthorization(token, nonBlocking: true, operation)
        }) { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == reference.id }) else { return .missing }
            guard token.observation.matches(rows[index]), rows[index].hardwareKey == reference.hardwareKey,
                  rows[index].legacyKeychainFilename == reference.legacyKeychainFilename else { return .rejected }
            guard rows[index].hardwareKey != hardwareKey else { return .noop(()) }
            if (rows[index].hardwareKey == nil) != (hardwareKey == nil) {
                let legacy = rows[index].legacyKeychainFilename
                let sharedLegacy = legacy.map { name in rows.contains { $0.id != reference.id && $0.legacyKeychainFilename == name } } ?? false
                deleteKeys(reference.id, sharedLegacy ? nil : legacy)
                keyEffect = true
                rows[index].legacyKeychainFilename = nil
            }
            rows[index].hardwareKey = hardwareKey
            return .write(())
        }
        switch result {
        case .durable: return .saved
        case .noop: return .unchanged
        case .missing, .rejected: return .rejected
        case .notPublished: return keyEffect ? .keyEffectUnconfirmed : .notPublished
        case .visibleUnconfirmed: return .visibleUnconfirmed
        }
    }

    /// Owns the consequences of toggling a database's AutoFill participation
    /// (mirroring how `remove(observed:)` owns removal consequences): disabling
    /// removes exactly that database's published identities — targeted, needs
    /// no unlock, other databases' suggestions stay untouched — and, when the
    /// disabled database was the active AutoFill database, hands the active
    /// pointer to the most recently opened AutoFill-enabled database (or
    /// clears it when none exists).
    ///
    /// `includingLegacyIdentifiers` mirrors `wasActive` because legacy
    /// bare-UUID identities carry no database attribution: they can only have
    /// been published by the pre-tagging whole-store-replace era, in which
    /// exactly one database — the then-active one — ever populated the store.
    /// So the store's legacy identities belong to the disabled database
    /// precisely when it was the active one.
    ///
    /// Enabling is lazy here: identities appear on the database's next unlock
    /// (entries live inside the encrypted KDBX; nothing can be published from
    /// the registry alone). The immediate-refresh-when-already-unlocked path
    /// lives at the view-model layer (`DatabaseListViewModel.setAutoFillEnabled`),
    /// which can see the open session; this store cannot.
    enum AutoFillPreferenceOutcome: Sendable, Equatable { case saved, unchanged, rejected, notPublished, visibleUnconfirmed }
    private struct AutoFillChange {
        let reference: DatabaseReference
        let wasActive: Bool
        let previousPointer: UUID?
        let nextPointer: UUID?
    }

    @discardableResult
    static func setAutoFillEnabled(_ isEnabled: Bool, for reference: DatabaseReference,
                                   io: DurableFileWriteIO = .init()) -> AutoFillPreferenceOutcome {
        let result = mutateRegistry(io: io) { rows -> RegistryDecision<AutoFillChange> in
            guard let index = rows.firstIndex(where: { $0.id == reference.id }) else { return .missing }
            guard PendingLocalSaveStore.PreferenceObservation(reference).matches(rows[index]),
                  rows[index].hardwareKey == reference.hardwareKey,
                  rows[index].autoFillEnabled == reference.autoFillEnabled else { return .rejected }
            let wasActive = activeAutoFillDatabase(in: rows)?.id == reference.id
            let pointer = activeAutoFillDatabaseID
            let captured = rows[index]
            let next = rows.filter { $0.id != reference.id && $0.autoFillEnabled && $0.lastOpenedAt != nil }
                .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }?.id
            let change = AutoFillChange(reference: captured, wasActive: wasActive, previousPointer: pointer, nextPointer: next)
            guard captured.autoFillEnabled != isEnabled else { return .noop(change) }
            rows[index].autoFillEnabled = isEnabled
            return .write(change)
        }
        switch result {
        case .durable(let change):
            if !isEnabled {
                if change.wasActive && activeAutoFillDatabaseID == change.previousPointer {
                    if let next = change.nextPointer {
                        if (try? readDatabasesStrict().contains { $0.id == next && $0.autoFillEnabled }) == true {
                            activeAutoFillDatabaseID = next
                        }
                    } else { activeAutoFillDatabaseID = nil }
                }
                CredentialIdentityStoreManager.removeIdentities(forDatabase: change.reference.id, includingLegacyIdentifiers: change.wasActive)
            }
            return .saved
        case .noop: return .unchanged
        case .missing, .rejected: return .rejected
        case .notPublished: return .notPublished
        case .visibleUnconfirmed: return .visibleUnconfirmed
        }
    }

    /// `destination` indexes the list as it was *before* the move, so it has to
    /// be pulled back by however many moved rows sat above it.
    @discardableResult
    static func move(from source: IndexSet, to destination: Int, observedIDs: [UUID]? = nil) -> Bool {
        let observed = observedIDs ?? loadDatabases().map(\.id)
        guard source.allSatisfy({ observed.indices.contains($0) }), (0...observed.count).contains(destination) else { return false }
        return succeeded(mutateRegistry { currentDatabases -> RegistryDecision<Void> in
            guard currentDatabases.map(\.id) == observed else { return .rejected }
            let movingItems = source.map { currentDatabases[$0] }
            let liftedAbove = source.count { $0 < destination }

            for index in source.sorted(by: >) {
                currentDatabases.remove(at: index)
            }

            let insertionIndex = min(max(destination - liftedAbove, 0), currentDatabases.count)
            currentDatabases.insert(contentsOf: movingItems, at: insertionIndex)
            return .write(())
        })
    }

    static func markDatabaseOpened(id: UUID, observed: DatabaseReference? = nil, at date: Date = .now) {
        let result = mutateRegistry { rows -> RegistryDecision<Bool> in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return .missing }
            rows[index].lastOpenedAt = date
            if let observed, observed.id == id, observed.bookmarkData == rows[index].bookmarkData,
               PendingLocalSaveStore.PreferenceObservation(observed).matches(rows[index]) {
                rows[index].hasUnverifiedRelink = false
            }
            return .write(rows[index].autoFillEnabled)
        }
        if case .durable(true) = result { activeAutoFillDatabaseID = id }
    }

    @discardableResult
    static func clearLegacyKeychainFilename(for expected: DatabaseReference, io: DurableFileWriteIO = .init()) -> Bool {
        guard let legacy = expected.legacyKeychainFilename else { return false }
        let result = mutateRegistry(io: io, authorize: { operation in
            try PendingLocalSaveStore.withLegacyFilenameCleanupAuthorization(for: expected.id, operation)
        }) { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == expected.id }) else { return .missing }
            guard rows[index].legacyKeychainFilename == legacy,
                  rows[index].hardwareKey == expected.hardwareKey,
                  PendingLocalSaveStore.PreferenceObservation(expected).matches(rows[index]) else { return .rejected }
            rows[index].legacyKeychainFilename = nil
            return .write(())
        }
        if case .durable = result { return true }
        return false
    }

    final class KeyCommitPublicationPermit: @unchecked Sendable {
        enum State: Sendable, Equatable { case pending, claimed, closed }
        let actionID: UUID
        let lockCycleID: Int
        private let lock = NSLock()
        enum WorkerCompletion: Sendable, Equatable {
            case pending, claimedPending, finishedWithoutClaim, finishedAfterClaim
        }
        private var value = State.pending
        private var workerFinished = false
        init(actionID: UUID, lockCycleID: Int) { self.actionID = actionID; self.lockCycleID = lockCycleID }
        var state: State { lock.lock(); defer { lock.unlock() }; return value }
        func close() { lock.lock(); defer { lock.unlock() }; if value == .pending { value = .closed } }
        var workerCompletion: WorkerCompletion {
            lock.lock(); defer { lock.unlock() }
            if workerFinished { return value == .claimed ? .finishedAfterClaim : .finishedWithoutClaim }
            return value == .claimed ? .claimedPending : .pending
        }
        func finishWorker() {
            lock.lock(); defer { lock.unlock() }
            workerFinished = true
            if value == .pending { value = .closed }
        }
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard value == .pending else { return false }
            value = .claimed
            return true
        }
    }

    struct KeyCommitPublicationIO: Sendable {
        var resolve: @Sendable (Data) -> (url: URL, isStale: Bool)? = SecurityScopedBookmarkManager.resolveURL
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var coordinate: @Sendable (URL, URL, (URL, URL) -> Void) throws -> Void = { target, registry, accessor in
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], writingItemAt: registry,
                options: [], error: &error, byAccessor: accessor)
            if let error { throw error }
        }
        var beforeEffect: @Sendable () throws -> Void = {}
        var didFinish: @Sendable () -> Void = {}
    }

    static func withLocalKeyCommitPublication<T>(
        for expected: DatabaseReference, receipt: PendingLocalSaveStore.CommitReceipt,
        permit: KeyCommitPublicationPermit, io: KeyCommitPublicationIO = .init(), _ publish: () throws -> T
    ) throws -> T {
        defer { permit.close() }
        guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        let observed = try withStateLock {
            let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL))
            guard let current = references.first(where: { $0.id == expected.id }), current.id == receipt.databaseID,
                  !current.isCloudBacked, !expected.isCloudBacked,
                  current.bookmarkData == expected.bookmarkData, current.hardwareKey == expected.hardwareKey,
                  current.legacyKeychainFilename == expected.legacyKeychainFilename else {
                throw PendingLocalSaveStore.OwnershipError.sourceChanged
            }
            return current
        }
        guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        let target: URL
        if let bookmark = observed.bookmarkData {
            guard let resolved = io.resolve(bookmark) else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
            target = resolved.url
        } else { target = cacheLocation(for: observed) }
        let access = observed.bookmarkData != nil && target.startAccessingSecurityScopedResource()
        defer { if access { target.stopAccessingSecurityScopedResource() } }
        guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        var result: Result<T, Error>?
        var coordinatorError: Error?
        do {
            try io.coordinate(target, databaseListURL) { protectedTarget, registry in
                result = Result {
                    guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    let identity = try PendingLocalSaveStore.targetIdentity(at: protectedTarget)
                    let bytes = try io.read(protectedTarget)
                    guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    // Never wait for a list holder that may itself be waiting for this coordination.
                    guard stateLock.try() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    defer { stateLock.unlock() }
                    let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let current = references.first(where: { $0.id == expected.id }),
                          PendingLocalSaveStore.PreferenceObservation(observed).matches(current),
                          current.hardwareKey == observed.hardwareKey,
                          current.legacyKeychainFilename == observed.legacyKeychainFilename else {
                        throw PendingLocalSaveStore.OwnershipError.sourceChanged
                    }
                    return try PendingLocalSaveStore.withKeyCommitPublicationAuthorization(receipt, reference: current, nonBlocking: true,
                        observeTarget: { (identity, bytes) }) {
                            try io.beforeEffect()
                            guard permit.claim() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                            return try publish()
                        }
                }
            }
        } catch { coordinatorError = error }
        // An outer coordinator error cannot undo Keychain effects observed inside the protected accessor.
        if let result { return try result.get() }
        throw coordinatorError ?? CocoaError(.fileReadUnknown)
    }

    /// Called only inside target coordination; never waits for the registry lock.
    static func withCloudMergeReference<T>(_ expected: DatabaseReference, _ body: (DatabaseReference) throws -> T) throws -> T {
        guard stateLock.try() else { throw SaveError.saveContextUnavailable }
        defer { stateLock.unlock() }
        let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL))
        guard let current = references.first(where: { $0.id == expected.id }),
              current.cloudSyncMetadata?.provider == expected.cloudSyncMetadata?.provider,
              current.cloudSyncMetadata?.accountId == expected.cloudSyncMetadata?.accountId,
              current.cloudSyncMetadata?.fileId == expected.cloudSyncMetadata?.fileId,
              current.cloudSyncMetadata?.keyEpoch == expected.cloudSyncMetadata?.keyEpoch,
              current.cloudSyncMetadata?.localHeadOperationID == expected.cloudSyncMetadata?.localHeadOperationID,
              current.lastMasterKeyChangeAt == expected.lastMasterKeyChangeAt,
              current.bookmarkData == expected.bookmarkData, current.hardwareKey == expected.hardwareKey,
              current.keyFileBookmarkData == expected.keyFileBookmarkData,
              current.keyFileFilename == expected.keyFileFilename,
              current.legacyKeychainFilename == expected.legacyKeychainFilename,
              current.isReadOnly == expected.isReadOnly else { throw SaveError.saveContextUnavailable }
        return try body(current)
    }

    /// Cache coordination precedes an immediate list/commit-lock attempt; contention rejects publication.
    static func withCloudKeyPublication<T>(
        for expected: DatabaseReference, sha512: Data, permit: KeyCommitPublicationPermit,
        io: KeyCommitPublicationIO = .init(), _ publish: () throws -> T
    ) throws -> T {
        defer { permit.close() }
        guard permit.state == .pending else { throw SaveError.saveContextUnavailable }
        let cache = cacheLocation(for: expected)
        var result: Result<T, Error>?
        var coordinationError: Error?
        do {
            try io.coordinate(cache, databaseListURL) { protectedCache, registry in
                result = Result {
                    guard permit.state == .pending else { throw SaveError.saveContextUnavailable }
                    let bytes = try io.read(protectedCache)
                    guard FileDigest.sha512(bytes) == sha512, stateLock.try() else { throw SaveError.saveContextUnavailable }
                    defer { stateLock.unlock() }
                    let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let current = references.first(where: { $0.id == expected.id }),
                          current.cloudSyncMetadata?.keyEpoch == expected.cloudSyncMetadata?.keyEpoch,
                          current.cloudSyncMetadata?.localHeadOperationID == expected.cloudSyncMetadata?.localHeadOperationID,
                          current.lastMasterKeyChangeAt == expected.lastMasterKeyChangeAt,
                          current.keyFileBookmarkData == expected.keyFileBookmarkData,
                          current.keyFileFilename == expected.keyFileFilename,
                          current.legacyKeychainFilename == expected.legacyKeychainFilename,
                          current.hardwareKey == expected.hardwareKey,
                          current.cloudSyncMetadata?.fileId == expected.cloudSyncMetadata?.fileId,
                          current.cloudSyncMetadata?.accountId == expected.cloudSyncMetadata?.accountId,
                          current.cloudSyncMetadata?.provider == expected.cloudSyncMetadata?.provider else { throw SaveError.saveContextUnavailable }
                    return try PendingUploadQueue.withCommitLock(for: current.id, nonBlocking: true) {
                        guard try PendingUploadQueue.readJournal(for: current.id).isEmpty else { throw SaveError.saveContextUnavailable }
                        return try PendingLocalSaveStore.withCachePublicationAuthorization(for: current.id, sha512: sha512, nonBlocking: true) {
                            try io.beforeEffect()
                            guard permit.claim() else { throw SaveError.saveContextUnavailable }
                            return try publish()
                        }
                    }
                }
            }
        } catch { coordinationError = error }
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown)
    }

    static func withLocalReadKeyPublication<T>(
        for expected: DatabaseReference, read: PendingLocalSaveStore.ReadKeyPublication,
        permit: KeyCommitPublicationPermit, io: KeyCommitPublicationIO = .init(), _ publish: () throws -> T
    ) throws -> T {
        defer { permit.close() }
        guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        guard let authenticated = read.encryptedSnapshot,
              FileDigest.sha512(authenticated) == read.sha512 else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
        let observed = try withStateLock {
            let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL))
            guard let current = references.first(where: { $0.id == expected.id }) else { throw PendingLocalSaveStore.OwnershipError.removed }
            guard !current.isCloudBacked,
                  current.hardwareKey == expected.hardwareKey, current.legacyKeychainFilename == expected.legacyKeychainFilename else {
                throw PendingLocalSaveStore.OwnershipError.sourceChanged
            }
            if let renewal = read.lease.bookmarkRenewal {
                guard renewal.matches(expected, current: current, lease: read.lease), !read.sharedCopy,
                      read.target == renewal.target else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
            } else if !read.lease.reference.matches(current) { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
            return current
        }
        guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        let target: URL
        if !read.sharedCopy, let bookmark = observed.bookmarkData {
            guard let resolved = io.resolve(bookmark) else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
            target = resolved.url
        } else { target = cacheLocation(for: observed) }
        let access = !read.sharedCopy && target.startAccessingSecurityScopedResource()
        defer { if access { target.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?
        var coordinatorError: Error?
        do {
            try io.coordinate(target, databaseListURL) { protectedTarget, registry in
                result = Result {
                    guard permit.state == .pending else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    let identity = try PendingLocalSaveStore.targetIdentity(at: protectedTarget)
                    let bytes = try io.read(protectedTarget)
                    guard identity == read.target, bytes == authenticated else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                    guard stateLock.try() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                    defer { stateLock.unlock() }
                    let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let current = references.first(where: { $0.id == expected.id }) else { throw PendingLocalSaveStore.OwnershipError.removed }
                    guard current == observed else {
                        throw PendingLocalSaveStore.OwnershipError.sourceChanged
                    }
                    return try PendingLocalSaveStore.withReadKeyPublicationAuthorization(read) {
                        try io.beforeEffect()
                        guard permit.claim() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                        return try publish()
                    }
                }
            }
        } catch { coordinatorError = error }
        if let result { return try result.get() }
        throw coordinatorError ?? CocoaError(.fileReadUnknown)
    }

    static func authenticatedBookmarkRenewalForMerge(
        for expected: DatabaseReference, read: PendingLocalSaveStore.ReadKeyPublication,
        io: KeyCommitPublicationIO = .init()
    ) throws -> DatabaseBookmarkRenewal {
        guard let renewal = read.lease.bookmarkRenewal, let authenticated = read.encryptedSnapshot,
              !read.sharedCopy, FileDigest.sha512(authenticated) == read.sha512,
              renewal.target == read.target else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
        let observed = try withStateLock {
            let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL))
            guard let current = references.first(where: { $0.id == expected.id }) else { throw PendingLocalSaveStore.OwnershipError.removed }
            guard renewal.matches(expected, current: current, lease: read.lease), !current.isCloudBacked else {
                throw PendingLocalSaveStore.OwnershipError.sourceChanged
            }
            return current
        }
        guard let bookmark = observed.bookmarkData, let resolved = io.resolve(bookmark) else {
            throw PendingLocalSaveStore.OwnershipError.targetChanged
        }
        let access = resolved.url.startAccessingSecurityScopedResource()
        defer { if access { resolved.url.stopAccessingSecurityScopedResource() } }
        var result: Result<DatabaseBookmarkRenewal, Error>?
        try io.coordinate(resolved.url, databaseListURL) { target, registry in
            result = Result {
                let identity = try PendingLocalSaveStore.targetIdentity(at: target)
                let bytes = try io.read(target)
                guard identity == read.target, bytes == authenticated else { throw PendingLocalSaveStore.OwnershipError.targetChanged }
                guard stateLock.try() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                defer { stateLock.unlock() }
                let references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                guard references.first(where: { $0.id == expected.id }) == observed else {
                    throw PendingLocalSaveStore.OwnershipError.sourceChanged
                }
                try PendingLocalSaveStore.validateBookmarkRenewalForMerge(read)
                return renewal
            }
        }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func withLocalCacheReference<T>(
        _ expected: DatabaseReference, allowNewReference: Bool,
        lease: PendingLocalSaveStore.CacheReadLease? = nil, _ publish: () throws -> T
    ) throws -> T {
        try withStateLock {
            let references: [DatabaseReference]
            do { references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: databaseListURL)) }
            catch let error as CocoaError where allowNewReference && error.code == .fileReadNoSuchFile { references = [] }
            if let current = references.first(where: { $0.id == expected.id }) {
                let unchanged = PendingLocalSaveStore.PreferenceObservation(expected).matches(current) && current.filename == expected.filename
                let renewed = lease.flatMap { value in value.bookmarkRenewal.map { $0.matches(expected, current: current, lease: value) } } == true
                guard unchanged || renewed else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
            } else if !allowNewReference { throw PendingLocalSaveStore.OwnershipError.removed }
            return try publish()
        }
    }

    static func cacheDatabaseCopy(_ data: Data, for databaseID: UUID) throws {
        guard let reference = databases.first(where: { $0.id == databaseID }) else { throw PendingLocalSaveStore.OwnershipError.removed }
        if reference.isCloudBacked { try cacheDatabaseCopy(data, for: reference); return }
        let lease = try PendingLocalSaveStore.captureCacheReadLease(for: reference)
        // UUID-only callers cannot upgrade an old read to an observed key epoch.
        guard lease.epochID == nil else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        try LocalDatabaseSaver.cacheLocalSnapshot(data, for: reference, lease: lease)
    }

    static func cacheDatabaseCopy(_ data: Data, for reference: DatabaseReference) throws {
        if !reference.isCloudBacked {
            try LocalDatabaseSaver.cacheLocalSnapshot(data, for: reference, allowNewReference: true)
            return
        }
        let url = cacheLocation(for: reference)
        guard let anchor = AppGroupContainer.resolvedURL else { throw CocoaError(.fileWriteNoPermission) }
        try createDurableDirectory(at: url.deletingLastPathComponent(), anchor: anchor)
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { protectedURL in
            result = Result {
                guard stateLock.try() else { throw SaveError.saveContextUnavailable }
                defer { stateLock.unlock() }
                if let current = loadDatabases().first(where: { $0.id == reference.id }) {
                    guard current.cloudSyncMetadata?.keyEpoch == reference.cloudSyncMetadata?.keyEpoch,
                          current.lastMasterKeyChangeAt == reference.lastMasterKeyChangeAt else { throw SaveError.saveContextUnavailable }
                }
                try PendingUploadQueue.withCommitLock(for: reference.id, nonBlocking: true) {
                    guard try PendingUploadQueue.readJournal(for: reference.id).isEmpty else { throw SaveError.saveContextUnavailable }
                    try PendingLocalSaveStore.withCachePublicationAuthorization(for: reference.id, sha512: FileDigest.sha512(data), nonBlocking: true) {
                        guard let anchor = AppGroupContainer.resolvedURL else { throw CocoaError(.fileWriteNoPermission) }
                        try writeAtomicallyAndDurably(data, to: protectedURL, directoryAnchor: anchor)
                    }
                }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileWriteUnknown)
    }

    static func cachedDatabaseURL(for databaseID: UUID) -> URL? {
        let url = cacheURL(for: databaseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func cachedDatabaseURL(for reference: DatabaseReference) -> URL? {
        let url = cacheLocation(for: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func cacheLocation(for reference: DatabaseReference) -> URL {
        if let metadata = reference.cloudSyncMetadata {
            return cloudCacheURL(for: metadata)
        }
        return cacheURL(for: reference.id)
    }

    enum LocalDatabaseFileLocation: Equatable, Sendable {
        case available(URL)
        case inTrash(URL)
    }

    enum LocalDatabaseFileError: Error, LocalizedError, Equatable, Sendable {
        case databaseInTrash

        var errorDescription: String? {
            #if os(macOS)
            String(localized: "The database file is in the Trash. Restore it from the Trash in Finder, or choose the current file with Locate Database File in KeeForge.")
            #else
            String(localized: "The database file is in Recently Deleted in the Files app. Restore it in Files, or choose the current file with Locate Database File in KeeForge.")
            #endif
        }
    }

    /// Resolves a local database's bookmark and classifies the result. iOS
    /// bookmarks follow file identity, so after a Files-app Delete or Replace
    /// the bookmark still resolves — to the old copy sitting in Recently
    /// Deleted. That copy must never be read, written, cached, or re-minted
    /// into a fresh bookmark: restoring the file in Files keeps the original
    /// bookmark valid, and once the trashed copy is purged, resolution falls
    /// back to the stored path and rebinds to whatever file now lives there.
    ///
    /// Documents-resident references are the exception: their identity is the
    /// path `Documents/<filename>` (Finder replace over USB is delete+recopy,
    /// stranding the old bookmark), so a failed or trashed resolution rebinds
    /// to the file currently at that path when one exists.
    struct DatabaseBookmarkRenewal: Sendable, Equatable {
        let before: DatabaseReference
        let after: DatabaseReference
        let epochID: UUID?
        let target: PendingLocalSaveStore.TargetIdentity
        fileprivate init(before: DatabaseReference, after: DatabaseReference, epochID: UUID?, target: PendingLocalSaveStore.TargetIdentity) {
            self.before = before
            self.after = after
            self.epochID = epochID
            self.target = target
        }
        func matches(_ expected: DatabaseReference, current: DatabaseReference, lease: PendingLocalSaveStore.CacheReadLease) -> Bool {
            before == expected && after == current && lease.databaseID == before.id
                && lease.epochID == epochID && lease.masterKeyChangedAt == before.lastMasterKeyChangeAt
                && lease.reference.matches(before)
        }
    }

    static func locateDatabaseFile(
        for reference: DatabaseReference,
        resolveBookmark: (Data) -> (url: URL, isStale: Bool)? = SecurityScopedBookmarkManager.resolveURL,
        renewBookmark: Bool = true,
        beforeBookmarkRenewal: () throws -> Void = {},
        bookmarkRenewalIO: DurableFileWriteIO = .init(),
        onBookmarkRenewal: (DatabaseBookmarkRenewal) -> Void = { _ in },
        onDocumentsRebind: (DatabaseReference) -> Void = { _ in }
    ) -> LocalDatabaseFileLocation? {
        let lease = renewBookmark ? (try? PendingLocalSaveStore.captureCacheReadLease(for: reference)) : nil
        guard let bookmarkData = reference.bookmarkData,
              let resolved = resolveBookmark(bookmarkData) else {
            return renewBookmark ? reboundDocumentsResidentLocation(for: reference, onRebind: onDocumentsRebind) : nil
        }

        let url = resolved.url
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if SecurityScopedBookmarkManager.isInTrashDirectory(url) {
            if renewBookmark, let rebound = reboundDocumentsResidentLocation(for: reference, onRebind: onDocumentsRebind) {
                return rebound
            }
            return .inTrash(url)
        }

        if renewBookmark, resolved.isStale,
           let refreshedBookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: url) {
            do {
                try beforeBookmarkRenewal()
                if let lease, let renewal = renewDatabaseBookmark(refreshedBookmarkData, expected: reference,
                    lease: lease, targetURL: url, io: bookmarkRenewalIO) { onBookmarkRenewal(renewal) }
            } catch {}
        }

        return .available(url)
    }

    static func publishInstalledMergeBookmark(
        for expected: DatabaseReference, commit: PendingLocalSaveStore.CommitReceipt, grantedTarget: URL,
        io: DurableFileWriteIO = .init()
    ) throws -> DatabaseBookmarkRenewal {
        guard expected.bookmarkData != nil, !expected.isCloudBacked, commit.databaseID == expected.id,
              let anchor = AppGroupContainer.resolvedURL else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
        var coordinationError: NSError?
        var result: Result<DatabaseBookmarkRenewal, Error>?
        NSFileCoordinator().coordinate(readingItemAt: grantedTarget, options: [], writingItemAt: databaseListURL,
            options: .forReplacing, error: &coordinationError) { target, registry in
            result = Result {
                let identity = try PendingLocalSaveStore.targetIdentity(at: target)
                let sha = FileDigest.sha512(try Data(contentsOf: target))
                let bookmark = try SecurityScopedBookmarkManager.makeBookmarkData(for: target)
                guard stateLock.try() else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
                defer { stateLock.unlock() }
                var references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                guard let index = references.firstIndex(where: { $0.id == expected.id }),
                      PendingLocalSaveStore.PreferenceObservation(expected).matches(references[index]),
                      expected.hardwareKey == references[index].hardwareKey else { throw PendingLocalSaveStore.OwnershipError.sourceChanged }
                return try PendingLocalSaveStore.withMergeBookmarkPublication(commit, target: identity, sha512: sha, nonBlocking: true) { epoch in
                    let before = references[index]
                    references[index].bookmarkData = bookmark
                    switch writeWithDurabilityOutcome(try JSONEncoder().encode(references), to: registry, directoryAnchor: anchor, io: io) {
                    case .durable:
                        return DatabaseBookmarkRenewal(before: before, after: references[index], epochID: epoch, target: identity)
                    case .notPublished(let error), .publishedWithoutConfirmedDurability(let error): throw error
                    }
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private static func renewDatabaseBookmark(
        _ bookmark: Data, expected: DatabaseReference, lease: PendingLocalSaveStore.CacheReadLease,
        targetURL: URL, io: DurableFileWriteIO
    ) -> DatabaseBookmarkRenewal? {
        guard let anchor = AppGroupContainer.resolvedURL else { return nil }
        do {
            var error: NSError?
            var renewal: DatabaseBookmarkRenewal?
            NSFileCoordinator().coordinate(readingItemAt: targetURL, options: [], writingItemAt: databaseListURL,
                options: .forReplacing, error: &error) { target, registry in
                guard stateLock.try() else { return }
                defer { stateLock.unlock() }
                do {
                    var references = try JSONDecoder().decode([DatabaseReference].self, from: Data(contentsOf: registry))
                    guard let index = references.firstIndex(where: { $0.id == expected.id }),
                          !references[index].isCloudBacked, references[index] == expected else { return }
                    let identity = try PendingLocalSaveStore.targetIdentity(at: target)
                    try PendingLocalSaveStore.withReferenceEpochAuthorization(lease, nonBlocking: true) {
                        references[index].bookmarkData = bookmark
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        if case .durable = writeWithDurabilityOutcome(try encoder.encode(references), to: registry,
                            directoryAnchor: anchor, io: io) {
                            renewal = DatabaseBookmarkRenewal(before: expected, after: references[index], epochID: lease.epochID, target: identity)
                        }
                    }
                } catch {}
            }
            return error == nil ? renewal : nil
        }
    }

    static func resolveDatabaseURL(for reference: DatabaseReference, renewBookmark: Bool = true,
        onBookmarkRenewal: (DatabaseBookmarkRenewal) -> Void = { _ in }
    ) -> URL? {
        guard case .available(let url) = locateDatabaseFile(for: reference, renewBookmark: renewBookmark, onBookmarkRenewal: onBookmarkRenewal) else {
            return nil
        }
        return url
    }

    /// Points a bookmarked local reference at the file the user picked after
    /// its bookmark stopped reaching the current copy — a File Provider that
    /// replaced the item during sync, or a Files-app Replace. Only the file
    /// identity changes, so the id, nickname, key file, Keychain key, AutoFill
    /// settings, and backups survive, unlike remove-and-add. The shared cache
    /// is reseeded from the picked file, which is the source of truth for a
    /// bookmarked reference. Nil when the id is no longer listed, is
    /// cloud-backed, or has no bookmark (a KeeForge-only database lives in
    /// that cache, so reseeding it would overwrite the database itself).
    @discardableResult
    static func relinkLocalDatabase(observed: DatabaseReference, to url: URL, io: DurableFileWriteIO = .init()) throws -> DatabaseReference? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if SecurityScopedBookmarkManager.isInTrashDirectory(url) {
            throw LocalDatabaseFileError.databaseInTrash
        }
        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        let target = try PendingLocalSaveStore.targetIdentity(at: url)
        guard let snapshot = try readRegistry(at: databaseListURL) else { return nil }
        let duplicate = existingLocalReference(matching: url, in: snapshot.filter { $0.id != observed.id })
        let result = mutateRegistry(io: io, readingTarget: url, validateTarget: { try PendingLocalSaveStore.targetIdentity(at: $0) == target }, authorize: { operation in
            try PendingLocalSaveStore.withRelinkAuthorization(for: observed.id, operation)
        }) { rows -> RegistryDecision<DatabaseReference> in
            guard let index = rows.firstIndex(where: { $0.id == observed.id }) else { return .missing }
            guard rows.count == snapshot.count, zip(rows, snapshot).allSatisfy({ current, previous in
                current.id == previous.id && current.bookmarkData == previous.bookmarkData && current.isCloudBacked == previous.isCloudBacked
            }), PendingLocalSaveStore.PreferenceObservation(observed).matches(rows[index]),
                rows[index].hardwareKey == observed.hardwareKey,
                rows[index].legacyKeychainFilename == observed.legacyKeychainFilename,
                rows[index].cloudSyncMetadata == nil, rows[index].bookmarkData != nil else { return .rejected }
            if let duplicate {
                throw AddDatabaseError.duplicateFile(
                    existingReferenceID: duplicate.id,
                    filename: duplicate.displayName
                )
            }
            rows[index].bookmarkData = bookmarkData
            rows[index].filename = filename(for: url)
            rows[index].isDocumentsResident = isTopLevelDocumentsFile(url)
            rows[index].hasUnverifiedRelink = true
            return .write(rows[index])
        }
        switch result {
        case .durable(let relinked):
            cacheInitialCopyIfPossible(from: url, for: relinked.id)
            return relinked
        case .noop(let reference): return reference
        case .notPublished(let error): throw error
        case .visibleUnconfirmed(_, let error): throw RegistryWriteError.visibleUnconfirmed(error)
        case .missing, .rejected: return nil
        }
    }

    static func resolveKeyFileURL(
        for reference: DatabaseReference,
        onRenewal: (Task<KeyFilePreferenceOutcome, Never>) -> Void = { _ in }
    ) -> URL? {
        guard let bookmark = reference.keyFileBookmarkData,
              let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmark) else { return nil }
        if resolved.isStale {
            let renewal = Task.detached(priority: .utility) { renewKeyFileBookmark(for: reference) }
            onRenewal(renewal)
        }
        return resolved.url
    }

    static func renewKeyFileBookmark(
        for reference: DatabaseReference,
        resolve: @Sendable (Data) -> (url: URL, isStale: Bool)? = { SecurityScopedBookmarkManager.resolveURL(from: $0) },
        makeBookmark: @Sendable (URL) throws -> Data = { try SecurityScopedBookmarkManager.makeBookmarkData(for: $0, readOnly: true) }
    ) -> KeyFilePreferenceOutcome {
        do {
            let token = reference.isCloudBacked ? nil : try prepareKeyFilePreference(for: reference)
            guard let bookmark = reference.keyFileBookmarkData, let resolved = resolve(bookmark), resolved.isStale else { return .notPublished }
            let access = resolved.url.startAccessingSecurityScopedResource()
            defer { if access { resolved.url.stopAccessingSecurityScopedResource() } }
            let refreshed = try makeBookmark(resolved.url)
            let desired = PendingLocalSaveStore.KeyFilePreference(bookmarkData: refreshed,
                filename: reference.keyFileFilename ?? resolved.url.lastPathComponent)
            if let token { return publishKeyFilePreference(token, desired: desired) }
            return try PendingUploadQueue.withCommitLock(for: reference.id, nonBlocking: true) {
                guard try PendingUploadQueue.readJournal(for: reference.id).isEmpty else { return .notPublished }
                return publishRegistryKeyFilePreference(for: reference, desired: desired)
            }
        } catch { return .rejected }
    }

    static func refreshBookmarks() {
        let currentDatabases = loadDatabases()
        currentDatabases.forEach { reference in
            _ = resolveDatabaseURL(for: reference)
            _ = resolveKeyFileURL(for: reference)
        }
    }

    enum RegistryInitializationResult {
        case initialized, alreadyPresent, notPublished(Error), visibleUnconfirmed(Error)
    }

    @discardableResult
    static func initializeRegistry() -> RegistryInitializationResult {
        #if DEBUG
        uiTestBootstrapLock.lock()
        bootstrapForUITestingIfNeeded()
        uiTestBootstrapLock.unlock()
        #endif
        let migrated = migratedLegacyReference()
        var missing = false
        let result = mutateRegistry(onMissing: {
            missing = true
            return migrated.map { [$0] } ?? []
        }) { rows -> RegistryDecision<Bool> in
            if missing { return .write(true) }
            return .noop(false)
        }
        switch result {
        case .durable:
            sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
            if let migrated {
                if activeAutoFillDatabaseID == nil { activeAutoFillDatabaseID = migrated.id }
                copyLegacyCachedDatabaseIfNeeded(to: migrated.id)
            }
            return .initialized
        case .noop: return .alreadyPresent
        case .visibleUnconfirmed(_, let error): return .visibleUnconfirmed(error)
        case .notPublished(let error): return .notPublished(error)
        case .missing, .rejected: return .notPublished(CocoaError(.fileWriteUnknown))
        }
    }

    static func clearAll() {
        guard AppGroupContainer.isRedirectedForTesting else { return }
        let currentDatabases = loadDatabases()
        currentDatabases.forEach { _ = remove(observed: $0) }
        withStateLock {
            try? FileManager.default.removeItem(at: removedDocumentsFilesURL)
            try? FileManager.default.removeItem(at: databaseListURL)
            try? FileManager.default.removeItem(at: backupsRootURL)
            try? PendingUploadQueue.clearAll()
            PendingLocalSaveStore.clearAll()
            if AppGroupContainer.isRedirectedForTesting {
                // Test teardown also owns caches whose unresolved journal refused ordinary reference removal.
                try? FileManager.default.removeItem(at: SharedVaultStore.cloudCacheDirectory)
            }
            activeAutoFillDatabaseID = nil
            sharedDefaults.removeObject(forKey: migrationVersionKey)
            #if DEBUG
            remainingUITestLocalSaveConflicts = nil
            consumedUITestLocalSaveConflicts = 0
            #endif
        }
    }

    #if DEBUG
    static func consumeUITestLocalSaveConflictSequence() -> Int? {
        guard ProcessInfo.processInfo.arguments.contains(uiTestingLaunchArg) else {
            return nil
        }

        if remainingUITestLocalSaveConflicts == nil {
            let rawValue = ProcessInfo.processInfo.environment[uiTestLocalSaveConflictCountEnv] ?? ""
            remainingUITestLocalSaveConflicts = max(0, Int(rawValue) ?? 0)
        }

        guard let remainingUITestLocalSaveConflicts, remainingUITestLocalSaveConflicts > 0 else {
            return nil
        }

        consumedUITestLocalSaveConflicts += 1
        self.remainingUITestLocalSaveConflicts = remainingUITestLocalSaveConflicts - 1
        return consumedUITestLocalSaveConflicts
    }

    /// UI-test seam: the injected conflicting file also grows an extra binary
    /// pool field, so a merge against it hits the attachment-pool divergence
    /// blocker.
    static var uiTestLocalSaveConflictDivergesPool: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingLaunchArg)
            && ProcessInfo.processInfo.environment[uiTestLocalSaveConflictDivergesPoolEnv] == "1"
    }
    #endif

    /// Ends the name of a backup that rotation never removes: an AutoFill
    /// save that could not be merged into the database file
    /// (`PendingLocalSaveStore.moveToBackups`). It is the only copy of that
    /// save, and no later backup contains it.
    static let retainedBackupSuffix = "-autofill"

    static func isRetainedBackup(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix(retainedBackupSuffix)
    }

    static func pruneBackups(for reference: DatabaseReference, keeping count: Int) throws {
        guard count >= 0 else { return }

        let backupsToRemove = recentBackups(for: reference)
            .filter { isRetainedBackup($0) == false }
            .dropFirst(count)
        for url in backupsToRemove {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    private static func loadDatabases() -> [DatabaseReference] {
        decodeStoredDatabases()
    }

    /// Decodes `database-list.json` without triggering UI-test bootstrap or
    /// legacy migration. The `activeAutoFillDatabaseID` setter's gate uses
    /// this because it can run mid-migration, where re-entering
    /// `loadDatabases()` could recurse back into the migration path.
    private static func decodeStoredDatabases() -> [DatabaseReference] {
        (try? readRegistry(at: databaseListURL)) ?? []
    }

    private static func normalized(_ references: [DatabaseReference]) -> [DatabaseReference] {
        var quickLaunchAlreadyAssigned = false

        return references.map { reference in
            var normalizedReference = reference

            let trimmedNickname = normalizedReference.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedReference.nickname = trimmedNickname?.isEmpty == true ? nil : trimmedNickname

            if normalizedReference.isQuickLaunch {
                if quickLaunchAlreadyAssigned {
                    normalizedReference.isQuickLaunch = false
                } else {
                    quickLaunchAlreadyAssigned = true
                }
            }

            return normalizedReference
        }
    }

    private static var applicationSupportURL: URL {
        sharedContainerURL.appendingPathComponent(applicationSupportPathComponent, isDirectory: true)
    }

    private static var backupsRootURL: URL {
        applicationSupportURL.appendingPathComponent(backupsDirectoryName, isDirectory: true)
    }

    #if DEBUG
    private static func bootstrapForUITestingIfNeeded() {
        guard didBootstrapUITesting == false else { return }
        guard ProcessInfo.processInfo.arguments.contains(uiTestingLaunchArg) else { return }
        didBootstrapUITesting = true

        removeUITestDocumentsDatabases()

        var references =
            uiTestLocalDatabaseReferences()
            + uiTestCloudDatabases()
        if uiTestEnvironmentFlag(uiTestDatabaseReadOnlyEnv) {
            references = references.map { reference in
                var updatedReference = reference
                updatedReference.isReadOnly = true
                return updatedReference
            }
        }
        if uiTestEnvironmentFlag(uiTestEnableQuickLaunchEnv), references.isEmpty == false {
            references[0].isQuickLaunch = true
        }
        // Cloud accounts live in `SharedVaultStore.cloudAccountDefaults`, which
        // differs per platform. Scrub the group suite too, or on macOS a stale
        // legacy value can be migrated back in mid-test; on iOS the two are the
        // same suite and the second remove is a no-op.
        SharedVaultStore.cloudAccountDefaults.removeObject(forKey: cloudAccountsStorageKey)
        sharedDefaults.removeObject(forKey: cloudAccountsStorageKey)
        try? PendingUploadQueue.clearAll()
        PendingLocalSaveStore.clearAll()
        try? FileManager.default.removeItem(at: SharedVaultStore.databaseCacheDirectory)
        try? FileManager.default.removeItem(at: SharedVaultStore.cloudCacheDirectory)

        if let cloudAccounts = uiTestCloudAccounts(),
           let encodedAccounts = try? JSONEncoder().encode(cloudAccounts) {
            SharedVaultStore.cloudAccountDefaults.set(encodedAccounts, forKey: cloudAccountsStorageKey)
        }

        _ = mutateRegistry(onMissing: { [] }) { rows -> RegistryDecision<Void> in
            rows = references
            return .write(())
        }
        activeAutoFillDatabaseID = nil
    }

    private static func uiTestLocalDatabaseReferences() -> [DatabaseReference] {
        let environment = ProcessInfo.processInfo.environment

        if let rawJSON = environment[uiTestDatabasesJSONEnv],
           let data = rawJSON.data(using: .utf8),
           let payloads = try? JSONDecoder().decode([UITestDatabasePayload].self, from: data),
           !payloads.isEmpty {
            return payloads.compactMap(uiTestReference(from:))
        }

        return []
    }

    private static func uiTestReference(from payload: UITestDatabasePayload) -> DatabaseReference? {
        guard let data = Data(base64Encoded: payload.base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        switch payload.disposition {
        case nil:
            guard let url = writeUITestDatabase(data: data, requestedFilename: payload.filename) else {
                return nil
            }
            return try? makeReference(from: url)
        case .documents:
            guard let url = writeUITestDocumentsDatabase(data: data, requestedFilename: payload.filename) else {
                return nil
            }
            return try? makeReference(from: url)
        case .documentsUnregistered:
            _ = writeUITestDocumentsDatabase(data: data, requestedFilename: payload.filename)
            return nil
        case .documentsMissing:
            guard let url = writeUITestDocumentsDatabase(data: data, requestedFilename: payload.filename),
                  let reference = try? makeReference(from: url) else {
                return nil
            }
            try? FileManager.default.removeItem(at: url)
            return reference
        }
    }

    private static func uiTestCloudDatabases() -> [DatabaseReference] {
        let environment = ProcessInfo.processInfo.environment
        guard let rawJSON = environment[uiTestCloudDatabasesJSONEnv],
              let data = rawJSON.data(using: .utf8),
              let payloads = try? uiTestJSONDecoder().decode([UITestCloudDatabasePayload].self, from: data) else {
            return []
        }

        return payloads.map(makeCloudReference(from:))
    }

    private static func uiTestCloudAccounts() -> [CloudAccount]? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawJSON = environment[uiTestCloudAccountsJSONEnv],
              let data = rawJSON.data(using: .utf8) else {
            return nil
        }

        return try? uiTestJSONDecoder().decode([CloudAccount].self, from: data)
    }

    private static func uiTestEnvironmentFlag(_ key: String) -> Bool {
        let rawValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func writeUITestDatabase(data: Data, requestedFilename: String) -> URL? {
        let safeFilename = (requestedFilename as NSString).lastPathComponent
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(safeFilename, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func writeUITestDocumentsDatabase(data: Data, requestedFilename: String) -> URL? {
        let safeFilename = (requestedFilename as NSString).lastPathComponent
        let url = documentsDirectoryURL.appendingPathComponent(safeFilename, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: documentsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Stale top-level KDBX files left in Documents by a previous UI-test
    /// launch would be re-registered by `DocumentsVaultScanner` and pollute
    /// the next test; scrub them before seeding. Reached only behind the
    /// `-ui-testing` launch argument.
    private static func removeUITestDocumentsDatabases() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: documentsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents where url.pathExtension.lowercased() == "kdbx" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func makeCloudReference(from payload: UITestCloudDatabasePayload) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: payload.file.name,
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: payload.provider,
                    accountId: payload.accountId,
                    fileId: payload.file.id,
                    displayPath: payload.file.path,
                    remoteContentHash: nil,
                    remoteModifiedAt: payload.file.modifiedDate,
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }

    private static func uiTestJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    #endif

    private static func makeReference(from url: URL) throws -> DatabaseReference {
        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)

        return DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename(for: url),
            bookmarkData: bookmarkData,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil,
            isDocumentsResident: isTopLevelDocumentsFile(url)
        )
    }

    /// Direct children only: rebind identity is exactly `Documents/<filename>`,
    /// so a nested file must never be classified as Documents-resident — its
    /// stranded reference could otherwise steal an unrelated same-name
    /// top-level file.
    static func isTopLevelDocumentsFile(_ url: URL) -> Bool {
        normalizedFilePath(for: url.deletingLastPathComponent()) == normalizedFilePath(for: documentsDirectoryURL)
    }

    // MARK: - Removed Documents files

    /// Holds no filename, path or vault bytes: only hashes and the file's
    /// inode and status-change time.
    private struct RemovedDocumentsFile: Codable, Hashable {
        /// SHA-256 of the name, size and modification date.
        let metadata: String
        /// SHA-256 of the bytes, so an edit that keeps the metadata is a new file.
        let content: String
        let fileNumber: UInt64
        let statusChange: UInt64

        /// Any write changes the status-change time, so a match proves the
        /// bytes unchanged without rereading them.
        func matches(_ snapshot: DocumentsFileSnapshot) -> Bool {
            metadata == snapshot.metadata && fileNumber == snapshot.fileNumber && statusChange == snapshot.statusChange
        }
    }

    /// What the scan read of a file before the registry lock.
    private struct RemovalCheck {
        let snapshot: DocumentsFileSnapshot?
        let contentDigest: String?
    }

    private struct DocumentsFileSnapshot: Equatable {
        let metadata: String
        let fileNumber: UInt64
        let statusChange: UInt64
    }

    /// The file a removal records, read before the registry lock and checked
    /// again under it with a `stat` alone.
    private struct RemovedDocumentsFileCandidate {
        let url: URL?
        let file: RemovedDocumentsFile?

        /// False when the file changed since it was read: the removal is
        /// refused rather than hashing under the lock. A file that could not
        /// be read records nothing and does not block the removal.
        func isCurrent(for reference: DatabaseReference) -> Bool {
            let currentURL = DatabaseListStore.currentDocumentsFileURL(for: reference)
            guard currentURL?.standardizedFileURL == url?.standardizedFileURL else { return false }
            guard let currentURL, let file else { return true }
            return DatabaseListStore.documentsFileSnapshot(for: currentURL).map(file.matches) == true
        }
    }

    private static func removedDocumentsFileRecord(for reference: DatabaseReference) -> RemovedDocumentsFileCandidate {
        guard let url = currentDocumentsFileURL(for: reference) else { return RemovedDocumentsFileCandidate(url: nil, file: nil) }
        guard let snapshot = documentsFileSnapshot(for: url), let content = contentDigest(of: url),
              documentsFileSnapshot(for: url) == snapshot else { return RemovedDocumentsFileCandidate(url: url, file: nil) }
        return RemovedDocumentsFileCandidate(url: url, file: RemovedDocumentsFile(
            metadata: snapshot.metadata, content: content,
            fileNumber: snapshot.fileNumber, statusChange: snapshot.statusChange
        ))
    }

    /// Only the app's scan reads this, so it stays out of the App Group. The
    /// Mac unit-test host is the real app, hence the redirect.
    private static var removedDocumentsFilesURL: URL {
        let directory = AppGroupContainer.isRedirectedForTesting ? applicationSupportURL : URL.applicationSupportDirectory
        return directory.appendingPathComponent("removed-documents-files.json", isDirectory: false)
    }

    /// Existing ancestor from which the durable write creates missing directories.
    private static var removedDocumentsFilesAnchor: URL {
        AppGroupContainer.isRedirectedForTesting ? sharedContainerURL : URL.libraryDirectory
    }

    private static var removedDocumentsFiles: Set<RemovedDocumentsFile> {
        guard let data = try? Data(contentsOf: removedDocumentsFilesURL),
              let files = try? JSONDecoder().decode([RemovedDocumentsFile].self, from: data) else { return [] }
        return Set(files)
    }

    /// Applies `change` to the record and writes it durably; false when
    /// `change` reports nothing to write. Throws when the result may not
    /// survive a crash.
    private static func changeRemovedDocumentsFiles(_ change: (inout Set<RemovedDocumentsFile>) -> Bool) throws -> Bool {
        var files = removedDocumentsFiles
        guard change(&files) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(files.sorted { ($0.metadata, $0.content) < ($1.metadata, $1.content) })
        switch writeWithDurabilityOutcome(data, to: removedDocumentsFilesURL, directoryAnchor: removedDocumentsFilesAnchor) {
        case .durable: return true
        case .notPublished(let error), .publishedWithoutConfirmedDurability(let error): throw error
        }
    }

    /// The digest the scan needs only when a record shares the file's
    /// metadata but not its status, so an unchanged removed vault is not reread.
    private static func contentDigestIfRemoved(_ url: URL, _ snapshot: DocumentsFileSnapshot) -> String? {
        guard removedDocumentsFiles.contains(where: { $0.metadata == snapshot.metadata }) else { return nil }
        guard let content = contentDigest(of: url), documentsFileSnapshot(for: url) == snapshot else { return nil }
        return content
    }

    /// Under the registry lock, so only a `stat`. A file that changed since
    /// the scan read it, or one a removal recorded meanwhile, counts as
    /// removed until the next scan rereads it.
    private static func isRemovedDocumentsFile(_ url: URL, checkedAs check: RemovalCheck) -> Bool {
        guard let snapshot = documentsFileSnapshot(for: url) else { return false }
        let candidates = removedDocumentsFiles.filter { $0.metadata == snapshot.metadata }
        guard !candidates.isEmpty else { return false }
        guard snapshot == check.snapshot else { return true }
        if candidates.contains(where: { $0.matches(snapshot) }) { return true }
        guard let content = check.contentDigest else { return true }
        return candidates.contains { $0.content == content }
    }

    /// Returns the record only when this call added it, so a failed removal
    /// can take back exactly what it recorded. Throws when the record may not
    /// survive a crash, so the removal is refused instead.
    private static func rememberRemovedDocumentsFile(_ file: RemovedDocumentsFile?) throws -> RemovedDocumentsFile? {
        guard let file else { return nil }
        do {
            return try changeRemovedDocumentsFiles { $0.insert(file).inserted } ? file : nil
        } catch {
            forgetRemovedDocumentsFiles([file])
            throw error
        }
    }

    /// An explicit add undoes the removal, so a later removal that records
    /// nothing (file missing) cannot leave the old record hiding the file.
    /// Clears every record with the file's metadata, which needs no hashing
    /// under the lock, and returns them; throws when clearing may not last.
    private static func forgetRemovedDocumentsFile(at url: URL) throws -> [RemovedDocumentsFile] {
        guard let snapshot = documentsFileSnapshot(for: url) else { return [] }
        var forgotten: [RemovedDocumentsFile] = []
        _ = try changeRemovedDocumentsFiles { files in
            forgotten = files.filter { $0.metadata == snapshot.metadata }
            files.subtract(forgotten)
            return !forgotten.isEmpty
        }
        return forgotten
    }

    /// Best effort: a record left behind still lets an explicit add, which
    /// clears it or fails, bring the file back.
    private static func forgetRemovedDocumentsFiles(_ files: [RemovedDocumentsFile]) {
        guard !files.isEmpty else { return }
        _ = try? changeRemovedDocumentsFiles { records in
            let count = records.count
            records.subtract(files)
            return records.count != count
        }
    }

    /// Best effort: the file was one the user just asked to add.
    private static func restoreRemovedDocumentsFiles(_ files: [RemovedDocumentsFile]) {
        guard !files.isEmpty else { return }
        _ = try? changeRemovedDocumentsFiles { $0.formUnion(files); return true }
    }

    private static func documentsFileSnapshot(for url: URL) -> DocumentsFileSnapshot? {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let identity = [
            url.lastPathComponent.precomposedStringWithCanonicalMapping,
            String(info.st_size),
            String(info.st_mtimespec.tv_sec),
            String(info.st_mtimespec.tv_nsec),
        ].joined(separator: "\u{1F}")
        return DocumentsFileSnapshot(
            metadata: SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined(),
            fileNumber: UInt64(info.st_ino),
            statusChange: UInt64(bitPattern: Int64(info.st_ctimespec.tv_sec)) &* 1_000_000_000 &+ UInt64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func contentDigest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Persists a re-minted bookmark for a stranded Documents-resident
    /// reference, mutating ONLY `bookmarkData` on the stored copy so
    /// concurrent edits to other fields (nickname, key file, read-only,
    /// AutoFill, lastOpenedAt) are not rolled back. Refuses (false) when the
    /// id is no longer listed — a removed reference must not be resurrected —
    /// or when a different live Documents-resident reference already resolves
    /// to `url`, which rebinding would steal. The claimant scan only resolves
    /// Documents-resident bookmarks: they are own-container, so resolution is
    /// cheap; a non-resident (potentially file-provider) bookmark must never
    /// be resolved on this path.
    @discardableResult
    static func rebindBookmarkData(_ bookmarkData: Data, for observed: DatabaseReference, toFileAt url: URL) -> Bool {
        rebindDocumentsReference(bookmarkData, for: observed, toFileAt: url) != nil
    }

    private static func rebindDocumentsReference(_ bookmarkData: Data, for observed: DatabaseReference, toFileAt url: URL) -> DatabaseReference? {
        let result = mutateRegistry { rows -> RegistryDecision<DatabaseReference> in
            guard let index = rows.firstIndex(where: { $0.id == observed.id }) else { return .missing }
            guard rows[index] == observed else { return .rejected }
            if let claimant = existingLocalReference(matching: url, in: rows.filter(\.isDocumentsResident)),
               claimant.id != observed.id { return .rejected }
            guard rows[index].bookmarkData != bookmarkData else { return .noop(rows[index]) }
            rows[index].bookmarkData = bookmarkData
            return .write(rows[index])
        }
        switch result {
        case .durable(let reference), .noop(let reference): return reference
        default: return nil
        }
    }

    /// Persists a re-derived Documents identity after a Files-app rename or
    /// move, mutating ONLY `filename` and `isDocumentsResident` on the stored
    /// copy; concurrent edits to other fields survive. A reference that left
    /// top-level Documents drops the flag and stops participating in
    /// path-keyed rebinding.
    @discardableResult
    static func rederiveDocumentsIdentity(for observed: DatabaseReference, filename: String, isDocumentsResident: Bool) -> Bool {
        succeeded(mutateRegistry { rows -> RegistryDecision<Void> in
            guard let index = rows.firstIndex(where: { $0.id == observed.id }) else { return .missing }
            guard PendingLocalSaveStore.PreferenceObservation(observed).matches(rows[index]),
                  rows[index].filename == observed.filename,
                  rows[index].isDocumentsResident == observed.isDocumentsResident else { return .rejected }
            guard rows[index].filename != filename || rows[index].isDocumentsResident != isDocumentsResident else { return .noop(()) }
            rows[index].filename = filename
            rows[index].isDocumentsResident = isDocumentsResident
            return .write(())
        })
    }

    /// Whether a Documents-resident reference's file is gone: its own
    /// bookmark does not resolve to an available file AND nothing sits at
    /// `Documents/<filename>`. Pure status check — no lock, no writes, no
    /// heal; a file present at the path is rebindable and therefore NOT
    /// missing (the locate paths perform the heal on unlock/save/scan).
    /// Own-container URLs only, so it never blocks on a file provider.
    static func isDocumentsFileMissing(for reference: DatabaseReference) -> Bool {
        reference.isDocumentsResident && currentDocumentsFileURL(for: reference) == nil
    }

    /// The file a Documents-resident reference stands for: its bookmark's
    /// target when available (it follows a Files-app rename the scan has not
    /// recorded yet), else whatever sits at `Documents/<filename>`. Own
    /// container only, so it never blocks on a file provider.
    private static func currentDocumentsFileURL(for reference: DatabaseReference) -> URL? {
        guard reference.isDocumentsResident else { return nil }

        if let bookmarkData = reference.bookmarkData,
           let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData) {
            let url = resolved.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if SecurityScopedBookmarkManager.isInTrashDirectory(url) == false,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let candidate = documentsDirectoryURL.appendingPathComponent(reference.filename, isDirectory: false)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Rebinds a Documents-resident reference to the KDBX file currently at
    /// `Documents/<filename>` after its bookmark went stale, keeping the
    /// reference's id, nickname, key file, and settings, and reseeding the
    /// AutoFill shared cache with the replacement's bytes. Nil when the
    /// reference is not Documents-resident, no file with the KDBX magic sits
    /// at that path (a garbage or mid-copy file must never be bound), or the
    /// rebind write was refused (id removed, or the path already belongs to
    /// another reference).
    private static func reboundDocumentsResidentLocation(
        for reference: DatabaseReference, onRebind: (DatabaseReference) -> Void
    ) -> LocalDatabaseFileLocation? {
        guard reference.isDocumentsResident else { return nil }

        let candidate = documentsDirectoryURL.appendingPathComponent(reference.filename, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false,
              DocumentPickerService.hasKDBXMagic(at: candidate),
              let bookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: candidate),
              let rebound = rebindDocumentsReference(bookmarkData, for: reference, toFileAt: candidate) else {
            return nil
        }

        onRebind(rebound)
        cacheInitialCopyIfPossible(from: candidate, for: reference.id)
        return .available(candidate)
    }

    private static func migratedLegacyReference() -> DatabaseReference? {
        guard let bookmarkData = SharedVaultStore.legacyBookmarkData,
              let filename = SharedVaultStore.legacyDatabaseFilename else {
            return nil
        }

        return DatabaseReference(
            id: deterministicMigrationID(bookmarkData: bookmarkData, filename: filename),
            nickname: nil,
            filename: filename,
            bookmarkData: bookmarkData,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: true,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: filename
        )
    }

    private static func deterministicMigrationID(bookmarkData: Data, filename: String) -> UUID {
        var seed = Data(bookmarkData)
        seed.append(contentsOf: filename.utf8)
        var hash = Array(SHA256.hash(data: seed).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80

        return hash.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }

    private static func cacheURL(for databaseID: UUID) -> URL {
        SharedVaultStore.databaseCacheDirectory.appendingPathComponent("\(databaseID.uuidString).kdbx", isDirectory: false)
    }

    private static func cloudCacheURL(for metadata: CloudSyncMetadata) -> URL {
        let accountComponent = safeCloudPathComponent("\(metadata.provider)-\(metadata.accountId)")
        let fileComponent = SHA256.hash(data: Data(metadata.fileId.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return SharedVaultStore.cloudCacheDirectory
            .appendingPathComponent(accountComponent, isDirectory: true)
            .appendingPathComponent("\(fileComponent).kdbx", isDirectory: false)
    }

    private static func safeCloudPathComponent(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return rawValue.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private static func copyLegacyCachedDatabaseIfNeeded(to databaseID: UUID) {
        guard let legacyCachedURL = SharedVaultStore.legacyCachedDatabaseURL else { return }
        guard FileManager.default.fileExists(atPath: cacheURL(for: databaseID).path) == false else { return }

        do {
            guard let reference = databases.first(where: { $0.id == databaseID }) else { return }
            let lease = try PendingLocalSaveStore.captureCacheReadLease(for: reference)
            let data = try CoordinatedFileReader.readData(from: legacyCachedURL)
            try LocalDatabaseSaver.cacheLocalSnapshot(data, for: reference, lease: lease, legacyMigrationSource: legacyCachedURL)
        } catch {
            return
        }
    }

    /// Shared body of the `activeAutoFillDatabase` getter and the
    /// `defaultAutoFillDatabase` fallback chain: the pointed-to reference when
    /// it exists and is AutoFill-enabled, else the gated legacy-filename
    /// fallback. Behavior is identical to the pre-slice-03 getter.
    private static func activeAutoFillDatabase(in currentDatabases: [DatabaseReference]) -> DatabaseReference? {
        if let activeAutoFillDatabaseID,
           let reference = currentDatabases.first(where: { $0.id == activeAutoFillDatabaseID }),
           reference.autoFillEnabled {
            return reference
        }

        return fallbackAutoFillDatabase(in: currentDatabases)
    }

    private static func fallbackAutoFillDatabase(in references: [DatabaseReference]) -> DatabaseReference? {
        references.first { $0.legacyKeychainFilename != nil && $0.autoFillEnabled }
    }

    /// The id the active pointer should fall to after `excludedID` stops being
    /// eligible: the most recently opened AutoFill-enabled database, or nil
    /// when no other enabled database has ever been opened.
    private static func nextActiveAutoFillDatabaseID(excluding excludedID: UUID) -> UUID? {
        loadDatabases()
            .filter { $0.autoFillEnabled && $0.id != excludedID && $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }?
            .id
    }

    private static func existingLocalReference(
        matching url: URL,
        in references: [DatabaseReference]
    ) -> DatabaseReference? {
        let targetPath = normalizedFilePath(for: url)
        return references.first { reference in
            guard reference.cloudSyncMetadata == nil,
                  let bookmarkData = reference.bookmarkData,
                  let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData) else {
                return false
            }
            return normalizedFilePath(for: resolved.url) == targetPath
        }
    }

    private static func validateCreatedLocal(
        _ reference: DatabaseReference,
        in references: [DatabaseReference]
    ) throws {
        if let bookmarkData = reference.bookmarkData,
           let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData),
           let duplicate = existingLocalReference(matching: resolved.url, in: references) {
            throw AddDatabaseError.duplicateFile(
                existingReferenceID: duplicate.id,
                filename: duplicate.displayName
            )
        }

        if reference.bookmarkData == nil {
            try validateAppOnlyCreatedLocal(reference, in: references)
        }
    }

    private static func validateAppOnlyCreatedLocal(
        _ reference: DatabaseReference,
        in references: [DatabaseReference]
    ) throws {
        let targetFilename = reference.filename.lowercased()
        let hasDuplicate = references.contains { existing in
            existing.cloudSyncMetadata == nil &&
            existing.bookmarkData == nil &&
            existing.filename.lowercased() == targetFilename
        }
        if hasDuplicate {
            throw AddDatabaseError.duplicateCreatedFilename(filename: reference.filename)
        }
    }

    private static func validateCreatedCloud(
        _ reference: DatabaseReference,
        in references: [DatabaseReference]
    ) throws {
        guard let metadata = reference.cloudSyncMetadata else { return }
        try validateCreatedCloud(
            provider: metadata.provider,
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            filename: reference.filename,
            in: references
        )
    }

    private static func validateCreatedCloud(
        provider: String,
        accountId: String,
        fileId: String,
        filename: String,
        in references: [DatabaseReference]
    ) throws {
        if let duplicate = references.first(where: { existing in
            guard let metadata = existing.cloudSyncMetadata else { return false }
            return metadata.provider == provider
                && metadata.accountId == accountId
                && metadata.fileId == fileId
        }) {
            throw AddDatabaseError.duplicateFile(
                existingReferenceID: duplicate.id,
                filename: filename
            )
        }
        try requireNoDetachedUpload(provider: provider, accountID: accountId, fileID: fileId, in: references)
    }

    private static func requireNoDetachedUpload(
        provider: String, accountID: String, fileID: String, in references: [DatabaseReference]
    ) throws {
        let detached = try PendingUploadQueue.readJournal(excluding: Set(references.map(\.id)))
        for entry in detached where entry.marker.detachedFilename != nil {
            guard let binding = entry.marker.binding, binding.isRecognized else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if sameCloudFile(provider, accountID, fileID, binding.provider, binding.accountID, binding.fileID) {
                throw AddDatabaseError.unresolvedCloudUpload
            }
        }
    }

    private static func sameCloudFile(_ provider: String, _ accountID: String, _ fileID: String,
                                      _ otherProvider: String?, _ otherAccountID: String?, _ otherFileID: String?) -> Bool {
        provider == otherProvider && accountID == otherAccountID && fileID == otherFileID
    }

    private static func normalizedFilePath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func cacheInitialCopyIfPossible(from url: URL, for databaseID: UUID,
        read: (URL) throws -> Data = readSecurityScopedData
    ) {
        guard let reference = databases.first(where: { $0.id == databaseID }),
              let lease = try? PendingLocalSaveStore.captureCacheReadLease(for: reference),
              let data = try? read(url) else { return }
        try? LocalDatabaseSaver.cacheLocalSnapshot(data, for: reference, lease: lease)
    }

    private static func readSecurityScopedData(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try CoordinatedFileReader.readData(from: url)
    }

    private static func filename(for url: URL) -> String {
        let filename = (url.lastPathComponent as NSString).lastPathComponent
        return filename.isEmpty ? "database.kdbx" : filename
    }
}
