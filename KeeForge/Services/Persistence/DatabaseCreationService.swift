import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

struct DatabaseCreationRequest: Sendable {
    var displayName: String
    var destination: DatabaseCreationDestination
    var password: String?
    var keyFileData: Data?
    var keyFileBookmarkData: Data?
    var keyFileFilename: String?
}

struct DatabasePreparationRequest: Sendable {
    var displayName: String
    var password: String?
    var keyFileData: Data?
    var keyFileBookmarkData: Data?
    var keyFileFilename: String?
}

enum DatabaseCreationDestination: Sendable, Equatable {
    case files(url: URL, bookmarkData: Data)
    case cloud(provider: String, accountId: String, folderPath: String?)
    case appOnlyAcknowledged
}

struct PreparedDatabase: Sendable {
    let id: UUID
    let filename: String
    let keyFileBookmarkData: Data?
    let keyFileFilename: String?
    let addedAt: Date
    let rootGroup: KPGroup
    let meta: KPMeta
    let formatVersion: KDBXParser.FileVersion
    let sessionKey: SymmetricKey
    let compositeKey: Data
    let openTimeSHA512: Data
    let encryptedBytes: Data
}

struct CreatedDatabase: Sendable {
    let reference: DatabaseReference
    let rootGroup: KPGroup
    let meta: KPMeta
    let formatVersion: KDBXParser.FileVersion
    let sessionKey: SymmetricKey
    let compositeKey: Data
    let openTimeSHA512: Data
}

enum DatabaseCreationDefaults {
    static let argon2idIterations: UInt64 = 10
    static let argon2idMemory: UInt64 = 64 * 1024 * 1024
    static let argon2Version: UInt32 = 0x13
    static let kdfSaltByteCount = 32

    static var argon2idParallelism: UInt32 {
        UInt32(min(ProcessInfo.processInfo.processorCount, 4))
    }

    static func freshHeaderConfiguration() throws -> KDBXWriter.FreshHeaderConfiguration {
        try KDBXWriter.FreshHeaderConfiguration(
            cipherID: KDBXParser.aesCipherUUID,
            kdfParameters: argon2idKDFParameters()
        )
    }

    static func argon2idKDFParameters(salt: Data? = nil) throws -> [String: Any] {
        let resolvedSalt = try salt ?? SecureRandom.data(count: kdfSaltByteCount)
        return [
            "$UUID": KDBXParser.argon2idUUID,
            "I": argon2idIterations,
            "M": argon2idMemory,
            "P": argon2idParallelism,
            "V": argon2Version,
            "S": resolvedSalt,
        ]
    }
}

enum DatabaseCreationService {
    typealias CloudProgressHandler = @Sendable (Double) -> Void

    enum CreationError: Error, LocalizedError, Equatable {
        case invalidName
        case missingKeyComponent
        case destinationUnavailable
        case generatedFileFailedToReopen

        var errorDescription: String? {
            switch self {
            case .invalidName:
                "Enter a valid database name."
            case .missingKeyComponent:
                "Add a master password, key file, or both."
            case .destinationUnavailable:
                "Choose a writable Files destination."
            case .generatedFileFailedToReopen:
                "The new database could not be verified after encryption."
            }
        }
    }

    struct BackgroundTaskHandle: Sendable, Equatable {
        let identifier: UInt

        static let invalid = BackgroundTaskHandle(identifier: UInt.max)
    }

    struct Environment: Sendable {
        var now: @Sendable () -> Date
        var id: @Sendable () -> UUID
        var beginBackgroundTask: @MainActor @Sendable (String) -> BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (BackgroundTaskHandle) -> Void
        var writePrimaryFile: @Sendable (Data, URL, Bool) throws -> Void
        var createCloudFile: @Sendable (String, String, String, Data, @escaping CloudProgressHandler) async throws -> CloudCreatedFile
        var cacheDatabaseCopy: @Sendable (Data, DatabaseReference) throws -> Void
        var addCreatedLocal: @Sendable (DatabaseReference) throws -> Void
        var addCreatedCloud: @Sendable (DatabaseReference) throws -> Void
        var addAppOnlyCreatedLocal: @Sendable (DatabaseReference, Data) throws -> Void
        var validateCreatedCloud: @Sendable (String, String, String, String) throws -> Void

        static let live = Environment(
            now: { .now },
            id: { UUID() },
            beginBackgroundTask: { name in
                DatabaseCreationService.beginBackgroundTask(named: name)
            },
            endBackgroundTask: { handle in
                DatabaseCreationService.endBackgroundTask(handle)
            },
            writePrimaryFile: { data, url, usesSecurityScope in
                try DatabaseCreationService.writePrimaryFile(
                    data,
                    to: url,
                    usesSecurityScope: usesSecurityScope
                )
            },
            createCloudFile: { providerID, accountId, path, data, progress in
                guard let provider = CloudProviderRegistry.provider(for: providerID) else {
                    throw CloudProviderError.notAuthenticated
                }
                return try await provider.createFile(
                    accountId: accountId,
                    path: path,
                    data: data,
                    progress: progress
                )
            },
            cacheDatabaseCopy: { data, reference in
                try DatabaseListStore.cacheDatabaseCopy(data, for: reference)
            },
            addCreatedLocal: { reference in
                try DatabaseListStore.addCreatedLocal(reference)
            },
            addCreatedCloud: { reference in
                try DatabaseListStore.addCreatedCloud(reference)
            },
            addAppOnlyCreatedLocal: { reference, data in
                try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: data)
            },
            validateCreatedCloud: { provider, accountId, fileId, filename in
                try DatabaseListStore.validateCreatedCloud(
                    provider: provider,
                    accountId: accountId,
                    fileId: fileId,
                    filename: filename
                )
            }
        )
    }

    static func create(
        request: DatabaseCreationRequest,
        environment: Environment = .live
    ) async throws -> CreatedDatabase {
        let backgroundTaskHandle = await environment.beginBackgroundTask("DatabaseCreation")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        return try await Task.detached(priority: .utility) {
            let prepared = try prepareOffMain(
                request: DatabasePreparationRequest(
                    displayName: request.displayName,
                    password: request.password,
                    keyFileData: request.keyFileData,
                    keyFileBookmarkData: request.keyFileBookmarkData,
                    keyFileFilename: request.keyFileFilename
                ),
                environment: environment
            )
            return try await createOffMain(
                prepared: prepared,
                destination: request.destination,
                environment: environment
            )
        }.value
    }

    static func prepare(
        request: DatabasePreparationRequest,
        environment: Environment = .live
    ) async throws -> PreparedDatabase {
        try await Task.detached(priority: .utility) {
            try prepareOffMain(request: request, environment: environment)
        }.value
    }

    static func registerExported(
        _ prepared: PreparedDatabase,
        exportedURL: URL,
        environment: Environment = .live
    ) throws -> CreatedDatabase {
        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: exportedURL)
        let reference = makeReference(
            prepared: prepared,
            bookmarkData: bookmarkData
        )
        try DatabaseListStore.validateCreatedLocal(reference)
        try environment.cacheDatabaseCopy(prepared.encryptedBytes, reference)
        try environment.addCreatedLocal(reference)
        return CreatedDatabase(
            reference: reference,
            rootGroup: prepared.rootGroup,
            meta: prepared.meta,
            formatVersion: prepared.formatVersion,
            sessionKey: prepared.sessionKey,
            compositeKey: prepared.compositeKey,
            openTimeSHA512: prepared.openTimeSHA512
        )
    }

    static func normalizedFilename(for displayName: String) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedScalars = trimmed.unicodeScalars.map { scalar in
            CharacterSet(charactersIn: "/:\\?%*|\"<>").contains(scalar) ? "_" : String(scalar)
        }
        var filename = sanitizedScalars.joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard filename.isEmpty == false else {
            throw CreationError.invalidName
        }

        if (filename as NSString).pathExtension.lowercased() != "kdbx" {
            filename += ".kdbx"
        }
        return filename
    }

    private static func prepareOffMain(
        request: DatabasePreparationRequest,
        environment: Environment
    ) throws -> PreparedDatabase {
        let filename = try normalizedFilename(for: request.displayName)
        let hasPassword = request.password?.isEmpty == false
        let hasKeyFile = request.keyFileData?.isEmpty == false
        guard hasPassword || hasKeyFile else {
            throw CreationError.missingKeyComponent
        }

        let now = environment.now()
        let referenceID = environment.id()
        let tree = makeFreshTree(displayName: (filename as NSString).deletingPathExtension, now: now)
        let compositeKey = KDBXCrypto.compositeKey(
            password: request.password,
            keyFileData: request.keyFileData
        )
        let sessionKey = SymmetricKey(size: .bits256)
        let encryptedBytes = try KDBXWriter.write(
            rootGroup: tree.rootGroup,
            meta: tree.meta,
            compositeKey: compositeKey,
            freshHeader: try DatabaseCreationDefaults.freshHeaderConfiguration(),
            sessionKey: sessionKey
        )

        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: encryptedBytes,
            compositeKey: compositeKey,
            sessionKey: sessionKey
        )
        guard parsed.header.formatVersion.majorVersion == KDBXParser.versionKDBX4 else {
            throw CreationError.generatedFileFailedToReopen
        }

        return PreparedDatabase(
            id: referenceID,
            filename: filename,
            keyFileBookmarkData: request.keyFileBookmarkData,
            keyFileFilename: request.keyFileFilename,
            addedAt: now,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            formatVersion: parsed.header.formatVersion,
            sessionKey: sessionKey,
            compositeKey: compositeKey,
            openTimeSHA512: KDBXCrypto.sha512(encryptedBytes),
            encryptedBytes: encryptedBytes
        )
    }

    private static func createOffMain(
        prepared: PreparedDatabase,
        destination: DatabaseCreationDestination,
        environment: Environment
    ) async throws -> CreatedDatabase {
        let reference: DatabaseReference

        switch destination {
        case .files(let url, _):
            reference = makeReference(
                prepared: prepared,
                bookmarkData: destinationBookmarkData(from: destination)
            )
            try DatabaseListStore.validateCreatedLocal(reference)
            try environment.writePrimaryFile(prepared.encryptedBytes, url, true)
            try environment.cacheDatabaseCopy(prepared.encryptedBytes, reference)
            try environment.addCreatedLocal(reference)
        case .cloud(let provider, let accountId, let folderPath):
            let filePath = cloudFilePath(filename: prepared.filename, folderPath: folderPath)
            try environment.validateCreatedCloud(provider, accountId, filePath, prepared.filename)
            let createdFile = try await environment.createCloudFile(
                provider,
                accountId,
                filePath,
                prepared.encryptedBytes,
                { _ in }
            )
            reference = makeCloudReference(
                prepared: prepared,
                provider: provider,
                accountId: accountId,
                file: createdFile.file,
                metadata: createdFile.metadata
            )
            try environment.cacheDatabaseCopy(prepared.encryptedBytes, reference)
            try environment.addCreatedCloud(reference)
        case .appOnlyAcknowledged:
            reference = makeReference(prepared: prepared, bookmarkData: nil)
            try DatabaseListStore.validateAppOnlyCreatedLocal(reference)
            try environment.addAppOnlyCreatedLocal(reference, prepared.encryptedBytes)
        }

        return CreatedDatabase(
            reference: reference,
            rootGroup: prepared.rootGroup,
            meta: prepared.meta,
            formatVersion: prepared.formatVersion,
            sessionKey: prepared.sessionKey,
            compositeKey: prepared.compositeKey,
            openTimeSHA512: prepared.openTimeSHA512
        )
    }

    private static func makeFreshTree(displayName: String, now: Date) -> (rootGroup: KPGroup, meta: KPMeta) {
        let recycleBinID = UUID()
        let visibleRoot = KPGroup(
            name: displayName,
            iconID: 48,
            groups: [
                KPGroup(
                    id: recycleBinID,
                    name: "Recycle Bin",
                    iconID: 43,
                    isExpanded: false,
                    creationTime: now,
                    lastModificationTime: now
                )
            ],
            creationTime: now,
            lastModificationTime: now
        )
        let root = KPGroup(name: "Root", groups: [visibleRoot], recycleBinUUID: recycleBinID)
        let meta = KPMeta(
            recycleBinUUID: recycleBinID,
            hasRecycleBinUUIDElement: true,
            maintenanceHistoryDays: KPMeta.defaultMaintenanceHistoryDays,
            historyMaxItems: KPMeta.defaultHistoryMaxItems,
            historyMaxSize: KPMeta.defaultHistoryMaxSize
        )
        return (root, meta)
    }

    private static func destinationBookmarkData(from destination: DatabaseCreationDestination) -> Data? {
        switch destination {
        case .files(_, let bookmarkData):
            bookmarkData
        case .cloud:
            nil
        case .appOnlyAcknowledged:
            nil
        }
    }

    private static func makeReference(
        prepared: PreparedDatabase,
        bookmarkData: Data?
    ) -> DatabaseReference {
        DatabaseReference(
            id: prepared.id,
            nickname: nil,
            filename: prepared.filename,
            bookmarkData: bookmarkData,
            keyFileBookmarkData: prepared.keyFileBookmarkData,
            keyFileFilename: prepared.keyFileFilename,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: prepared.addedAt,
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: false,
            editsAcknowledgedAt: nil,
            source: .local
        )
    }

    private static func makeCloudReference(
        prepared: PreparedDatabase,
        provider: String,
        accountId: String,
        file: CloudFile,
        metadata: CloudFileMetadata
    ) -> DatabaseReference {
        DatabaseReference(
            id: prepared.id,
            nickname: nil,
            filename: prepared.filename,
            bookmarkData: nil,
            keyFileBookmarkData: prepared.keyFileBookmarkData,
            keyFileFilename: prepared.keyFileFilename,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: prepared.addedAt,
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: false,
            editsAcknowledgedAt: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: provider,
                    accountId: accountId,
                    fileId: file.id,
                    displayPath: file.path,
                    remoteContentHash: metadata.contentHash,
                    remoteModifiedAt: metadata.modifiedDate,
                    remoteRev: metadata.rev,
                    lastSyncedAt: prepared.addedAt,
                    lastSyncError: nil
                )
            )
        )
    }

    static func cloudFilePath(filename: String, folderPath: String?) -> String {
        let trimmedFolder = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedFolder = trimmedFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedFolder.isEmpty else {
            return "/\(filename)"
        }
        return "/\(normalizedFolder)/\(filename)"
    }

    private static func writePrimaryFile(
        _ data: Data,
        to url: URL,
        usesSecurityScope: Bool
    ) throws {
        let accessed = usesSecurityScope ? url.startAccessingSecurityScopedResource() : false
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try CoordinatedFileReader.writeData(
            data,
            to: url,
            options: [.atomic, .completeFileProtection]
        )
    }

    @MainActor
    private static func beginBackgroundTask(named name: String) -> BackgroundTaskHandle {
        guard let application = sharedApplication() else {
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
    private static func endBackgroundTask(_ handle: BackgroundTaskHandle) {
        guard handle != .invalid,
              let application = sharedApplication() else {
            return
        }

        let selector = NSSelectorFromString("endBackgroundTask:")
        guard application.responds(to: selector) else { return }

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
        guard applicationClass.responds(to: selector) else { return nil }

        typealias SharedApplicationMethod = @convention(c) (AnyClass, Selector) -> NSObject?
        let method = unsafeBitCast(applicationClass.method(for: selector), to: SharedApplicationMethod.self)
        return method(applicationClass, selector)
    }
}
