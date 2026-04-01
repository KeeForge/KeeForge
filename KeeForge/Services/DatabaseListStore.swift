import CryptoKit
import Foundation

enum DatabaseListStore {
    private static let databaseListFilename = "database-list.json"
    private static let activeAutoFillDatabaseIDKey = "activeAutoFillDatabaseID"
    private static let migrationVersionKey = "databaseListMigrationVersion"
    private static let currentMigrationVersion = 1
    private static let uiTestingLaunchArg = "-ui-testing"
    private static let uiTestDBBase64Env = "UI_TEST_DB_BASE64"
    private static let uiTestDBFilenameEnv = "UI_TEST_DB_FILENAME"

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

    @discardableResult
    static func add(url: URL) throws -> DatabaseReference {
        var currentDatabases = loadDatabases()
        let reference = try makeReference(from: url)
        currentDatabases.append(reference)
        saveDatabases(currentDatabases)
        return reference
    }

    static func remove(id: UUID) {
        let currentDatabases = loadDatabases()
        guard let removedReference = currentDatabases.first(where: { $0.id == id }) else { return }

        KeychainService.deleteCompositeKey(for: removedReference.id)
        if let legacyFilename = removedReference.legacyKeychainFilename {
            KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
        }

        try? FileManager.default.removeItem(at: cacheURL(for: removedReference.id))

        let remainingDatabases = currentDatabases.filter { $0.id != id }
        if activeAutoFillDatabaseID == id {
            activeAutoFillDatabaseID = nil
        }
        saveDatabases(remainingDatabases)
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
            options: [.atomic, .completeFileProtection]
        )
    }

    static func cachedDatabaseURL(for databaseID: UUID) -> URL? {
        let url = cacheURL(for: databaseID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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
        activeAutoFillDatabaseID = nil
        sharedDefaults.removeObject(forKey: migrationVersionKey)
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
                options: [.atomic, .completeFileProtection]
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

    private static func bootstrapForUITestingIfNeeded() {
        guard didBootstrapUITesting == false else { return }
        guard ProcessInfo.processInfo.arguments.contains(uiTestingLaunchArg) else { return }
        didBootstrapUITesting = true

        guard let url = uiTestDatabaseURL(),
              let reference = try? makeReference(from: url) else {
            return
        }

        saveDatabases([reference])
        activeAutoFillDatabaseID = nil
    }

    private static func uiTestDatabaseURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let base64 = environment[uiTestDBBase64Env], !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }

        let requestedFilename = environment[uiTestDBFilenameEnv] ?? "ui-test.kdbx"
        let safeFilename = (requestedFilename as NSString).lastPathComponent
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeFilename, isDirectory: false)

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func makeReference(from url: URL) throws -> DatabaseReference {
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

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

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let refreshedBookmarkData = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                onRefresh(refreshedBookmarkData)
            }
        }

        return url
    }

    private static func resolveFilename(from bookmarkData: Data) -> String? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        return filename(for: url)
    }

    private static func cacheURL(for databaseID: UUID) -> URL {
        SharedVaultStore.databaseCacheDirectory.appendingPathComponent("\(databaseID.uuidString).kdbx", isDirectory: false)
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

    private static func filename(for url: URL) -> String {
        let filename = (url.lastPathComponent as NSString).lastPathComponent
        return filename.isEmpty ? "database.kdbx" : filename
    }
}
