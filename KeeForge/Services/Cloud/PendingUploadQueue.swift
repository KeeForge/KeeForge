import CoreFoundation
import Darwin
import Foundation

enum PendingUploadQueue {
    enum UpdateError: Error, Equatable {
        /// The marker file was dropped (typically by a concurrent drain) before
        /// this update ran. Persisting anyway would resurrect a marker that has
        /// already been handled, so callers must treat this as a lost race.
        case markerNoLongerExists
        /// Another process updated this marker after the caller read it.
        /// Replacing that newer value could revert a finalized payload hash.
        case markerChanged
    }

    struct RekeyContext: Codable, Equatable, Sendable {
        let epoch: UUID
        let keyFileBookmarkData: Data?
        let keyFileFilename: String?

        init(epoch: UUID = UUID(), keyFileBookmarkData: Data?, keyFileFilename: String?) {
            self.epoch = epoch
            self.keyFileBookmarkData = keyFileBookmarkData
            self.keyFileFilename = keyFileFilename
        }
    }

    struct Marker: Codable, Equatable, Sendable {
        let databaseId: UUID
        let encryptedBytesCacheURL: String
        /// SHA-512 the bytes at `encryptedBytesCacheURL` must still hash to
        /// when the drainer pushes them. A provisional marker records the base
        /// bytes' hash; finalize swaps in the saved payload's hash.
        var openTimeSHA512: Data
        /// False only during the durable pre-save phase. Until finalization,
        /// `openTimeSHA512` identifies the base bytes rather than the saved
        /// AutoFill payload and must never be used as merge input.
        /// `nil` on markers written before this field existed: v1.16.0 already
        /// wrote the provisional base hash first without recording the phase,
        /// so such a marker is never proven to describe its payload.
        var isPayloadFinalized: Bool?
        /// Monotonic compare-and-swap generation for in-place updates.
        /// Legacy markers start at zero.
        var generation: UInt64
        var expectedRev: String?
        let createdAt: Date
        /// Whether the last drain attempt was blocked by a conflict. A cached
        /// verdict only: every drain re-derives it from the rekey, payload-SHA
        /// and provider-revision gates, so a marker that decodes as `false`
        /// (any marker written before this field existed) is re-checked rather
        /// than pushed blind.
        var isConflicted: Bool = false
        /// Remote revision the payload was derived from (the reference's rev
        /// when the saving process opened the database). The drainer only
        /// auto-rebases a conflicted marker when this equals the remote head.
        /// Legacy markers decode as `nil`, disabling auto-rebase for them.
        var baseRev: String?

        var attemptIsFenced: Bool?
        var discardRequested: Bool?
        var requiresLocalRecovery: Bool?
        var absorbedOperationIDs: [UUID]?
        var predecessorSHA512: Data?
        var predecessorOperationID: UUID?
        var remoteBaseSHA512: Data?
        var intendedPayloadSHA512: Data?
        var intendedPayloadPath: String?
        var keyEpoch: UUID?
        var rekeyContext: RekeyContext?
        /// A nonnil attempt is uncertain until exact-byte confirmation, even after a restart.
        var uploadAttemptID: UUID?
        var confirmedRemoteRev: String?
        var confirmedRemoteHash: String?
        var confirmedAt: Date?

        init(
            databaseId: UUID,
            encryptedBytesCacheURL: String,
            openTimeSHA512: Data,
            expectedRev: String?,
            createdAt: Date,
            isConflicted: Bool = false,
            baseRev: String? = nil,
            isPayloadFinalized: Bool? = true,
            generation: UInt64 = 0
        ) {
            self.databaseId = databaseId
            self.encryptedBytesCacheURL = encryptedBytesCacheURL
            self.openTimeSHA512 = openTimeSHA512
            self.expectedRev = expectedRev
            self.createdAt = createdAt
            self.isConflicted = isConflicted
            self.baseRev = baseRev
            self.isPayloadFinalized = isPayloadFinalized
            self.generation = generation
        }

        /// Hand-written so markers persisted before `isConflicted` existed keep
        /// decoding. A synthesized decoder demands every non-optional key and
        /// ignores the property default, and `listMarkers` drops a marker it
        /// cannot decode — which would strand an AutoFill save's bytes in the
        /// shared cache with no marker covering them, the one thing the queue
        /// exists to prevent.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            databaseId = try container.decode(UUID.self, forKey: .databaseId)
            encryptedBytesCacheURL = try container.decode(String.self, forKey: .encryptedBytesCacheURL)
            openTimeSHA512 = try container.decode(Data.self, forKey: .openTimeSHA512)
            expectedRev = try container.decodeIfPresent(String.self, forKey: .expectedRev)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            isConflicted = try container.decodeIfPresent(Bool.self, forKey: .isConflicted) ?? false
            baseRev = try container.decodeIfPresent(String.self, forKey: .baseRev)
            // Missing stays `nil`, not `true`: an extension interrupted between
            // the cache write and finalization before an upgrade left a base
            // hash here. The synthesized encoder omits `nil` again, so a
            // drainer update keeps the marker unproven.
            isPayloadFinalized = try container.decodeIfPresent(Bool.self, forKey: .isPayloadFinalized)
            generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
            attemptIsFenced = try container.decodeIfPresent(Bool.self, forKey: .attemptIsFenced)
            discardRequested = try container.decodeIfPresent(Bool.self, forKey: .discardRequested)
            requiresLocalRecovery = try container.decodeIfPresent(Bool.self, forKey: .requiresLocalRecovery)
            absorbedOperationIDs = try container.decodeIfPresent([UUID].self, forKey: .absorbedOperationIDs)
            predecessorSHA512 = try container.decodeIfPresent(Data.self, forKey: .predecessorSHA512)
            predecessorOperationID = try container.decodeIfPresent(UUID.self, forKey: .predecessorOperationID)
            remoteBaseSHA512 = try container.decodeIfPresent(Data.self, forKey: .remoteBaseSHA512)
            intendedPayloadSHA512 = try container.decodeIfPresent(Data.self, forKey: .intendedPayloadSHA512)
            intendedPayloadPath = try container.decodeIfPresent(String.self, forKey: .intendedPayloadPath)
            keyEpoch = try container.decodeIfPresent(UUID.self, forKey: .keyEpoch)
            rekeyContext = try container.decodeIfPresent(RekeyContext.self, forKey: .rekeyContext)
            uploadAttemptID = try container.decodeIfPresent(UUID.self, forKey: .uploadAttemptID)
            confirmedRemoteRev = try container.decodeIfPresent(String.self, forKey: .confirmedRemoteRev)
            confirmedRemoteHash = try container.decodeIfPresent(String.self, forKey: .confirmedRemoteHash)
            confirmedAt = try container.decodeIfPresent(Date.self, forKey: .confirmedAt)
        }
    }

    struct StoredMarker: Sendable {
        let id: UUID
        let fileURL: URL
        var marker: Marker
    }

    /// Creation records have a distinct extension and cannot enter replacement-marker recovery.
    struct CreationIntent: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case prepared, reserved, attempting, confirmed, completed }
        let operationID: UUID
        let ownerDatabaseID: UUID
        let provider: String
        let accountID: String
        let target: CloudFileCreationTarget
        let payloadSHA512: Data
        let payloadPath: String
        let referenceTemplate: DatabaseReference
        let isConflictCopy: Bool
        var creationID: String?
        var requestedTarget: CloudFileCreationTarget?
        var phase: Phase = .prepared
        var receipt: DatabaseReference?
        var isPaused: Bool = false
        var lastIssue: CloudSyncIssue?
    }

    static func listCreations(for databaseID: UUID? = nil, includingCompleted: Bool = false, environment: Environment = .live) throws -> [CreationIntent] {
        let root = queueRootURL(environment: environment)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try databaseID.map { [queueDirectoryURL(for: $0, environment: environment)] } ?? environment.listDirectory(root)
        return try directories.flatMap { directory -> [CreationIntent] in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try environment.listDirectory(directory).filter { $0.pathExtension == "creation" }.map {
                var intent = try JSONDecoder().decode(CreationIntent.self, from: environment.readData($0))
                if FileManager.default.fileExists(atPath: creationPauseURL(intent, environment: environment).path) { intent.isPaused = true }
                return intent
            }
        }.filter { includingCompleted || $0.phase != .completed }
    }

    static func storeCreation(_ intent: CreationIntent, environment: Environment = .live) throws {
        let directory = queueDirectoryURL(for: intent.ownerDatabaseID, environment: environment)
        try environment.createDirectory(directory)
        let data = try JSONEncoder().encode(intent)
        try environment.writeMarkerAtomically(data, directory.appendingPathComponent("\(intent.operationID.uuidString).creation"))
    }

    static func creationPayloadURL(ownerDatabaseID: UUID, operationID: UUID, environment: Environment = .live) -> URL {
        queueDirectoryURL(for: ownerDatabaseID, environment: environment).appendingPathComponent("\(operationID.uuidString).creation.kdbx")
    }

    static func creationPauseURL(_ intent: CreationIntent, environment: Environment = .live) -> URL {
        queueDirectoryURL(for: intent.ownerDatabaseID, environment: environment).appendingPathComponent("\(intent.operationID.uuidString).creation-paused")
    }

    static func requestCreationPause(_ intent: CreationIntent, environment: Environment = .live) throws {
        try environment.writeMarkerAtomically(Data([1]), creationPauseURL(intent, environment: environment))
    }

    /// Only an unattempted creation may relinquish its sole retained ciphertext.
    static func cancelCreation(_ intent: CreationIntent, environment: Environment = .live) throws {
        if intent.phase == .prepared || intent.phase == .reserved {
            let directory = queueDirectoryURL(for: intent.ownerDatabaseID, environment: environment)
            try environment.removeItem(directory.appendingPathComponent("\(intent.operationID.uuidString).creation"))
            try environment.removeItem(resolveAppGroupURL(for: intent.payloadPath, environment: environment))
            try environment.removeItem(creationPauseURL(intent, environment: environment))
        } else {
            var paused = intent
            paused.isPaused = true
            try storeCreation(paused, environment: environment)
        }
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
            appGroupContainerURL: { AppGroupContainer.url },
            createDirectory: { url in
                try createDurableDirectory(at: url)
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
    static let markerLockFileName = ".markers.lock"

    static func enqueue(_ marker: Marker, notifying: Bool = true) throws -> StoredMarker {
        try enqueue(marker, notifying: notifying, environment: .live)
    }

    /// `notifying: false` writes the marker durably without posting the Darwin
    /// drain notification — for provisional markers that precede their
    /// payload's cache write (see `postEnqueuedNotification`).
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
        _ = try dropIfUnchanged(storedMarker, environment: environment)
    }

    /// Removes a marker only while its persisted value still matches the
    /// snapshot the caller handled. A late AutoFill finalization changes the
    /// marker in place; deleting by id alone would then discard a different,
    /// still-unuploaded payload.
    @discardableResult
    static func dropIfUnchanged(_ storedMarker: StoredMarker, environment: Environment = .live) throws -> Bool {
        try withExclusiveMarkerLock(for: storedMarker.fileURL) {
            guard let data = try? environment.readData(storedMarker.fileURL),
                  let current = try? environment.decodeMarker(data),
                  current == storedMarker.marker else {
                return false
            }
            try environment.removeItem(storedMarker.fileURL)
            if let path = current.intendedPayloadPath,
               !listMarkers(for: current.databaseId, environment: environment).contains(where: { $0.marker.intendedPayloadPath == path }) {
                try? environment.removeItem(resolveAppGroupURL(for: path, environment: environment))
            }
            return true
        }
    }

    static func update(_ storedMarker: StoredMarker) throws -> StoredMarker {
        try update(storedMarker, environment: .live)
    }

    static func update(_ storedMarker: StoredMarker, environment: Environment) throws -> StoredMarker {
        // Compare-and-swap against the on-disk marker: if a concurrent drain has
        // already dropped the file, refuse to recreate it. Without this guard an
        // in-flight `markConflicted`/rebase could resurrect a marker the drainer
        // just completed, leaving a phantom pending upload behind.
        try withExclusiveMarkerLock(for: storedMarker.fileURL) {
            guard let data = try? environment.readData(storedMarker.fileURL),
                  let current = try? environment.decodeMarker(data) else {
                throw UpdateError.markerNoLongerExists
            }
            guard current.generation == storedMarker.marker.generation else {
                throw UpdateError.markerChanged
            }
            var updated = storedMarker
            updated.marker.generation += 1
            try persist(updated, environment: environment)
            return updated
        }
    }

    /// Phase 3 of the AutoFill two-phase marker: records the saved payload's
    /// hash on the marker as it is on disk now, not as the extension read it.
    /// A drainer that ran between the cache write and this call has already
    /// bumped the generation and flagged the marker conflicted, because the
    /// cache no longer matched the provisional base hash. A generation-checked
    /// `update` would then fail and leave that provisional marker behind for
    /// good, which makes every later recovery lookup `.unavailable`. The
    /// conflict flag is cleared because the hash it was raised against is
    /// gone; the drainer re-checks the finalized marker on its next pass.
    /// The drainer's own changes (`expectedRev`, `baseRev`) are kept.
    static func finalize(_ storedMarker: StoredMarker) throws -> StoredMarker {
        try finalize(storedMarker, environment: .live)
    }

    static func finalize(_ storedMarker: StoredMarker, environment: Environment) throws -> StoredMarker {
        try withExclusiveMarkerLock(for: storedMarker.fileURL) {
            guard let data = try? environment.readData(storedMarker.fileURL),
                  var current = try? environment.decodeMarker(data) else {
                throw UpdateError.markerNoLongerExists
            }
            guard current.isPayloadFinalized == false,
                  current.intendedPayloadSHA512 == nil || current.intendedPayloadSHA512 == storedMarker.marker.openTimeSHA512 else {
                throw UpdateError.markerChanged
            }
            current.openTimeSHA512 = storedMarker.marker.openTimeSHA512
            current.isPayloadFinalized = true
            current.isConflicted = false
            current.requiresLocalRecovery = nil
            current.generation += 1
            let finalized = StoredMarker(id: storedMarker.id, fileURL: storedMarker.fileURL, marker: current)
            try persist(finalized, environment: environment)
            return finalized
        }
    }

    static func markConflicted(_ storedMarker: StoredMarker, environment: Environment = .live) throws -> StoredMarker {
        var updated = storedMarker
        updated.marker.isConflicted = true
        return try update(updated, environment: environment)
    }

    /// Drops every marker for `databaseId` whose recorded payload SHA-512
    /// equals `payloadSHA512`, except `excludedMarkerID`.
    ///
    /// SHA equality proves supersession: that exact content is the base of
    /// what the caller is about to upload or just uploaded, so the marker can
    /// no longer represent unsaved content — including conflicted markers,
    /// whose conflict the equality shows to be spurious. Only a finalized
    /// marker counts: an unproven one may record the base its AutoFill save
    /// started from, so a save on that base does not contain the change.
    /// Best-effort per marker: a failed drop leaves a phantom conflict badge,
    /// never data loss.
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
        where storedMarker.id != excludedMarkerID
            && (storedMarker.marker.uploadAttemptID == nil || storedMarker.marker.attemptIsFenced == true)
            && storedMarker.marker.isPayloadFinalized == true
            && storedMarker.marker.openTimeSHA512 == payloadSHA512 {
            _ = try? dropIfUnchanged(storedMarker, environment: environment)
        }
    }

    static func removeAllMarkers(for databaseId: UUID) throws {
        try removeAllMarkers(for: databaseId, environment: .live)
    }

    static func removeAllMarkers(for databaseId: UUID, environment: Environment) throws {
        for marker in listMarkers(for: databaseId, environment: environment) {
            _ = try dropIfUnchanged(marker, environment: environment)
        }
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

    static func transferMergedSources(_ sources: [StoredMarker], toPayloadSHA512 sha: Data, for databaseID: UUID, environment: Environment = .live) throws {
        try withCommitLock(for: databaseID, environment: environment) {
            guard var owner = listMarkers(for: databaseID, environment: environment).last(where: {
                $0.marker.isPayloadFinalized == true && $0.marker.intendedPayloadSHA512 == sha && $0.marker.intendedPayloadPath != nil
            }) else { return }
            owner.marker.absorbedOperationIDs = Array(Set((owner.marker.absorbedOperationIDs ?? []) + sources.map(\.id)))
            owner = try update(owner, environment: environment)
            for source in sources where source.id != owner.id && (source.marker.uploadAttemptID == nil || source.marker.attemptIsFenced == true || source.marker.confirmedAt != nil) {
                _ = try dropIfUnchanged(source, environment: environment)
            }
        }
    }

    /// Serializes the local journal/cache/head transaction across app and extension processes.
    static func withCommitLock<T>(for databaseID: UUID, environment: Environment = .live, _ body: () throws -> T) throws -> T {
        let directory = queueDirectoryURL(for: databaseID, environment: environment)
        try environment.createDirectory(directory)
        let lockURL = directory.appendingPathComponent(".commit.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func hasRekeyJournal(for databaseID: UUID, environment: Environment = .live) -> Bool {
        listMarkers(for: databaseID, environment: environment).contains { $0.marker.rekeyContext != nil }
    }

    /// The caller holds the commit lock until cache replacement and head publication finish.
    static func prepare(
        reference: DatabaseReference, currentData: Data, intendedData: Data,
        cacheURL: URL, rekeyContext: RekeyContext? = nil,
        remoteBaseSHA512: Data? = nil, environment: Environment = .live
    ) throws -> StoredMarker {
        let currentSHA = KDBXCrypto.sha512(currentData)
        let markers = try listMarkers(for: reference.id, environment: environment).map { try recoverPrepared($0, environment: environment) }
        guard !markers.contains(where: { $0.marker.rekeyContext != nil }) else {
            throw SaveError.saveContextUnavailable
        }
        if let rekeyContext {
            guard markers.isEmpty, rekeyContext.epoch != reference.cloudSyncMetadata?.keyEpoch else {
                throw SaveError.saveContextUnavailable
            }
        }
        let predecessor = markers.last { $0.marker.isPayloadFinalized == true && $0.marker.openTimeSHA512 == currentSHA }
        let operationID = UUID()
        let directory = queueDirectoryURL(for: reference.id, environment: environment)
        try environment.createDirectory(directory)
        let payloadURL = directory.appendingPathComponent("\(operationID.uuidString).kdbx")
        try environment.writeMarkerAtomically(intendedData, payloadURL)
        var marker = Marker(
            databaseId: reference.id,
            encryptedBytesCacheURL: try makeRelativeAppGroupPath(for: cacheURL, environment: environment),
            openTimeSHA512: currentSHA, expectedRev: predecessor?.marker.expectedRev ?? reference.expectedCloudRevision,
            createdAt: .now, baseRev: predecessor?.marker.baseRev ?? reference.expectedCloudRevision,
            isPayloadFinalized: false
        )
        marker.predecessorSHA512 = currentSHA
        marker.predecessorOperationID = predecessor?.id
        marker.remoteBaseSHA512 = remoteBaseSHA512 ?? predecessor?.marker.remoteBaseSHA512 ?? (predecessor == nil ? currentSHA : nil)
        marker.intendedPayloadSHA512 = KDBXCrypto.sha512(intendedData)
        marker.intendedPayloadPath = try makeRelativeAppGroupPath(for: payloadURL, environment: environment)
        marker.keyEpoch = rekeyContext?.epoch ?? reference.cloudSyncMetadata?.keyEpoch
        marker.rekeyContext = rekeyContext
        let stored = StoredMarker(id: operationID, fileURL: directory.appendingPathComponent("\(operationID.uuidString).json"), marker: marker)
        try persist(stored, environment: environment)
        return stored
    }

    /// Only new journals contain enough evidence to recover an interrupted finalization.
    static func recoverPrepared(_ stored: StoredMarker, environment: Environment = .live) throws -> StoredMarker {
        guard stored.marker.isPayloadFinalized == false,
              stored.marker.rekeyContext == nil,
              let intendedSHA = stored.marker.intendedPayloadSHA512,
              let path = stored.marker.intendedPayloadPath,
              KDBXCrypto.sha512(try environment.readData(resolveAppGroupURL(for: path, environment: environment))) == intendedSHA else {
            return stored
        }
        if KDBXCrypto.sha512(try environment.readData(resolveAppGroupURL(for: stored.marker.encryptedBytesCacheURL, environment: environment))) == intendedSHA {
            var finalized = stored
            finalized.marker.openTimeSHA512 = intendedSHA
            return try finalize(finalized, environment: environment)
        }
        guard stored.marker.requiresLocalRecovery != true else { return stored }
        var recoverable = stored
        recoverable.marker.requiresLocalRecovery = true
        recoverable.marker.isConflicted = true
        return try update(recoverable, environment: environment)
    }

    /// A remote divergence affects the whole local lineage, including descendants not attempted yet.
    static func markDatabaseConflicted(for databaseID: UUID, environment: Environment = .live) throws {
        for stored in listMarkers(for: databaseID, environment: environment) where !stored.marker.isConflicted {
            _ = try markConflicted(stored, environment: environment)
        }
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

    /// Serializes an in-place marker update with a conditional delete across
    /// the app and AutoFill extension. One lock file per database directory,
    /// never removed while the directory exists: removing a lock file after
    /// unlock can split later callers across two inodes, and a per-marker
    /// sidecar that must stay would pile up one file per AutoFill save.
    /// Queue enumeration ignores it because it is hidden and not JSON.
    private static func withExclusiveMarkerLock<T>(for markerURL: URL, _ operation: () throws -> T) throws -> T {
        let lockURL = markerURL.deletingLastPathComponent()
            .appendingPathComponent(markerLockFileName, isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

func writeAtomicallyAndDurably(_ data: Data, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let directoryURL = destinationURL.deletingLastPathComponent()
    var missingDirectories: [URL] = []
    var ancestor = directoryURL
    while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        missingDirectories.append(ancestor)
        ancestor.deleteLastPathComponent()
    }
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
            if bytesWritten <= 0 {
                throw POSIXError(.EIO)
            }
            totalWritten += bytesWritten
        }

        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tempURL.path)
        #endif
        if fsync(fd) != 0 {
            throw POSIXError(.EIO)
        }
    }

    if rename(tempURL.path, destinationURL.path) != 0 {
        throw POSIXError(.EIO)
    }

    for directory in [directoryURL] + missingDirectories.map({ $0.deletingLastPathComponent() }) {
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw POSIXError(.EIO) }
        let status = fsync(directoryFD)
        close(directoryFD)
        guard status == 0 else { throw POSIXError(.EIO) }
    }
}

func createDurableDirectory(at directory: URL) throws {
    var missing: [URL] = []
    var ancestor = directory
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        missing.append(ancestor)
        ancestor.deleteLastPathComponent()
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for url in [directory] + missing.map({ $0.deletingLastPathComponent() }) {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let status = fsync(fd)
        Darwin.close(fd)
        guard status == 0 else { throw POSIXError(.EIO) }
    }
}
