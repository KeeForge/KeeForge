import CryptoKit
import Foundation

enum SaveResult: Sendable, Equatable {
    case saved(newSHA512: Data)
    case conflict(remoteSHA512: Data, remoteData: Data)
}

struct SaveConflict: Sendable, Equatable {
    let remoteSHA512: Data
    let remoteData: Data
}

/// The stored states a save is allowed to overwrite.
///
/// `openTimeSHA512` is what the session read when it opened the file — the
/// ordinary optimistic-concurrency baseline. `reconciledRemoteSHA512` is set
/// only by the merge flow, which has already read the diverged file and folded
/// it into the draft: those bytes are then just as safe to replace as the
/// open-time ones, and nothing else is. Anything else under the save is
/// content nobody has reconciled, and still conflicts.
struct SaveBaseline: Sendable, Equatable {
    let openTimeSHA512: Data
    let reconciledRemoteSHA512: Data?

    init(openTimeSHA512: Data, reconciledRemoteSHA512: Data? = nil) {
        self.openTimeSHA512 = openTimeSHA512
        self.reconciledRemoteSHA512 = reconciledRemoteSHA512
    }

    func covers(_ sha512: Data) -> Bool {
        sha512 == openTimeSHA512 || sha512 == reconciledRemoteSHA512
    }
}

enum SaveError: Error, LocalizedError, Equatable {
    case databaseIsReadOnly
    case databaseLocationUnavailable
    case saveContextUnavailable
    case rekeyVerificationFailed
    case rekeyAppliedRemotely

    var errorDescription: String? {
        switch self {
        case .databaseIsReadOnly:
            String(localized: "This database is read-only.")
        case .databaseLocationUnavailable:
            String(localized: "The database file could not be located.")
        case .saveContextUnavailable:
            String(localized: "The database is not ready to save.")
        case .rekeyVerificationFailed:
            String(localized: "The new database could not be verified after encryption.")
        case .rekeyAppliedRemotely:
            String(localized: "The new master key was uploaded, but the local copy could not be updated. The cloud file now requires the new master key.")
        }
    }
}

enum LocalDatabaseSaver {
    struct BackgroundTaskHandle: Sendable, Equatable {
        let identifier: UInt

        static let invalid = BackgroundTaskHandle(identifier: UInt.max)
    }

    struct ResolvedLocation: Sendable {
        let url: URL
        let usesSecurityScope: Bool
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (BackgroundTaskHandle) -> Void
        var resolveLocation: @Sendable (DatabaseReference) -> ResolvedLocation?
        var readData: @Sendable (URL) throws -> Data
        var extractHeader: @Sendable (Data, Data, KDFExecutionPolicy) throws -> KDBXParser.Header
        var encryptDraft: @Sendable (DatabaseDraft, Data, KDBXParser.Header, KDFExecutionPolicy) throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var replaceFileAtomically: @Sendable (Data, URL) throws -> Void
        var cacheDatabaseCopy: @Sendable (Data, DatabaseReference) throws -> Void

        static let live = Environment(
            beginBackgroundTask: { name in
                AppBackgroundTaskManager.begin(named: name)
            },
            endBackgroundTask: { handle in
                AppBackgroundTaskManager.end(handle)
            },
            resolveLocation: { reference in
                LocalDatabaseSaver.resolveLocation(for: reference)
            },
            readData: { url in
                try CoordinatedFileReader.readData(from: url)
            },
            extractHeader: { data, compositeKey, kdfPolicy in
                try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: SymmetricKey(size: .bits256),
                    kdfPolicy: kdfPolicy
                ).header
            },
            encryptDraft: { draft, compositeKey, header, kdfPolicy in
                try KDBXWriter.write(
                    rootGroup: draft.rootGroup,
                    meta: draft.meta,
                    compositeKey: compositeKey,
                    header: header,
                    sessionKey: draft.writerSessionKey,
                    kdfPolicy: kdfPolicy
                )
            },
            backupDirectoryURL: { reference in
                DatabaseListStore.databaseBackupDirectoryURL(for: reference)
            },
            createDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            },
            writeBackup: { data, url in
                try CoordinatedFileReader.writeData(
                    data,
                    to: url,
                    options: .atomicProtected
                )
            },
            pruneBackups: { reference, count in
                try DatabaseListStore.pruneBackups(for: reference, keeping: count)
            },
            now: { .now },
            replaceFileAtomically: { data, url in
                try LocalDatabaseSaver.replaceFileAtomically(data, at: url)
            },
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            }
        )
    }

    /// Saves an edited database draft back to encrypted storage.
    ///
    /// `newCompositeKey` rekeys the database: `compositeKey` still decrypts the
    /// on-disk file, `newCompositeKey` encrypts the saved bytes, and the result
    /// is verified to reopen with the new key before the file is replaced.
    ///
    /// `reconciledRemoteSHA512` widens the overwrite gate by exactly one state
    /// — see `SaveBaseline`.
    ///
    /// - Important: The caller must keep `draft.writerSessionKey` alive until this async call
    ///   returns. `KDBXWriter` needs that session key to re-encrypt protected values while saving.
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: Data? = nil
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: kdfPolicy,
            newCompositeKey: newCompositeKey,
            environment: .live
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
        reconciledRemoteSHA512: Data? = nil,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: Data? = nil,
        environment: Environment
    ) async throws -> SaveResult {
        if reference.isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        let backgroundTaskHandle = await environment.beginBackgroundTask("DatabaseSaving")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        return try await Task.detached(priority: .utility) {
            try saveOffMain(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                baseline: SaveBaseline(
                    openTimeSHA512: openTimeSHA512,
                    reconciledRemoteSHA512: reconciledRemoteSHA512
                ),
                kdfPolicy: kdfPolicy,
                newCompositeKey: newCompositeKey,
                environment: environment
            )
        }.value
    }

    private static func saveOffMain(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        baseline: SaveBaseline,
        kdfPolicy: KDFExecutionPolicy,
        newCompositeKey: Data?,
        environment: Environment
    ) throws -> SaveResult {
        guard let location = environment.resolveLocation(reference) else {
            throw SaveError.databaseLocationUnavailable
        }

        let hasSecurityScope = location.usesSecurityScope
            ? location.url.startAccessingSecurityScopedResource()
            : false
        defer {
            if hasSecurityScope {
                location.url.stopAccessingSecurityScopedResource()
            }
        }

        var currentData = try environment.readData(location.url)
        if let conflictSequence = DatabaseListStore.consumeUITestLocalSaveConflictSequence() {
            currentData = try makeUITestConflictData(
                from: currentData,
                compositeKey: compositeKey,
                sequence: conflictSequence,
                kdfPolicy: kdfPolicy
            )
            try environment.replaceFileAtomically(currentData, location.url)
        }
        let currentSHA512 = KDBXCrypto.sha512(currentData)
        guard baseline.covers(currentSHA512) else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        let header = try environment.extractHeader(currentData, compositeKey, kdfPolicy)
        guard header.formatVersion.requiresReadOnlyMode == false else {
            throw SaveError.databaseIsReadOnly
        }
        let newData = try environment.encryptDraft(draft, newCompositeKey ?? compositeKey, header, kdfPolicy)
        if let newCompositeKey {
            do {
                _ = try environment.extractHeader(newData, newCompositeKey, kdfPolicy)
            } catch {
                throw SaveError.rekeyVerificationFailed
            }
        }

        let backupDirectoryURL = environment.backupDirectoryURL(reference)
        try environment.createDirectory(backupDirectoryURL)

        let backupURL = backupDirectoryURL.appendingPathComponent(
            backupFilename(for: environment.now()),
            isDirectory: false
        )
        try environment.writeBackup(currentData, backupURL)
        try environment.replaceFileAtomically(newData, location.url)
        // When the save location already IS the cache file (a cloud reference
        // without a bookmark resolves straight to it), the replace above was
        // the cache write; repeating it widens the window where a concurrent
        // cache read can mismatch its pending-upload marker.
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        if canonicalPath(of: location.url) != canonicalPath(of: cacheURL) {
            try? environment.cacheDatabaseCopy(newData, reference)
        }
        try? environment.pruneBackups(reference, 5)

        return .saved(newSHA512: KDBXCrypto.sha512(newData))
    }

    private static func resolveLocation(for reference: DatabaseReference) -> ResolvedLocation? {
        if let url = DatabaseListStore.resolveDatabaseURL(for: reference) {
            return ResolvedLocation(url: url, usesSecurityScope: true)
        }

        guard reference.bookmarkData == nil else {
            return nil
        }

        let cachedURL = DatabaseListStore.cachedDatabaseURL(for: reference) ?? DatabaseListStore.cacheLocation(for: reference)
        return ResolvedLocation(url: cachedURL, usesSecurityScope: false)
    }

    private static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func backupFilename(for date: Date) -> String {
        let utcCalendar = Calendar(identifier: .gregorian)
        let utcTimeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = utcCalendar.dateComponents(in: utcTimeZone, from: date)
        let microseconds = (components.nanosecond ?? 0) / 1_000

        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%06d.kdbx",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            microseconds
        )
    }

    private static func makeUITestConflictData(
        from data: Data,
        compositeKey: Data,
        sequence: Int,
        kdfPolicy: KDFExecutionPolicy
    ) throws -> Data {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: kdfPolicy
        )
        let conflictMarkerParent = parsed.rootGroup.entries.isEmpty && parsed.rootGroup.groups.count == 1
            ? parsed.rootGroup.groups[0]
            : parsed.rootGroup
        conflictMarkerParent.entries.append(
            KPEntry(
                title: "UI Test Conflict \(sequence)",
                notes: "Injected save conflict \(sequence)"
            )
        )
        var header = parsed.header
        if DatabaseListStore.uiTestLocalSaveConflictDivergesPool {
            // Leading byte is the pool entry's flags field; the rest is filler.
            header.innerHeaderBinaryFields.append(
                Data([0x00]) + Data("keeforge-ui-test-divergent-binary-\(sequence)".utf8)
            )
        }
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: kdfPolicy
        )
    }

    private static func replaceFileAtomically(_ data: Data, at url: URL) throws {
        let fileManager = FileManager.default

        var coordinatorError: NSError?
        var result: Result<Void, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                let replacementDirectoryURL = try fileManager.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: coordinatedURL,
                    create: true
                )
                let tempURL = replacementDirectoryURL.appendingPathComponent(
                    "keeforge-save-\(UUID().uuidString)",
                    isDirectory: false
                )
                defer {
                    try? fileManager.removeItem(at: replacementDirectoryURL)
                }

                do {
                    // Keep the staged replacement outside the picked folder because
                    // file-scoped security access may not allow creating sibling temp files.
                    try data.write(to: tempURL, options: .atomicProtected)
                    _ = try fileManager.replaceItemAt(
                        coordinatedURL,
                        withItemAt: tempURL,
                        backupItemName: nil,
                        options: []
                    )
                } catch {
                    try? fileManager.removeItem(at: tempURL)
                    throw error
                }
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }

        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }

        try result.get()
    }
}

private enum AppBackgroundTaskManager {
    @MainActor
    static func begin(named name: String) -> LocalDatabaseSaver.BackgroundTaskHandle {
        guard Bundle.main.bundleURL.pathExtension != "appex",
              let application = sharedApplication() else {
            return .invalid
        }

        let selector = NSSelectorFromString("beginBackgroundTaskWithName:expirationHandler:")
        guard application.responds(to: selector) else {
            return .invalid
        }

        typealias BeginMethod = @convention(c) (AnyObject, Selector, NSString, AnyObject?) -> UInt
        let method = unsafeBitCast(application.method(for: selector), to: BeginMethod.self)
        let expirationHandler: @convention(block) () -> Void = {}
        let identifier = method(application, selector, name as NSString, expirationHandler as AnyObject)
        return .init(identifier: identifier)
    }

    @MainActor
    static func end(_ handle: LocalDatabaseSaver.BackgroundTaskHandle) {
        guard handle != .invalid,
              let application = sharedApplication() else {
            return
        }

        let selector = NSSelectorFromString("endBackgroundTask:")
        guard application.responds(to: selector) else {
            return
        }

        typealias EndMethod = @convention(c) (AnyObject, Selector, UInt) -> Void
        let method = unsafeBitCast(application.method(for: selector), to: EndMethod.self)
        method(application, selector, handle.identifier)
    }

    @MainActor
    private static func sharedApplication() -> NSObject? {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type else {
            return nil
        }

        let selector = NSSelectorFromString("sharedApplication")
        guard applicationClass.responds(to: selector),
              let application = applicationClass.perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }

        return application
    }
}
