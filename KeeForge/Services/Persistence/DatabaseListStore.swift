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

    private nonisolated(unsafe) static var didBootstrapUITesting = false
    private nonisolated(unsafe) static var remainingUITestLocalSaveConflicts: Int?
    private nonisolated(unsafe) static var consumedUITestLocalSaveConflicts = 0

    private struct UITestDatabasePayload: Decodable {
        let filename: String
        let base64: String
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
            if let newValue {
                sharedDefaults.set(newValue.uuidString, forKey: activeAutoFillDatabaseIDKey)
            } else {
                sharedDefaults.removeObject(forKey: activeAutoFillDatabaseIDKey)
            }
        }
    }

    static var activeAutoFillDatabase: DatabaseReference? {
        let currentDatabases = loadDatabases()

        if let activeAutoFillDatabaseID,
           let reference = currentDatabases.first(where: { $0.id == activeAutoFillDatabaseID }) {
            return reference
        }

        return fallbackAutoFillDatabase(in: currentDatabases)
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
        cacheInitialCopyIfPossible(from: url, for: reference.id)
        return reference
    }

    @discardableResult
    static func addCloud(
        provider: String,
        accountId: String,
        file: CloudFile
    ) -> DatabaseReference {
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

    static func addCreatedLocal(_ reference: DatabaseReference) throws {
        var currentDatabases = loadDatabases()
        try validateCreatedLocal(reference, in: currentDatabases)
        currentDatabases.append(reference)
        saveDatabases(currentDatabases)
    }

    static func addCreatedCloud(_ reference: DatabaseReference) throws {
        var currentDatabases = loadDatabases()
        try validateCreatedCloud(reference, in: currentDatabases)
        currentDatabases.append(reference)
        saveDatabases(currentDatabases)
    }

    static func addAppOnlyCreatedLocal(_ reference: DatabaseReference, encryptedBytes: Data) throws {
        var currentDatabases = loadDatabases()
        try validateAppOnlyCreatedLocal(reference, in: currentDatabases)
        try cacheDatabaseCopy(encryptedBytes, for: reference)
        currentDatabases.append(reference)
        saveDatabases(currentDatabases)
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
        let currentDatabases = loadDatabases()
        guard let removedReference = currentDatabases.first(where: { $0.id == id }) else { return }
        let shouldClearCredentialStore = activeAutoFillDatabase?.id == id

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

        if shouldClearCredentialStore {
            CredentialIdentityStoreManager.clearStore()
        }
    }

    static func update(_ reference: DatabaseReference) {
        var currentDatabases = loadDatabases()

        if let index = currentDatabases.firstIndex(where: { $0.id == reference.id }) {
            currentDatabases[index] = reference
        } else {
            currentDatabases.append(reference)
        }

        saveDatabases(currentDatabases)
    }

    static func setReadOnly(_ isReadOnly: Bool, for reference: DatabaseReference) {
        guard var updatedReference = loadDatabases().first(where: { $0.id == reference.id }) else { return }
        updatedReference.isReadOnly = isReadOnly
        update(updatedReference)
    }

    static func acknowledgeEdits(for reference: DatabaseReference, at date: Date = .now) {
        guard var updatedReference = loadDatabases().first(where: { $0.id == reference.id }) else { return }
        updatedReference.editsAcknowledgedAt = date
        update(updatedReference)
    }

    static func move(from source: IndexSet, to destination: Int) {
        var currentDatabases = loadDatabases()
        let movingItems = source.map { currentDatabases[$0] }
        for index in source.sorted(by: >) {
            currentDatabases.remove(at: index)
        }

        let insertionIndex = min(destination, currentDatabases.count)
        currentDatabases.insert(contentsOf: movingItems, at: insertionIndex)
        saveDatabases(currentDatabases)
    }

    static func markDatabaseOpened(id: UUID, at date: Date = .now) {
        guard var reference = loadDatabases().first(where: { $0.id == id }) else { return }
        reference.lastOpenedAt = date
        update(reference)
        activeAutoFillDatabaseID = id
    }

    static func clearLegacyKeychainFilename(for id: UUID) {
        guard var reference = loadDatabases().first(where: { $0.id == id }) else { return }
        guard reference.legacyKeychainFilename != nil else { return }
        reference.legacyKeychainFilename = nil
        update(reference)
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

    static func resolveDatabaseURL(for reference: DatabaseReference) -> URL? {
        resolveURL(from: reference.bookmarkData) { refreshedBookmarkData in
            var refreshedReference = reference
            refreshedReference.bookmarkData = refreshedBookmarkData
            update(refreshedReference)
        }
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

    static func clearAll() {
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

    static func pruneBackups(for reference: DatabaseReference, keeping count: Int) throws {
        guard count >= 0 else { return }

        let backupsToRemove = recentBackups(for: reference).dropFirst(count)
        for url in backupsToRemove {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    private static func loadDatabases() -> [DatabaseReference] {
        bootstrapForUITestingIfNeeded()
        migrateFromSharedVaultStoreIfNeeded()

        guard let data = try? Data(contentsOf: databaseListURL) else {
            return []
        }

        guard let decoded = try? JSONDecoder().decode([DatabaseReference].self, from: data) else {
            return []
        }

        return normalized(decoded)
    }

    private static func saveDatabases(_ references: [DatabaseReference]) {
        let normalizedReferences = normalized(references)
        let encoded: Data

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoded = try encoder.encode(normalizedReferences)
        } catch {
            return
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
            return
        }

        if let activeAutoFillDatabaseID,
           normalizedReferences.contains(where: { $0.id == activeAutoFillDatabaseID }) == false {
            self.activeAutoFillDatabaseID = nil
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

        var references =
            uiTestDatabaseURLs().compactMap { try? makeReference(from: $0) }
            + uiTestCloudDatabases()
        if uiTestEnvironmentFlag(uiTestDatabaseReadOnlyEnv) {
            references = references.map { reference in
                var updatedReference = reference
                updatedReference.isReadOnly = true
                return updatedReference
            }
        }
        if references.count == 1, uiTestEnvironmentFlag(uiTestEnableQuickLaunchEnv) {
            references = references.map { reference in
                var updatedReference = reference
                updatedReference.isQuickLaunch = true
                return updatedReference
            }
        }
        sharedDefaults.removeObject(forKey: cloudAccountsStorageKey)
        try? PendingUploadQueue.clearAll()
        try? FileManager.default.removeItem(at: SharedVaultStore.databaseCacheDirectory)
        try? FileManager.default.removeItem(at: SharedVaultStore.cloudCacheDirectory)

        if let cloudAccounts = uiTestCloudAccounts(),
           let encodedAccounts = try? JSONEncoder().encode(cloudAccounts) {
            sharedDefaults.set(encodedAccounts, forKey: cloudAccountsStorageKey)
        }

        saveDatabases(references)
        activeAutoFillDatabaseID = nil
    }

    private static func uiTestDatabaseURLs() -> [URL] {
        let environment = ProcessInfo.processInfo.environment

        if let rawJSON = environment[uiTestDatabasesJSONEnv],
           let data = rawJSON.data(using: .utf8),
           let payloads = try? JSONDecoder().decode([UITestDatabasePayload].self, from: data) {
            let urls = payloads.compactMap(uiTestDatabaseURL(from:))
            if !urls.isEmpty {
                return urls
            }
        }

        if let url = uiTestDatabaseURL() {
            return [url]
        }

        return []
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

    private static func uiTestDatabaseURL(from payload: UITestDatabasePayload) -> URL? {
        guard let data = Data(base64Encoded: payload.base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        return writeUITestDatabase(data: data, requestedFilename: payload.filename)
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
            legacyKeychainFilename: nil
        )
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

    private static func fallbackAutoFillDatabase(in references: [DatabaseReference]) -> DatabaseReference? {
        references.first { $0.legacyKeychainFilename != nil }
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

    private static func cacheInitialCopyIfPossible(from url: URL, for databaseID: UUID) {
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
