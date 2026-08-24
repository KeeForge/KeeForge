import CryptoKit
import Foundation

enum DatabaseListStore {
    enum AddDatabaseError: Error, LocalizedError, Equatable {
        case duplicateFile(existingReferenceID: UUID, filename: String)
        case duplicateCreatedFilename(filename: String)

        var errorDescription: String? {
            switch self {
            case .duplicateFile(_, let filename):
                return String(localized: "“\(filename)” is already in your database list.")
            case .duplicateCreatedFilename(let filename):
                return String(localized: "“\(filename)” is already used by a KeeForge-only database.")
            }
        }
    }

    private static let databaseListFilename = "database-list.json"
    private static let applicationSupportPathComponent = "Library/Application Support"
    private static let backupsDirectoryName = "backups"
    private static let activeAutoFillDatabaseIDKey = "activeAutoFillDatabaseID"
    private static let migrationVersionKey = "databaseListMigrationVersion"
    private static let currentMigrationVersion = 1
    private static let uiTestingLaunchArg = "-ui-testing"
    private static let uiTestDBBase64Env = "UI_TEST_DB_BASE64"
    private static let uiTestDBFilenameEnv = "UI_TEST_DB_FILENAME"
    private static let uiTestDatabasesJSONEnv = "UI_TEST_DATABASES_JSON"
    private static let uiTestCloudDatabasesJSONEnv = "UI_TEST_CLOUD_DATABASES_JSON"
    private static let uiTestCloudAccountsJSONEnv = "UI_TEST_CLOUD_ACCOUNTS_JSON"
    private static let uiTestLocalSaveConflictCountEnv = "UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"
    private static let uiTestLocalSaveConflictDivergesPoolEnv = "UI_TEST_LOCAL_SAVE_CONFLICT_DIVERGES_POOL"
    private static let uiTestDatabaseReadOnlyEnv = "UI_TEST_DATABASE_READ_ONLY"
    private static let uiTestEnableQuickLaunchEnv = "UI_TEST_ENABLE_QUICK_LAUNCH"
    private static let cloudAccountsStorageKey = "KeeForge.cloudAccounts"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
    }

    private static var sharedContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID)
            ?? FileManager.default.temporaryDirectory
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

    private nonisolated(unsafe) static var didBootstrapUITesting = false
    private nonisolated(unsafe) static var remainingUITestLocalSaveConflicts: Int?
    private nonisolated(unsafe) static var consumedUITestLocalSaveConflicts = 0

    /// Serializes every load/mutate/save of `database-list.json`. Detached
    /// cloud-upload tasks call `update(_:)` while main-actor writers mutate the
    /// same file; without this each mutator's read-modify-write could interleave
    /// and clobber a concurrent change. The lock is recursive because compound
    /// mutators (e.g. `setReadOnly`, `markDatabaseOpened`) run their whole
    /// read-modify-write under it and then re-enter through `loadDatabases()` /
    /// `saveDatabases()` on the same thread.
    private static let stateLock = NSRecursiveLock()

    private static func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

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

    static var databases: [DatabaseReference] {
        get { loadDatabases() }
        set { saveDatabases(newValue) }
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
        let currentDatabases = loadDatabases()

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
        let reference = try withStateLock { () throws -> DatabaseReference in
            var currentDatabases = loadDatabases()
            if let duplicate = existingLocalReference(matching: url, in: currentDatabases) {
                throw AddDatabaseError.duplicateFile(
                    existingReferenceID: duplicate.id,
                    filename: duplicate.displayName
                )
            }
            let reference = try makeReference(from: url)
            currentDatabases.append(reference)
            saveDatabases(currentDatabases)
            return reference
        }
        cacheInitialCopyIfPossible(from: url, for: reference.id)
        return reference
    }

    @discardableResult
    static func addCloud(
        provider: String,
        accountId: String,
        file: CloudFile
    ) -> DatabaseReference {
        withStateLock {
            if let existing = loadDatabases().first(where: {
                guard let metadata = $0.cloudSyncMetadata else { return false }
                return metadata.provider == provider && metadata.accountId == accountId && metadata.fileId == file.id
            }) {
                return existing
            }

            var currentDatabases = loadDatabases()
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
                        lastSyncError: nil
                    )
                )
            )
            currentDatabases.append(reference)
            saveDatabases(currentDatabases)
            return reference
        }
    }

    static func addCreatedLocal(_ reference: DatabaseReference) throws {
        try withStateLock {
            var currentDatabases = loadDatabases()
            try validateCreatedLocal(reference, in: currentDatabases)
            currentDatabases.append(reference)
            saveDatabases(currentDatabases)
        }
    }

    static func addCreatedCloud(_ reference: DatabaseReference) throws {
        try withStateLock {
            var currentDatabases = loadDatabases()
            try validateCreatedCloud(reference, in: currentDatabases)
            currentDatabases.append(reference)
            saveDatabases(currentDatabases)
        }
    }

    static func addAppOnlyCreatedLocal(_ reference: DatabaseReference, encryptedBytes: Data) throws {
        try withStateLock {
            var currentDatabases = loadDatabases()
            try validateAppOnlyCreatedLocal(reference, in: currentDatabases)
            try cacheDatabaseCopy(encryptedBytes, for: reference)
            currentDatabases.append(reference)
            saveDatabases(currentDatabases)
        }
    }

    static func validateCreatedLocal(_ reference: DatabaseReference) throws {
        try validateCreatedLocal(reference, in: loadDatabases())
    }

    static func validateAppOnlyCreatedLocal(_ reference: DatabaseReference) throws {
        try validateAppOnlyCreatedLocal(reference, in: loadDatabases())
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

    static func remove(id: UUID) {
        withStateLock {
            let currentDatabases = loadDatabases()
            guard let removedReference = currentDatabases.first(where: { $0.id == id }) else { return }
            // Computed before the registry mutation drops the reference; also
            // decides the legacy sweep below (legacy bare-UUID identities can
            // only have been published by the then-active database — see
            // `setAutoFillEnabled`).
            let wasActiveAutoFillDatabase = activeAutoFillDatabase?.id == id

            KeychainService.deleteCompositeKey(for: removedReference.id)
            if let legacyFilename = removedReference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
            }

            try? FileManager.default.removeItem(at: cacheLocation(for: removedReference))
            try? FileManager.default.removeItem(at: databaseBackupDirectoryURL(for: removedReference))
            try? PendingUploadQueue.removeAllMarkers(for: removedReference.id)

            let remainingDatabases = currentDatabases.filter { $0.id != id }
            if activeAutoFillDatabaseID == id {
                activeAutoFillDatabaseID = nil
            }
            saveDatabases(remainingDatabases)

            // Every removal drops the database's published identities —
            // targeted, works while locked, leaves other databases'
            // suggestions in place. (Pre-slice-04 only removing the *active*
            // database cleared anything, and it wiped the whole store.)
            CredentialIdentityStoreManager.removeIdentities(
                forDatabase: id,
                includingLegacyIdentifiers: wasActiveAutoFillDatabase
            )
        }
    }

    static func update(_ reference: DatabaseReference) {
        withStateLock {
            var currentDatabases = loadDatabases()

            if let index = currentDatabases.firstIndex(where: { $0.id == reference.id }) {
                currentDatabases[index] = reference
            } else {
                currentDatabases.append(reference)
            }

            saveDatabases(currentDatabases)
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
    static func updateCloudSyncMetadata(
        for id: UUID,
        ifUnchangedFrom observed: CloudSyncMetadata,
        mutate: (inout CloudSyncMetadata) -> Void
    ) -> DatabaseReference? {
        withStateLock {
            var currentDatabases = loadDatabases()
            guard let index = currentDatabases.firstIndex(where: { $0.id == id }),
                  let storedMetadata = currentDatabases[index].cloudSyncMetadata else {
                return nil
            }

            guard cloudRevisionIdentity(storedMetadata) == cloudRevisionIdentity(observed) else {
                return currentDatabases[index]
            }

            currentDatabases[index].updateCloudSyncMetadata(mutate)
            guard saveDatabases(currentDatabases) else { return nil }
            return currentDatabases[index]
        }
    }

    /// Identity for the compare-and-skip above. Revision alone is not enough:
    /// references predating rev tracking carry only a content hash, which is
    /// then the entire signal that the remote moved.
    private static func cloudRevisionIdentity(_ metadata: CloudSyncMetadata) -> String {
        "\(metadata.remoteRev ?? "")\u{1F}\(metadata.remoteContentHash ?? "")"
    }

    static func setReadOnly(_ isReadOnly: Bool, for reference: DatabaseReference) {
        withStateLock {
            guard var updatedReference = loadDatabases().first(where: { $0.id == reference.id }) else { return }
            updatedReference.isReadOnly = isReadOnly
            update(updatedReference)
        }
    }

    /// Owns the consequences of toggling a database's AutoFill participation
    /// (mirroring how `remove(id:)` owns removal consequences): disabling
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
    static func setAutoFillEnabled(_ isEnabled: Bool, for reference: DatabaseReference) {
        withStateLock {
            guard var updatedReference = loadDatabases().first(where: { $0.id == reference.id }) else { return }
            guard updatedReference.autoFillEnabled != isEnabled else { return }

            let wasActive = activeAutoFillDatabase?.id == reference.id
            updatedReference.autoFillEnabled = isEnabled
            update(updatedReference)

            guard isEnabled == false else { return }

            if wasActive {
                activeAutoFillDatabaseID = nextActiveAutoFillDatabaseID(excluding: reference.id)
            }
            CredentialIdentityStoreManager.removeIdentities(
                forDatabase: reference.id,
                includingLegacyIdentifiers: wasActive
            )
        }
    }

    /// `destination` indexes the list as it was *before* the move, so it has to
    /// be pulled back by however many moved rows sat above it.
    static func move(from source: IndexSet, to destination: Int) {
        withStateLock {
            var currentDatabases = loadDatabases()
            let movingItems = source.map { currentDatabases[$0] }
            let liftedAbove = source.count { $0 < destination }

            for index in source.sorted(by: >) {
                currentDatabases.remove(at: index)
            }

            let insertionIndex = min(max(destination - liftedAbove, 0), currentDatabases.count)
            currentDatabases.insert(contentsOf: movingItems, at: insertionIndex)
            saveDatabases(currentDatabases)
        }
    }

    static func markDatabaseOpened(id: UUID, at date: Date = .now) {
        withStateLock {
            guard var reference = loadDatabases().first(where: { $0.id == id }) else { return }
            reference.lastOpenedAt = date
            update(reference)
            // Opening a database with AutoFill disabled must not make it the
            // active AutoFill database; the previous pointer stays in place.
            // (The `activeAutoFillDatabaseID` setter also refuses disabled
            // ids; this guard just makes the write path explicit.)
            if reference.autoFillEnabled {
                activeAutoFillDatabaseID = id
            }
        }
    }

    static func clearLegacyKeychainFilename(for id: UUID) {
        withStateLock {
            guard var reference = loadDatabases().first(where: { $0.id == id }) else { return }
            guard reference.legacyKeychainFilename != nil else { return }
            reference.legacyKeychainFilename = nil
            update(reference)
        }
    }

    static func cacheDatabaseCopy(_ data: Data, for databaseID: UUID) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: SharedVaultStore.databaseCacheDirectory.path) {
            try fm.createDirectory(
                at: SharedVaultStore.databaseCacheDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        try CoordinatedFileReader.writeData(
            data,
            to: cacheURL(for: databaseID),
            options: .atomicProtected
        )
    }

    static func cacheDatabaseCopy(_ data: Data, for reference: DatabaseReference) throws {
        let url = cacheLocation(for: reference)
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try CoordinatedFileReader.writeData(
            data,
            to: url,
            options: .atomicProtected
        )
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
            String(localized: "The database file is in Recently Deleted in the Files app. Restore it in Files, or remove this database and add the current file again.")
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
    static func locateDatabaseFile(for reference: DatabaseReference) -> LocalDatabaseFileLocation? {
        guard let bookmarkData = reference.bookmarkData,
              let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData) else {
            return reboundDocumentsResidentLocation(for: reference)
        }

        let url = resolved.url
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if SecurityScopedBookmarkManager.isInTrashDirectory(url) {
            if let rebound = reboundDocumentsResidentLocation(for: reference) {
                return rebound
            }
            return .inTrash(url)
        }

        if resolved.isStale,
           let refreshedBookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: url) {
            var refreshedReference = reference
            refreshedReference.bookmarkData = refreshedBookmarkData
            update(refreshedReference)
        }

        return .available(url)
    }

    static func resolveDatabaseURL(for reference: DatabaseReference) -> URL? {
        guard case .available(let url) = locateDatabaseFile(for: reference) else {
            return nil
        }
        return url
    }

    static func resolveKeyFileURL(for reference: DatabaseReference) -> URL? {
        resolveURL(from: reference.keyFileBookmarkData) { refreshedBookmarkData in
            var refreshedReference = reference
            refreshedReference.keyFileBookmarkData = refreshedBookmarkData
            if refreshedReference.keyFileFilename == nil {
                refreshedReference.keyFileFilename = resolveFilename(from: refreshedBookmarkData)
            }
            update(refreshedReference)
        }
    }

    static func refreshBookmarks() {
        let currentDatabases = loadDatabases()
        currentDatabases.forEach { reference in
            _ = resolveDatabaseURL(for: reference)
            _ = resolveKeyFileURL(for: reference)
        }
    }

    static func migrateFromSharedVaultStore() {
        withStateLock {
            bootstrapForUITestingIfNeeded()

            guard !FileManager.default.fileExists(atPath: databaseListURL.path) else {
                sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
                return
            }

            guard let migratedReference = migratedLegacyReference() else {
                sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
                return
            }

            saveDatabases([migratedReference])
            if activeAutoFillDatabaseID == nil {
                activeAutoFillDatabaseID = migratedReference.id
            }
            copyLegacyCachedDatabaseIfNeeded(to: migratedReference.id)
        }
    }

    static func clearAll() {
        withStateLock {
            let currentDatabases = loadDatabases()
            currentDatabases.forEach { remove(id: $0.id) }
            try? FileManager.default.removeItem(at: databaseListURL)
            try? FileManager.default.removeItem(at: backupsRootURL)
            try? PendingUploadQueue.clearAll()
            activeAutoFillDatabaseID = nil
            sharedDefaults.removeObject(forKey: migrationVersionKey)
            remainingUITestLocalSaveConflicts = nil
            consumedUITestLocalSaveConflicts = 0
        }
    }

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

    static func pruneBackups(for reference: DatabaseReference, keeping count: Int) throws {
        guard count >= 0 else { return }

        let backupsToRemove = recentBackups(for: reference).dropFirst(count)
        for url in backupsToRemove {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    private static func loadDatabases() -> [DatabaseReference] {
        withStateLock {
            bootstrapForUITestingIfNeeded()
            migrateFromSharedVaultStoreIfNeeded()
            return decodeStoredDatabases()
        }
    }

    /// Decodes `database-list.json` without triggering UI-test bootstrap or
    /// legacy migration. The `activeAutoFillDatabaseID` setter's gate uses
    /// this because it can run mid-migration, where re-entering
    /// `loadDatabases()` could recurse back into the migration path.
    private static func decodeStoredDatabases() -> [DatabaseReference] {
        withStateLock {
            guard let data = try? Data(contentsOf: databaseListURL) else {
                return []
            }

            guard let decoded = try? JSONDecoder().decode([DatabaseReference].self, from: data) else {
                return []
            }

            return normalized(decoded)
        }
    }

    /// Returns whether the list actually reached disk. Most callers are
    /// best-effort and ignore it; one recording a cloud revision must not
    /// report success for a revision that never persisted.
    @discardableResult
    private static func saveDatabases(_ references: [DatabaseReference]) -> Bool {
        withStateLock {
            let normalizedReferences = normalized(references)
            let encoded: Data

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoded = try encoder.encode(normalizedReferences)
            } catch {
                return false
            }

            do {
                let parentDirectory = databaseListURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parentDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try CoordinatedFileReader.writeData(
                    encoded,
                    to: databaseListURL,
                    options: .atomicProtected
                )
                sharedDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
            } catch {
                return false
            }

            if let activeAutoFillDatabaseID,
               normalizedReferences.contains(where: { $0.id == activeAutoFillDatabaseID && $0.autoFillEnabled }) == false {
                self.activeAutoFillDatabaseID = nil
            }

            return true
        }
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

    private static func migrateFromSharedVaultStoreIfNeeded() {
        guard FileManager.default.fileExists(atPath: databaseListURL.path) == false else { return }
        migrateFromSharedVaultStore()
    }

    private static var applicationSupportURL: URL {
        sharedContainerURL.appendingPathComponent(applicationSupportPathComponent, isDirectory: true)
    }

    private static var backupsRootURL: URL {
        applicationSupportURL.appendingPathComponent(backupsDirectoryName, isDirectory: true)
    }

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
        try? FileManager.default.removeItem(at: SharedVaultStore.databaseCacheDirectory)
        try? FileManager.default.removeItem(at: SharedVaultStore.cloudCacheDirectory)

        if let cloudAccounts = uiTestCloudAccounts(),
           let encodedAccounts = try? JSONEncoder().encode(cloudAccounts) {
            SharedVaultStore.cloudAccountDefaults.set(encodedAccounts, forKey: cloudAccountsStorageKey)
        }

        saveDatabases(references)
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

        if let url = uiTestDatabaseURL() {
            return [url].compactMap { try? makeReference(from: $0) }
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

    private static func uiTestDatabaseURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let base64 = environment[uiTestDBBase64Env], !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        let requestedFilename = environment[uiTestDBFilenameEnv] ?? "ui-test.kdbx"
        return writeUITestDatabase(data: data, requestedFilename: requestedFilename)
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
    static func rebindBookmarkData(_ bookmarkData: Data, for id: UUID, toFileAt url: URL) -> Bool {
        withStateLock {
            var currentDatabases = loadDatabases()
            guard let index = currentDatabases.firstIndex(where: { $0.id == id }) else { return false }
            if let claimant = existingLocalReference(matching: url, in: currentDatabases.filter(\.isDocumentsResident)),
               claimant.id != id {
                return false
            }
            currentDatabases[index].bookmarkData = bookmarkData
            return saveDatabases(currentDatabases)
        }
    }

    /// Persists a re-derived Documents identity after a Files-app rename or
    /// move, mutating ONLY `filename` and `isDocumentsResident` on the stored
    /// copy; concurrent edits to other fields survive. A reference that left
    /// top-level Documents drops the flag and stops participating in
    /// path-keyed rebinding.
    static func rederiveDocumentsIdentity(for id: UUID, filename: String, isDocumentsResident: Bool) {
        withStateLock {
            var currentDatabases = loadDatabases()
            guard let index = currentDatabases.firstIndex(where: { $0.id == id }) else { return }
            currentDatabases[index].filename = filename
            currentDatabases[index].isDocumentsResident = isDocumentsResident
            saveDatabases(currentDatabases)
        }
    }

    /// Whether a Documents-resident reference's file is gone: its own
    /// bookmark does not resolve to an available file AND nothing sits at
    /// `Documents/<filename>`. Pure status check — no lock, no writes, no
    /// heal; a file present at the path is rebindable and therefore NOT
    /// missing (the locate paths perform the heal on unlock/save/scan).
    /// Own-container URLs only, so it never blocks on a file provider.
    static func isDocumentsFileMissing(for reference: DatabaseReference) -> Bool {
        guard reference.isDocumentsResident else { return false }

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
                return false
            }
        }

        let candidate = documentsDirectoryURL.appendingPathComponent(reference.filename, isDirectory: false)
        return FileManager.default.fileExists(atPath: candidate.path) == false
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
        for reference: DatabaseReference
    ) -> LocalDatabaseFileLocation? {
        guard reference.isDocumentsResident else { return nil }

        let candidate = documentsDirectoryURL.appendingPathComponent(reference.filename, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false,
              DocumentPickerService.hasKDBXMagic(at: candidate),
              let bookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: candidate),
              rebindBookmarkData(bookmarkData, for: reference.id, toFileAt: candidate) else {
            return nil
        }

        cacheInitialCopyIfPossible(from: candidate, for: reference.id)
        return .available(candidate)
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
                    lastSyncError: nil
                )
            )
        )
    }

    private static func uiTestJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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

    private static func resolveURL(from bookmarkData: Data?, onRefresh: (Data) -> Void) -> URL? {
        guard let bookmarkData else { return nil }
        guard let resolved = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData) else {
            return nil
        }
        let url = resolved.url

        if resolved.isStale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let refreshedBookmarkData = try? SecurityScopedBookmarkManager.makeBookmarkData(for: url) {
                onRefresh(refreshedBookmarkData)
            }
        }

        return url
    }

    private static func resolveFilename(from bookmarkData: Data) -> String? {
        guard let url = SecurityScopedBookmarkManager.resolveURL(from: bookmarkData)?.url else { return nil }

        return filename(for: url)
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
            let data = try CoordinatedFileReader.readData(from: legacyCachedURL)
            try cacheDatabaseCopy(data, for: databaseID)
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
    }

    private static func normalizedFilePath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func cacheInitialCopyIfPossible(from url: URL, for databaseID: UUID) {
        guard let data = try? readSecurityScopedData(from: url) else { return }
        try? cacheDatabaseCopy(data, for: databaseID)
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
