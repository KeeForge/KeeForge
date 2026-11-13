import Darwin
import Foundation

/// Immutable encrypted AutoFill snapshots, exact receipts and permanent removal fencing.
enum PendingLocalSaveStore {
    struct PendingSave: Sendable, Equatable {
        let databaseID: UUID
        let fileURL: URL
    }

    struct Receipt: Codable, Sendable, Equatable, Identifiable {
        let relativePath: String
        let fileNumber: UInt64
        let digest: Data
        var id: String {
            relativePath + "-" + String(fileNumber) + "-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct OwnerState: Codable {
        let version: Int
        var removed: Bool
        var retirementID: UUID?
        var retiringSources: [Receipt]?
    }

    struct RecoverySnapshot: Sendable, Equatable {
        let databaseID: UUID
        let receipts: [Receipt]
        let isRevoked: Bool
        let retirementID: UUID?
        let ownerDigest: Data?
        let ownerUnavailable: Bool
        let unavailableReceiptIDs: Set<String>
        var needsRecovery: Bool { isRevoked || retirementID != nil || ownerUnavailable }
    }

    enum OwnershipError: Error, LocalizedError {
        case recoveryRequired, sourceChanged, removed
        var errorDescription: String? {
            String(localized: "AutoFill changes need recovery. Open Database Details to export their original encrypted snapshots or deliberately discard them before trying again.")
        }
    }

    @TaskLocal private static var ownerContainer: URL?
    @TaskLocal static var mergingReceipts: [Receipt]?
    static let didChange = Notification.Name("KeeForge.pendingLocalSavesChanged")

    @discardableResult
    static func add(_ encryptedBytes: Data, for databaseID: UUID, now: Date = .now, sourceID: UUID = UUID()) throws -> PendingSave {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            let payloadRoot = directoryURL(for: databaseID)
            try createDurableDirectory(at: payloadRoot, anchor: ownerContainer ?? payloadRoot)
            let directory = payloadRoot.appendingPathComponent(sourceID.uuidString, isDirectory: true)
            guard Darwin.mkdir(directory.path, S_IRWXU) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try synchronizeDirectory(directory)
            try synchronizeDirectory(payloadRoot)
            let names = Set(try sourceURLs(databaseID).map(\.lastPathComponent))
            var date = now
            var name = LocalDatabaseSaver.backupFilename(for: date)
            while names.contains(name) {
                date.addTimeInterval(0.000_001)
                name = LocalDatabaseSaver.backupFilename(for: date)
            }
            let url = directory.appendingPathComponent(name)
            try writeAtomicallyAndDurably(encryptedBytes, to: url)
            changed()
            return PendingSave(databaseID: databaseID, fileURL: url)
        }
    }

    /// Legacy timestamp.kdbx files remain readable; new snapshots have a unique parent.
    static func saves(for databaseID: UUID) -> [PendingSave] {
        (try? withLock(for: databaseID) { try sourceURLs(databaseID).map { PendingSave(databaseID: databaseID, fileURL: $0) } }) ?? []
    }

    static func hasSaves(for databaseID: UUID) -> Bool {
        do {
            return try withLock(for: databaseID) {
                let state = try loadState(databaseID)
                return try state?.retirementID != nil || !sourceURLs(databaseID).isEmpty
            }
        } catch { return true }
    }

    /// Read bytes and identity together; the merge later admits exactly this receipt.
    static func read(_ source: PendingSave) throws -> (data: Data, receipt: Receipt) {
        try withLock(for: source.databaseID) {
            let receipt = try receipt(at: source.fileURL, databaseID: source.databaseID)
            let data = try Data(contentsOf: sourceURL(receipt.relativePath, databaseID: source.databaseID))
            guard FileDigest.sha512(data) == receipt.digest else { throw OwnershipError.sourceChanged }
            return (data, receipt)
        }
    }

    /// Coordinated access precedes flock, which remains held through the synchronous replace.
    static func withWriteAuthorization<T>(for databaseID: UUID, receipts: [Receipt]? = nil, _ replace: () throws -> T) throws -> T {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            guard try loadState(databaseID)?.retirementID == nil else { throw OwnershipError.recoveryRequired }
            for receipt in receipts ?? [] { try validate(receipt, databaseID: databaseID) }
            return try replace()
        }
    }

    static func consume(_ receipts: [Receipt], for databaseID: UUID) throws {
        try withLock(for: databaseID) {
            try requireNotRemoved(databaseID)
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            guard state.retirementID == nil else { throw OwnershipError.recoveryRequired }
            for receipt in receipts { try validate(receipt, databaseID: databaseID) }
            state.retirementID = UUID()
            state.retiringSources = receipts
            try persist(state, databaseID: databaseID)
            for receipt in receipts {
                let url = try sourceURL(receipt.relativePath, databaseID: databaseID)
                try FileManager.default.removeItem(at: url)
                try synchronizeDirectory(url.deletingLastPathComponent())
            }
            state.retirementID = nil
            state.retiringSources = nil
            try persist(state, databaseID: databaseID)
        }
    }

    static func recovery(for databaseID: UUID) throws -> RecoverySnapshot {
        try withLock(for: databaseID) {
            let raw: Data?
            var readFailed = false
            do { raw = try ownerData(databaseID) } catch { raw = nil; readFailed = true }
            let state = try? loadState(databaseID)
            let unavailable = readFailed || (raw != nil && state == nil)
            var receipts = state?.retiringSources ?? []
            for url in try sourceURLs(databaseID) {
                let current = try receipt(at: url, databaseID: databaseID)
                if !receipts.contains(current) { receipts.append(current) }
            }
            let unavailableIDs = Set(receipts.filter { receipt in
                do { try validate(receipt, databaseID: databaseID); return false } catch { return true }
            }.map(\.id))
            return RecoverySnapshot(databaseID: databaseID, receipts: receipts,
                isRevoked: try tombstoned(databaseID) || state?.removed == true,
                retirementID: state?.retirementID, ownerDigest: raw.map(FileDigest.sha512),
                ownerUnavailable: unavailable, unavailableReceiptIDs: unavailableIDs)
        }
    }

    static func export(_ receipt: Receipt, for databaseID: UUID) throws -> Data {
        try withLock(for: databaseID) {
            try validate(receipt, databaseID: databaseID)
            let data = try Data(contentsOf: sourceURL(receipt.relativePath, databaseID: databaseID))
            guard FileDigest.sha512(data) == receipt.digest else { throw OwnershipError.sourceChanged }
            return data
        }
    }

    /// Separate destructive consent applies only to this snapshot, never newer sources.
    static func discard(_ snapshot: RecoverySnapshot) throws {
        try withLock(for: snapshot.databaseID) {
            guard try ownerData(snapshot.databaseID).map(FileDigest.sha512) == snapshot.ownerDigest else { throw OwnershipError.sourceChanged }
            var state = (try? loadState(snapshot.databaseID)) ?? OwnerState(version: 1, removed: snapshot.isRevoked)
            guard state.retirementID == snapshot.retirementID else { throw OwnershipError.sourceChanged }
            let paths = Set(snapshot.receipts.map(\.relativePath))
            for path in paths {
                let url = try sourceURL(path, databaseID: snapshot.databaseID)
                if try exists(url) {
                    let actual = try receipt(at: url, databaseID: snapshot.databaseID)
                    guard snapshot.receipts.contains(actual) else { throw OwnershipError.sourceChanged }
                }
            }
            state.retirementID = UUID()
            state.retiringSources = snapshot.receipts
            try persist(state, databaseID: snapshot.databaseID)
            for path in paths {
                let url = try sourceURL(path, databaseID: snapshot.databaseID)
                if try exists(url) {
                    try FileManager.default.removeItem(at: url)
                    try synchronizeDirectory(url.deletingLastPathComponent())
                }
            }
            state.retirementID = nil
            state.retiringSources = nil
            try persist(state, databaseID: snapshot.databaseID)
        }
    }

    /// List-lock -> flock; revocation never deletes unresolved encrypted sources.
    static func revokeForRemoval(_ databaseID: UUID) throws -> Bool {
        try withLock(for: databaseID) {
            try writeAtomicallyAndDurably(Data("removed".utf8), to: controlDirectory(databaseID).appendingPathComponent(".tombstone"))
            var state = try loadState(databaseID) ?? OwnerState(version: 1, removed: false)
            state.removed = true
            try persist(state, databaseID: databaseID)
            return try state.retirementID == nil && sourceURLs(databaseID).isEmpty
        }
    }

    static func isRevoked(_ databaseID: UUID) -> Bool {
        do { return try withLock(for: databaseID) { try tombstoned(databaseID) || loadState(databaseID)?.removed == true } }
        catch { return true }
    }

    static func remove(_ save: PendingSave) {
        // Retained for existing pre-commit cleanup; successful merges consume captured receipts.
        if let source = try? read(save) { try? consume([source.receipt], for: save.databaseID) }
    }

    static func moveToBackups(_ save: PendingSave, for reference: DatabaseReference) throws -> URL {
        // Resolve the backup location before acquiring flock (list-lock order).
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        return try withLock(for: save.databaseID) {
            try requireNotRemoved(save.databaseID)
            let receipt = try receipt(at: save.fileURL, databaseID: save.databaseID)
            let data = try Data(contentsOf: save.fileURL)
            try createDurableDirectory(at: backupDirectory, anchor: ownerContainer ?? backupDirectory)
            var date = Date.now
            var name = save.fileURL.deletingPathExtension().lastPathComponent
            var url = backupDirectory.appendingPathComponent("\(name)\(DatabaseListStore.retainedBackupSuffix).kdbx")
            while FileManager.default.fileExists(atPath: url.path) {
                name = (LocalDatabaseSaver.backupFilename(for: date) as NSString).deletingPathExtension
                date.addTimeInterval(0.000_001)
                url = backupDirectory.appendingPathComponent("\(name)\(DatabaseListStore.retainedBackupSuffix).kdbx")
            }
            let staging = backupDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staging) }
            try writeAtomicallyAndDurably(data, to: staging)
            guard Darwin.link(staging.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try synchronizeDirectory(backupDirectory)
            guard try Data(contentsOf: url) == data else { throw OwnershipError.sourceChanged }
            try validate(receipt, databaseID: save.databaseID)
            try FileManager.default.removeItem(at: save.fileURL)
            try synchronizeDirectory(save.fileURL.deletingLastPathComponent())
            changed()
            return url
        }
    }

    static func removeAll(for databaseID: UUID) { _ = try? revokeForRemoval(databaseID) }

    static func clearAll() {
        // Only test isolation resets permanent revocations; ordinary removal never unlinks locks.
        if AppGroupContainer.isRedirectedForTesting {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: AppGroupContainer.url.appendingPathComponent("pending-local-save-owners"))
        }
    }

    private static func withLock<T>(for databaseID: UUID, _ body: () throws -> T) throws -> T {
        guard let container = AppGroupContainer.resolvedURL else { throw OwnershipError.recoveryRequired }
        return try $ownerContainer.withValue(container) {
            let directory = controlDirectory(databaseID)
            try createDurableDirectory(at: directory, anchor: container)
            let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(fd) }
            try protectDurableFile(at: directory.appendingPathComponent(".lock"), descriptor: fd)
            try synchronizeDirectory(directory)
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
            defer { flock(fd, LOCK_UN) }
            return try body()
        }
    }

    private static func sourceURLs(_ databaseID: UUID) throws -> [URL] {
        let directory = directoryURL(for: databaseID)
        var urls: [URL] = []
        guard try exists(directory) else { return [] }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            if url.pathExtension.lowercased() == "kdbx" { urls.append(url) }
            else if UUID(uuidString: url.lastPathComponent) != nil {
                urls += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "kdbx" }
            }
        }
        return urls.sorted {
            ($0.lastPathComponent, $0.path) < ($1.lastPathComponent, $1.path)
        }
    }

    private static func relativePath(_ url: URL, databaseID: UUID) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent == databaseID.uuidString ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    private static func sourceURL(_ path: String, databaseID: UUID) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (parts.count == 1 || (parts.count == 2 && UUID(uuidString: String(parts[0])) != nil)),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.lowercased().hasSuffix(".kdbx") else { throw OwnershipError.sourceChanged }
        return directoryURL(for: databaseID).appendingPathComponent(path)
    }

    private static func receipt(at url: URL, databaseID: UUID) throws -> Receipt {
        let relative = relativePath(url, databaseID: databaseID)
        let resolved = try sourceURL(relative, databaseID: databaseID)
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.systemFileNumber] as? NSNumber else { throw OwnershipError.sourceChanged }
        return Receipt(relativePath: relative, fileNumber: number.uint64Value,
                       digest: FileDigest.sha512(try Data(contentsOf: resolved)))
    }

    private static func validate(_ expected: Receipt, databaseID: UUID) throws {
        guard try receipt(at: sourceURL(expected.relativePath, databaseID: databaseID), databaseID: databaseID) == expected else {
            throw OwnershipError.sourceChanged
        }
    }

    private static func exists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private static func ownerData(_ databaseID: UUID) throws -> Data? {
        let url = stateURL(databaseID)
        return try exists(url) ? Data(contentsOf: url) : nil
    }
    private static func tombstoned(_ databaseID: UUID) throws -> Bool {
        try exists(controlDirectory(databaseID).appendingPathComponent(".tombstone"))
    }
    private static func loadState(_ databaseID: UUID) throws -> OwnerState? {
        guard let data = try ownerData(databaseID) else { return nil }
        let state = try JSONDecoder().decode(OwnerState.self, from: data)
        guard state.version == 1 else { throw OwnershipError.recoveryRequired }
        return state
    }
    private static func persist(_ state: OwnerState, databaseID: UUID) throws {
        try writeAtomicallyAndDurably(JSONEncoder().encode(state), to: stateURL(databaseID))
        changed()
    }
    private static func requireKnownState(_ databaseID: UUID) throws { _ = try loadState(databaseID) }
    private static func requireNotRemoved(_ databaseID: UUID) throws {
        if try tombstoned(databaseID) || loadState(databaseID)?.removed == true { throw OwnershipError.removed }
    }
    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
    private static func stateURL(_ id: UUID) -> URL { controlDirectory(id).appendingPathComponent("owner.json") }
    private static func controlDirectory(_ id: UUID) -> URL {
        (ownerContainer ?? AppGroupContainer.url).appendingPathComponent("pending-local-save-owners", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private static var rootURL: URL { (ownerContainer ?? AppGroupContainer.url).appendingPathComponent("pending-local-saves", isDirectory: true) }
    private static func directoryURL(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
}
