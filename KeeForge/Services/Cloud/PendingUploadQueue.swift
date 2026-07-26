import CoreFoundation
import Darwin
import Foundation

enum PendingUploadQueue {
    enum UpdateError: Error, Equatable {
        /// The marker file was dropped (typically by a concurrent drain) before
        /// this update ran. Persisting anyway would resurrect a marker that has
        /// already been handled, so callers must treat this as a lost race.
        case markerNoLongerExists
    }

    struct Marker: Codable, Equatable, Sendable {
        let databaseId: UUID
        let encryptedBytesCacheURL: String
        /// SHA-512 the payload bytes at `encryptedBytesCacheURL` must still
        /// hash to when the drainer pushes them. A provisional marker (written
        /// before the AutoFill save rewrites the cache) records the base
        /// bytes' hash; the finalize step swaps in the saved payload's hash.
        var openTimeSHA512: Data
        var expectedRev: String?
        let createdAt: Date
        var lastSyncError: String?
        /// Remote revision whose content the payload was derived from — the
        /// rev recorded on the reference when the saving process opened the
        /// database. The drainer only auto-rebases a conflicted marker when
        /// this equals the reported remote head (a provable fast-forward).
        /// Markers persisted before this field existed decode as `nil`, which
        /// conservatively disables auto-rebase for them.
        var baseRev: String?

        init(
            databaseId: UUID,
            encryptedBytesCacheURL: String,
            openTimeSHA512: Data,
            expectedRev: String?,
            createdAt: Date,
            lastSyncError: String?,
            baseRev: String? = nil
        ) {
            self.databaseId = databaseId
            self.encryptedBytesCacheURL = encryptedBytesCacheURL
            self.openTimeSHA512 = openTimeSHA512
            self.expectedRev = expectedRev
            self.createdAt = createdAt
            self.lastSyncError = lastSyncError
            self.baseRev = baseRev
        }
    }

    struct StoredMarker: Sendable {
        let id: UUID
        let fileURL: URL
        var marker: Marker
    }

    struct Environment: Sendable {
        var appGroupContainerURL: @Sendable () -> URL
        var createDirectory: @Sendable (URL) throws -> Void
        var listDirectory: @Sendable (URL) throws -> [URL]
        var readData: @Sendable (URL) throws -> Data
        var removeItem: @Sendable (URL) throws -> Void
        var encodeMarker: @Sendable (Marker) throws -> Data
        var decodeMarker: @Sendable (Data) throws -> Marker
        var writeMarkerAtomically: @Sendable (Data, URL) throws -> Void
        var postDarwinNotification: @Sendable () -> Void

        static let live = Environment(
            appGroupContainerURL: {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID
                ) ?? FileManager.default.temporaryDirectory
            },
            createDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            },
            listDirectory: { url in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            },
            readData: { url in
                try Data(contentsOf: url)
            },
            removeItem: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            },
            encodeMarker: { marker in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(marker)
            },
            decodeMarker: { data in
                try JSONDecoder().decode(Marker.self, from: data)
            },
            writeMarkerAtomically: { data, url in
                try writeAtomicallyAndDurably(data, to: url)
            },
            postDarwinNotification: {
                let name = CFNotificationName(PendingUploadQueue.notificationName as CFString)
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    name,
                    nil,
                    nil,
                    true
                )
            }
        )
    }

    static let notificationName = "com.keevault.app.pending-upload-enqueued"

    static func enqueue(_ marker: Marker, notifying: Bool = true) throws -> StoredMarker {
        try enqueue(marker, notifying: notifying, environment: .live)
    }

    /// `notifying: false` writes the marker durably without posting the Darwin
    /// drain notification. Used for provisional markers that precede their
    /// payload's cache write — the notification is posted separately once the
    /// payload is actually in place (see `postEnqueuedNotification`).
    static func enqueue(_ marker: Marker, notifying: Bool = true, environment: Environment) throws -> StoredMarker {
        let markerID = UUID()
        let directoryURL = queueDirectoryURL(for: marker.databaseId, environment: environment)
        let fileURL = directoryURL.appendingPathComponent("\(markerID.uuidString).json", isDirectory: false)
        let storedMarker = StoredMarker(id: markerID, fileURL: fileURL, marker: marker)
        try persist(storedMarker, environment: environment)
        if notifying {
            environment.postDarwinNotification()
        }
        return storedMarker
    }

    static func postEnqueuedNotification() {
        postEnqueuedNotification(environment: .live)
    }

    static func postEnqueuedNotification(environment: Environment) {
        environment.postDarwinNotification()
    }

    static func listMarkers(for databaseId: UUID? = nil) -> [StoredMarker] {
        listMarkers(for: databaseId, environment: .live)
    }

    static func listMarkers(for databaseId: UUID? = nil, environment: Environment) -> [StoredMarker] {
        let queueRoot = queueRootURL(environment: environment)
        let fm = FileManager.default
        guard fm.fileExists(atPath: queueRoot.path) else { return [] }

        let databaseDirectories: [URL]
        if let databaseId {
            databaseDirectories = [queueRoot.appendingPathComponent(databaseId.uuidString, isDirectory: true)]
        } else {
            databaseDirectories = (try? environment.listDirectory(queueRoot)) ?? []
        }

        return databaseDirectories
            .flatMap { directoryURL in
                ((try? environment.listDirectory(directoryURL)) ?? []).compactMap { fileURL in
                    guard fileURL.pathExtension == "json",
                          let markerID = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent),
                          let data = try? environment.readData(fileURL),
                          let marker = try? environment.decodeMarker(data) else {
                        return nil
                    }

                    return StoredMarker(id: markerID, fileURL: fileURL, marker: marker)
                }
            }
            .sorted { lhs, rhs in
                if lhs.marker.createdAt == rhs.marker.createdAt {
                    return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent
                }
                return lhs.marker.createdAt < rhs.marker.createdAt
            }
    }

    static func drop(_ storedMarker: StoredMarker) throws {
        try drop(storedMarker, environment: .live)
    }

    static func drop(_ storedMarker: StoredMarker, environment: Environment) throws {
        try environment.removeItem(storedMarker.fileURL)
    }

    static func update(_ storedMarker: StoredMarker) throws -> StoredMarker {
        try update(storedMarker, environment: .live)
    }

    static func update(_ storedMarker: StoredMarker, environment: Environment) throws -> StoredMarker {
        // Compare-and-swap against the on-disk marker: if a concurrent drain has
        // already dropped the file, refuse to recreate it. Without this guard an
        // in-flight `markConflicted`/rebase could resurrect a marker the drainer
        // just completed, leaving a phantom pending upload behind.
        guard FileManager.default.fileExists(atPath: storedMarker.fileURL.path) else {
            throw UpdateError.markerNoLongerExists
        }
        try persist(storedMarker, environment: environment)
        return storedMarker
    }

    static func markConflicted(_ storedMarker: StoredMarker, message: String) throws -> StoredMarker {
        var updated = storedMarker
        updated.marker.lastSyncError = message
        return try update(updated, environment: .live)
    }

    static func markConflicted(_ storedMarker: StoredMarker, message: String, environment: Environment) throws -> StoredMarker {
        var updated = storedMarker
        updated.marker.lastSyncError = message
        return try update(updated, environment: environment)
    }

    /// Drops every marker for `databaseId` whose recorded payload SHA-512
    /// equals `payloadSHA512`, except `excludedMarkerID`.
    ///
    /// SHA equality is a proof of supersession: the caller's own base bytes
    /// hash to the marker's recorded payload, so that exact content forms the
    /// base of whatever the caller is about to upload or has just uploaded.
    /// The marker can no longer represent unsaved content — conflicted or not
    /// — which is why this drops conflicted markers too (the equality is the
    /// evidence the conflict was spurious). Best-effort per marker: a failed
    /// drop leaves at worst a phantom conflict badge, never data loss.
    static func dropMarkers(
        withPayloadSHA512 payloadSHA512: Data,
        for databaseId: UUID,
        excluding excludedMarkerID: UUID? = nil
    ) {
        dropMarkers(
            withPayloadSHA512: payloadSHA512,
            for: databaseId,
            excluding: excludedMarkerID,
            environment: .live
        )
    }

    static func dropMarkers(
        withPayloadSHA512 payloadSHA512: Data,
        for databaseId: UUID,
        excluding excludedMarkerID: UUID?,
        environment: Environment
    ) {
        for storedMarker in listMarkers(for: databaseId, environment: environment)
        where storedMarker.id != excludedMarkerID && storedMarker.marker.openTimeSHA512 == payloadSHA512 {
            try? drop(storedMarker, environment: environment)
        }
    }

    static func removeAllMarkers(for databaseId: UUID) throws {
        try removeAllMarkers(for: databaseId, environment: .live)
    }

    static func removeAllMarkers(for databaseId: UUID, environment: Environment) throws {
        try environment.removeItem(queueDirectoryURL(for: databaseId, environment: environment))
    }

    static func clearAll() throws {
        try clearAll(environment: .live)
    }

    static func clearAll(environment: Environment) throws {
        try environment.removeItem(queueRootURL(environment: environment))
    }

    static func makeRelativeAppGroupPath(for url: URL) throws -> String {
        try makeRelativeAppGroupPath(for: url, environment: .live)
    }

    static func makeRelativeAppGroupPath(for url: URL, environment: Environment) throws -> String {
        let standardizedURL = url.standardizedFileURL
        let containerURL = environment.appGroupContainerURL().standardizedFileURL
        let containerPath = containerURL.path.hasSuffix("/") ? containerURL.path : "\(containerURL.path)/"
        let candidatePath = standardizedURL.path

        guard candidatePath == containerURL.path || candidatePath.hasPrefix(containerPath) else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        if candidatePath == containerURL.path {
            return "."
        }

        return String(candidatePath.dropFirst(containerPath.count))
    }

    static func resolveAppGroupURL(for relativePath: String) -> URL {
        resolveAppGroupURL(for: relativePath, environment: .live)
    }

    static func resolveAppGroupURL(for relativePath: String, environment: Environment) -> URL {
        let containerURL = environment.appGroupContainerURL()
        if relativePath == "." {
            return containerURL
        }
        return containerURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    private static func persist(_ storedMarker: StoredMarker, environment: Environment) throws {
        let directoryURL = storedMarker.fileURL.deletingLastPathComponent()
        try environment.createDirectory(directoryURL)
        let data = try environment.encodeMarker(storedMarker.marker)
        try environment.writeMarkerAtomically(data, storedMarker.fileURL)
    }

    private static func queueRootURL(environment: Environment) -> URL {
        environment.appGroupContainerURL().appendingPathComponent("pending-uploads", isDirectory: true)
    }

    private static func queueDirectoryURL(for databaseId: UUID, environment: Environment) -> URL {
        queueRootURL(environment: environment).appendingPathComponent(databaseId.uuidString, isDirectory: true)
    }
}

private func writeAtomicallyAndDurably(_ data: Data, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let directoryURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

    let tempURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
    defer {
        try? fileManager.removeItem(at: tempURL)
    }

    try data.withUnsafeBytes { buffer in
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

        guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
            throw CocoaError(.fileWriteUnknown)
        }

        var totalWritten = 0
        while totalWritten < data.count {
            let bytesWritten = write(fd, baseAddress.advanced(by: totalWritten), data.count - totalWritten)
            if bytesWritten < 0 {
                throw POSIXError(.EIO)
            }
            totalWritten += bytesWritten
        }

        if fsync(fd) != 0 {
            throw POSIXError(.EIO)
        }
    }

    if rename(tempURL.path, destinationURL.path) != 0 {
        throw POSIXError(.EIO)
    }

    let directoryFD = open(directoryURL.path, O_RDONLY)
    guard directoryFD >= 0 else {
        throw POSIXError(.EIO)
    }
    defer { close(directoryFD) }

    if fsync(directoryFD) != 0 {
        throw POSIXError(.EIO)
    }
}
