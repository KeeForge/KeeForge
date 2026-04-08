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

enum SaveError: Error, LocalizedError, Equatable {
    case databaseIsReadOnly
    case databaseLocationUnavailable
    case saveContextUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseIsReadOnly:
            "This database is read-only."
        case .databaseLocationUnavailable:
            "The database file could not be located."
        case .saveContextUnavailable:
            "The database is not ready to save."
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
        var extractHeader: @Sendable (Data, Data) throws -> KDBXParser.Header
        var encryptDraft: @Sendable (DatabaseDraft, Data, KDBXParser.Header) throws -> Data
        var backupDirectoryURL: @Sendable (DatabaseReference) -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var writeBackup: @Sendable (Data, URL) throws -> Void
        var pruneBackups: @Sendable (DatabaseReference, Int) throws -> Void
        var now: @Sendable () -> Date
        var replaceFileAtomically: @Sendable (Data, URL) throws -> Void

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
            extractHeader: { data, compositeKey in
                try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: SymmetricKey(size: .bits256)
                ).header
            },
            encryptDraft: { draft, compositeKey, header in
                try KDBXWriter.write(
                    rootGroup: draft.rootGroup,
                    meta: draft.meta,
                    compositeKey: compositeKey,
                    header: header,
                    sessionKey: draft.writerSessionKey
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
                    options: [.atomic, .completeFileProtection]
                )
            },
            pruneBackups: { reference, count in
                try DatabaseListStore.pruneBackups(for: reference, keeping: count)
            },
            now: { .now },
            replaceFileAtomically: { data, url in
                try LocalDatabaseSaver.replaceFileAtomically(data, at: url)
            }
        )
    }

    /// Saves an edited database draft back to encrypted storage.
    ///
    /// - Important: The caller must keep `draft.writerSessionKey` alive until this async call
    ///   returns. `KDBXWriter` needs that session key to re-encrypt protected values while saving.
    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data
    ) async throws -> SaveResult {
        try await save(
            draft: draft,
            reference: reference,
            compositeKey: compositeKey,
            openTimeSHA512: openTimeSHA512,
            environment: .live
        )
    }

    static func save(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
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
                openTimeSHA512: openTimeSHA512,
                environment: environment
            )
        }.value
    }

    private static func saveOffMain(
        draft: DatabaseDraft,
        reference: DatabaseReference,
        compositeKey: Data,
        openTimeSHA512: Data,
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
                sequence: conflictSequence
            )
            try environment.replaceFileAtomically(currentData, location.url)
        }
        let currentSHA512 = KDBXCrypto.sha512(currentData)
        guard currentSHA512 == openTimeSHA512 else {
            return .conflict(remoteSHA512: currentSHA512, remoteData: currentData)
        }

        let header = try environment.extractHeader(currentData, compositeKey)
        let newData = try environment.encryptDraft(draft, compositeKey, header)

        let backupDirectoryURL = environment.backupDirectoryURL(reference)
        try environment.createDirectory(backupDirectoryURL)

        let backupURL = backupDirectoryURL.appendingPathComponent(
            backupFilename(for: environment.now()),
            isDirectory: false
        )
        try environment.writeBackup(currentData, backupURL)
        try environment.replaceFileAtomically(newData, location.url)
        // Keep the shared AutoFill cache aligned with the just-written encrypted bytes.
        try? DatabaseListStore.cacheDatabaseCopy(newData, for: reference)
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
        sequence: Int
    ) throws -> Data {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )
        parsed.rootGroup.entries.append(
            KPEntry(
                title: "UI Test Conflict \(sequence)",
                notes: "Injected save conflict \(sequence)"
            )
        )
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: parsed.header,
            sessionKey: sessionKey
        )
    }

    private static func replaceFileAtomically(_ data: Data, at url: URL) throws {
        let fileManager = FileManager.default
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(
            ".keeforge-save-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var coordinatorError: NSError?
        var result: Result<Void, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                do {
                    try data.write(to: tempURL, options: [.completeFileProtection])
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
