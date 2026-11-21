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

    struct KeyChange: Codable, Equatable, Sendable {
        let epoch: UUID
        let keyFileBookmarkData: Data?
        let keyFileFilename: String?

        init(epoch: UUID = UUID(), keyFileBookmarkData: Data?, keyFileFilename: String?) {
            self.epoch = epoch
            self.keyFileBookmarkData = keyFileBookmarkData
            self.keyFileFilename = keyFileFilename
        }
    }

    struct LocalCommitBaseline: Codable, Equatable, Sendable {
        let headOperationID: UUID?
        let keyEpoch: UUID?
        let lastMasterKeyChangeAt: Date?

        init(reference: DatabaseReference) {
            headOperationID = reference.cloudSyncMetadata?.localHeadOperationID
            keyEpoch = reference.cloudSyncMetadata?.keyEpoch
            lastMasterKeyChangeAt = reference.lastMasterKeyChangeAt
        }

        func hasCompatibleEpoch(_ reference: DatabaseReference) -> Bool {
            reference.cloudSyncMetadata?.keyEpoch == keyEpoch && reference.lastMasterKeyChangeAt == lastMasterKeyChangeAt
        }
    }

    struct JournalBinding: Codable, Equatable, Sendable {
        let version: Int
        let databaseID: UUID?
        let operationID: UUID?
        let provider: String?
        let accountID: String?
        let fileID: String?
        let preferenceFingerprint: Data?
        let intendedPreferenceFingerprint: Data?
        let alternatePreferenceFingerprint: Data?
        let baseline: LocalCommitBaseline?

        private enum CodingKeys: String, CodingKey { case version, databaseID, operationID, provider, accountID, fileID, preferenceFingerprint, intendedPreferenceFingerprint, alternatePreferenceFingerprint, baseline }

        private init(version: Int, databaseID: UUID, operationID: UUID, provider: String, accountID: String, fileID: String,
                     preferenceFingerprint: Data, intendedPreferenceFingerprint: Data?, alternatePreferenceFingerprint: Data? = nil, baseline: LocalCommitBaseline) {
            self.version = version; self.databaseID = databaseID; self.operationID = operationID
            self.provider = provider; self.accountID = accountID; self.fileID = fileID
            self.preferenceFingerprint = preferenceFingerprint; self.intendedPreferenceFingerprint = intendedPreferenceFingerprint; self.baseline = baseline
            self.alternatePreferenceFingerprint = alternatePreferenceFingerprint
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? container.decode(Int.self, forKey: .version)) ?? 0
            if version == 1 {
                databaseID = try? container.decode(UUID.self, forKey: .databaseID)
                operationID = try? container.decode(UUID.self, forKey: .operationID)
                provider = try? container.decode(String.self, forKey: .provider)
                accountID = try? container.decode(String.self, forKey: .accountID)
                fileID = try? container.decode(String.self, forKey: .fileID)
                preferenceFingerprint = try? container.decode(Data.self, forKey: .preferenceFingerprint)
                intendedPreferenceFingerprint = try? container.decode(Data.self, forKey: .intendedPreferenceFingerprint)
                alternatePreferenceFingerprint = try? container.decode(Data.self, forKey: .alternatePreferenceFingerprint)
                baseline = try? container.decode(LocalCommitBaseline.self, forKey: .baseline)
            } else {
                databaseID = nil; operationID = nil; provider = nil; accountID = nil; fileID = nil
                preferenceFingerprint = nil; intendedPreferenceFingerprint = nil; alternatePreferenceFingerprint = nil; baseline = nil
            }
        }

        var isRecognized: Bool {
            version == 1 && databaseID != nil && operationID != nil && provider != nil && accountID != nil
                && fileID != nil && preferenceFingerprint != nil && baseline != nil
        }

        private struct Preferences: Encodable {
            let targetBookmark: Data?
            let keyFileBookmark: Data?
            let keyFileFilename: String?
            let hardwareKey: HardwareKeyConfiguration?
            let legacyKeychainFilename: String?
            let isReadOnly: Bool
        }

        static func capture(reference: DatabaseReference, operationID: UUID, keyChange: KeyChange? = nil) throws -> JournalBinding {
            guard let metadata = reference.cloudSyncMetadata else { throw SaveError.saveContextUnavailable }
            let preferences = Preferences(targetBookmark: reference.bookmarkData, keyFileBookmark: reference.keyFileBookmarkData,
                                          keyFileFilename: reference.keyFileFilename, hardwareKey: reference.hardwareKey,
                                          legacyKeychainFilename: reference.legacyKeychainFilename, isReadOnly: reference.isReadOnly)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var intended = reference
            if let keyChange {
                intended.keyFileBookmarkData = keyChange.keyFileBookmarkData
                intended.keyFileFilename = keyChange.keyFileFilename
            }
            let intendedPreferences = Preferences(targetBookmark: intended.bookmarkData, keyFileBookmark: intended.keyFileBookmarkData,
                keyFileFilename: intended.keyFileFilename, hardwareKey: intended.hardwareKey,
                legacyKeychainFilename: intended.legacyKeychainFilename, isReadOnly: intended.isReadOnly)
            return JournalBinding(version: 1, databaseID: reference.id, operationID: operationID,
                                  provider: metadata.provider, accountID: metadata.accountId, fileID: metadata.fileId,
                                  preferenceFingerprint: FileDigest.sha512(try encoder.encode(preferences)),
                                  intendedPreferenceFingerprint: keyChange == nil ? nil : FileDigest.sha512(try encoder.encode(intendedPreferences)),
                                  baseline: LocalCommitBaseline(reference: reference))
        }

        func matchesOriginal(reference: DatabaseReference, operationID: UUID) -> Bool {
            guard version == 1, let candidate = try? Self.capture(reference: reference, operationID: operationID) else { return false }
            return matchesAuthority(reference: reference, operationID: operationID) && baseline == candidate.baseline
        }

        func matchesInstalled(reference: DatabaseReference, operationID: UUID, keyChange: KeyChange, committedAt: Date) -> Bool {
            guard isRecognized, let intendedPreferenceFingerprint,
                  let candidate = try? Self.capture(reference: reference, operationID: operationID),
                  databaseID == candidate.databaseID, self.operationID == candidate.operationID,
                  provider == candidate.provider, accountID == candidate.accountID, fileID == candidate.fileID,
                  intendedPreferenceFingerprint == candidate.preferenceFingerprint,
                  reference.cloudSyncMetadata?.localHeadOperationID == operationID,
                  reference.cloudSyncMetadata?.keyEpoch == keyChange.epoch,
                  reference.keyFileBookmarkData == keyChange.keyFileBookmarkData,
                  reference.keyFileFilename == keyChange.keyFileFilename,
                  reference.lastMasterKeyChangeAt == committedAt else { return false }
            return true
        }

        func matchesOrdinaryAuthority(reference: DatabaseReference, operationID: UUID) -> Bool {
            if matchesAuthority(reference: reference, operationID: operationID) { return true }
            guard reference.isReadOnly else { return false }
            var writable = reference
            writable.isReadOnly = false
            return matchesAuthority(reference: writable, operationID: operationID)
        }

        func matchesAuthority(reference: DatabaseReference, operationID: UUID) -> Bool {
            guard version == 1, let candidate = try? Self.capture(reference: reference, operationID: operationID) else { return false }
            return databaseID == candidate.databaseID && self.operationID == candidate.operationID
                && provider == candidate.provider && accountID == candidate.accountID && fileID == candidate.fileID
                && (preferenceFingerprint == candidate.preferenceFingerprint || alternatePreferenceFingerprint == candidate.preferenceFingerprint)
                && baseline?.keyEpoch == candidate.baseline?.keyEpoch
                && baseline?.lastMasterKeyChangeAt == candidate.baseline?.lastMasterKeyChangeAt
        }

        func authorizingPreferenceChange(from current: DatabaseReference, to desired: DatabaseReference,
                                         operationID: UUID) throws -> JournalBinding {
            var unchanged = desired
            unchanged.keyFileBookmarkData = current.keyFileBookmarkData
            unchanged.keyFileFilename = current.keyFileFilename
            var boundCurrent = current
            var boundDesired = desired
            if !matchesAuthority(reference: current, operationID: operationID), current.isReadOnly {
                boundCurrent.isReadOnly = false
                boundDesired.isReadOnly = false
            }
            guard unchanged == current, matchesAuthority(reference: boundCurrent, operationID: operationID),
                  let baseline, let databaseID, let provider, let accountID, let fileID,
                  let currentFingerprint = try Self.capture(reference: boundCurrent, operationID: operationID).preferenceFingerprint,
                  let desiredFingerprint = try Self.capture(reference: boundDesired, operationID: operationID).preferenceFingerprint else {
                throw SaveError.saveContextUnavailable
            }
            return JournalBinding(version: version, databaseID: databaseID, operationID: operationID,
                provider: provider, accountID: accountID, fileID: fileID, preferenceFingerprint: currentFingerprint,
                intendedPreferenceFingerprint: intendedPreferenceFingerprint, alternatePreferenceFingerprint: desiredFingerprint, baseline: baseline)
        }

        func finalizingPreferenceChange(reference: DatabaseReference, operationID: UUID) throws -> JournalBinding {
            var bound = reference
            if !matchesAuthority(reference: bound, operationID: operationID), bound.isReadOnly { bound.isReadOnly = false }
            guard matchesAuthority(reference: bound, operationID: operationID), let baseline, let databaseID,
                  let provider, let accountID, let fileID,
                  let fingerprint = try Self.capture(reference: bound, operationID: operationID).preferenceFingerprint,
                  alternatePreferenceFingerprint != nil else { throw SaveError.saveContextUnavailable }
            return JournalBinding(version: version, databaseID: databaseID, operationID: operationID,
                provider: provider, accountID: accountID, fileID: fileID, preferenceFingerprint: fingerprint,
                intendedPreferenceFingerprint: intendedPreferenceFingerprint, baseline: baseline)
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
        /// Recorded remote ancestry; legacy markers decode nil and never gain byte identity from it.
        var baseRev: String?

        var journalVersion: Int?
        var localCommitBaseline: LocalCommitBaseline?
        var attemptIsFenced: Bool?
        var uploadRecoveryIssue: CloudSyncIssue?
        var observedUploadRevision: String?
        var detachedFilename: String?
        var discardRequested: Bool?
        var requiresLocalRecovery: Bool?
        var absorbedOperationIDs: [UUID]?
        var predecessorSHA512: Data?
        var predecessorOperationID: UUID?
        var remoteBaseSHA512: Data?
        var intendedPayloadSHA512: Data?
        var intendedPayloadPath: String?
        var keyEpoch: UUID?
        var keyChange: KeyChange?
        var binding: JournalBinding?
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
            journalVersion = try container.decodeIfPresent(Int.self, forKey: .journalVersion)
            localCommitBaseline = try container.decodeIfPresent(LocalCommitBaseline.self, forKey: .localCommitBaseline)
            attemptIsFenced = try container.decodeIfPresent(Bool.self, forKey: .attemptIsFenced)
            uploadRecoveryIssue = try container.decodeIfPresent(CloudSyncIssue.self, forKey: .uploadRecoveryIssue)
            observedUploadRevision = try container.decodeIfPresent(String.self, forKey: .observedUploadRevision)
            detachedFilename = try container.decodeIfPresent(String.self, forKey: .detachedFilename)
            discardRequested = try container.decodeIfPresent(Bool.self, forKey: .discardRequested)
            requiresLocalRecovery = try container.decodeIfPresent(Bool.self, forKey: .requiresLocalRecovery)
            absorbedOperationIDs = try container.decodeIfPresent([UUID].self, forKey: .absorbedOperationIDs)
            predecessorSHA512 = try container.decodeIfPresent(Data.self, forKey: .predecessorSHA512)
            predecessorOperationID = try container.decodeIfPresent(UUID.self, forKey: .predecessorOperationID)
            remoteBaseSHA512 = try container.decodeIfPresent(Data.self, forKey: .remoteBaseSHA512)
            intendedPayloadSHA512 = try container.decodeIfPresent(Data.self, forKey: .intendedPayloadSHA512)
            intendedPayloadPath = try container.decodeIfPresent(String.self, forKey: .intendedPayloadPath)
            keyEpoch = try container.decodeIfPresent(UUID.self, forKey: .keyEpoch)
            keyChange = try container.decodeIfPresent(KeyChange.self, forKey: .keyChange)
            binding = try container.decodeIfPresent(JournalBinding.self, forKey: .binding)
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

    static func hasBoundAuthority(_ stored: StoredMarker, reference: DatabaseReference) -> Bool {
        guard let binding = stored.marker.binding, binding.isRecognized,
              binding.databaseID == stored.marker.databaseId, binding.operationID == stored.id,
              binding.baseline == stored.marker.localCommitBaseline else { return false }
        return stored.marker.keyChange == nil
            ? binding.matchesOrdinaryAuthority(reference: reference, operationID: stored.id)
            : binding.matchesAuthority(reference: reference, operationID: stored.id)
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
        var observedCommitLockFailure: @Sendable (Int32) -> Void = { _ in }
        var synchronizeRetirementDirectory: @Sendable (URL) throws -> Void = { try synchronizeDirectory($0) }

        static let live = Environment(
            appGroupContainerURL: { AppGroupContainer.url },
            createDirectory: { url in
                guard let anchor = AppGroupContainer.resolvedURL else { throw CocoaError(.fileWriteNoPermission) }; try createDurableDirectory(at: url, anchor: anchor)
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

    private static func journalDirectories(for databaseID: UUID?, environment: Environment) throws -> [URL] {
        let root = queueRootURL(environment: environment)
        let directories: [URL]
        do { directories = try environment.listDirectory(root) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let parent = try environment.listDirectory(root.deletingLastPathComponent())
            guard !parent.contains(where: { $0.lastPathComponent == root.lastPathComponent }) else { throw error }
            return []
        }
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        return directories.filter { databaseID == nil || $0.lastPathComponent == databaseID?.uuidString }
    }

    static func readJournal(for databaseID: UUID? = nil, excluding excludedIDs: Set<UUID> = [],
                            environment: Environment = .live) throws -> [StoredMarker] {
        let directories = try journalDirectories(for: databaseID, environment: environment)
            .filter { UUID(uuidString: $0.lastPathComponent).map { !excludedIDs.contains($0) } ?? false }
        var records: [StoredMarker] = []
        for folder in directories {
            for file in try environment.listDirectory(folder) where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw CocoaError(.fileReadCorruptFile) }
                let marker = try environment.decodeMarker(environment.readData(file))
                guard marker.databaseId.uuidString == folder.lastPathComponent,
                      CloudJournalDecision.state(of: marker) != .invalid else { throw CocoaError(.fileReadCorruptFile) }
                records.append(StoredMarker(id: id, fileURL: file, marker: marker))
            }
        }
        return records.sorted { $0.marker.createdAt == $1.marker.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.marker.createdAt < $1.marker.createdAt }
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
            guard (current.journalVersion == nil && current.binding == nil) || current.binding?.isRecognized == true else { return false }
            guard current.uploadAttemptID == nil || current.attemptIsFenced == true || current.confirmedAt != nil else { return false }
            do {
                try environment.removeItem(storedMarker.fileURL)
                try environment.synchronizeRetirementDirectory(storedMarker.fileURL.deletingLastPathComponent())
            } catch {
                try? environment.writeMarkerAtomically(data, storedMarker.fileURL)
                throw error
            }
            let payload = queueDirectoryURL(for: current.databaseId, environment: environment)
                .appendingPathComponent(storedMarker.id.uuidString + ".kdbx")
            if current.intendedPayloadPath == (try makeRelativeAppGroupPath(for: payload, environment: environment)),
               !listMarkers(for: current.databaseId, environment: environment).contains(where: { $0.marker.intendedPayloadPath == current.intendedPayloadPath }) {
                try? environment.removeItem(payload)
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
            guard current.binding == nil || current.binding?.isRecognized == true else { throw UpdateError.markerChanged }
            var updated = storedMarker
            updated.marker.generation += 1
            try persist(updated, environment: environment)
            return updated
        }
    }

    /// Finalization rereads the current generation so an intervening conflict update cannot strand the payload.
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
                  current.binding == nil || current.binding?.isRecognized == true,
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
    /// Confirmed journals stay with delivery until local durability is established.
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
            && storedMarker.marker.binding?.isRecognized == true
            && storedMarker.marker.confirmedAt == nil
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

    static func readImmutablePayload(_ stored: StoredMarker, environment: Environment = .live) throws -> Data {
        let expected = queueDirectoryURL(for: stored.marker.databaseId, environment: environment)
            .appendingPathComponent(stored.id.uuidString + ".kdbx")
        guard stored.marker.intendedPayloadPath == (try makeRelativeAppGroupPath(for: expected, environment: environment)),
              let sha = stored.marker.intendedPayloadSHA512 else { throw SaveError.saveContextUnavailable }
        let bytes = try environment.readData(expected)
        guard FileDigest.sha512(bytes) == sha else { throw SaveError.saveContextUnavailable }
        return bytes
    }

    /// Caller holds commit and reference authority through the exact source handoff.
    static func transferMergedSourcesLocked(_ sources: [StoredMarker], toPayloadSHA512 sha: Data,
        reference current: DatabaseReference, environment: Environment = .live,
        onStage: (String) -> Void = { _ in }) throws {
        onStage("transfer-owner-proof")
        let databaseID = current.id
        guard var owner = try readJournal(for: databaseID, environment: environment).last(where: {
            $0.marker.isPayloadFinalized == true && $0.marker.intendedPayloadSHA512 == sha && $0.marker.intendedPayloadPath != nil
        }) else { throw SaveError.saveContextUnavailable }
        guard hasBoundAuthority(owner, reference: current),
              current.cloudSyncMetadata?.localHeadOperationID == owner.id,
              current.cloudSyncMetadata?.keyEpoch == owner.marker.keyEpoch,
              owner.marker.localCommitBaseline?.hasCompatibleEpoch(current) == true,
              FileDigest.sha512(try environment.readData(DatabaseListStore.cacheLocation(for: current))) == sha,
              let path = owner.marker.intendedPayloadPath,
              FileDigest.sha512(try environment.readData(resolveAppGroupURL(for: path, environment: environment))) == sha else {
            throw SaveError.saveContextUnavailable
        }
        let journal = try readJournal(for: databaseID, environment: environment)
        for source in sources where source.id != owner.id {
            guard source.marker.confirmedAt == nil,
                  source.marker.uploadAttemptID == nil || source.marker.attemptIsFenced == true,
                  journal.contains(where: { $0.id == source.id && $0.marker == source.marker }),
                  FileDigest.sha512(try readImmutablePayload(source, environment: environment)) == source.marker.intendedPayloadSHA512 else {
                throw SaveError.saveContextUnavailable
            }
        }
        onStage("transfer-update")
        owner.marker.absorbedOperationIDs = Array(Set((owner.marker.absorbedOperationIDs ?? []) + sources.map(\.id)))
        owner = try update(owner, environment: environment)
        for source in sources where source.id != owner.id {
            onStage("transfer-drop-sync")
            guard try dropIfUnchanged(source, environment: environment) else { throw SaveError.saveContextUnavailable }
        }
    }

    /// Serializes the local journal/cache/head transaction across app and extension processes.
    static func withCommitLock<T>(for databaseID: UUID, environment: Environment = .live, nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
        let directory = environment.appGroupContainerURL().appendingPathComponent("pending-upload-locks", isDirectory: true)
        try environment.createDirectory(directory)
        let lockURL = directory.appendingPathComponent(databaseID.uuidString + ".commit.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, nonBlocking ? LOCK_EX | LOCK_NB : LOCK_EX) == 0 else {
            let failureErrno = errno
            environment.observedCommitLockFailure(failureErrno)
            throw POSIXError(.EWOULDBLOCK)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func hasRekeyJournal(for databaseID: UUID, environment: Environment = .live) -> Bool {
        (try? readJournal(for: databaseID, environment: environment).contains { $0.marker.keyChange != nil }) ?? true
    }

    /// The caller holds the commit lock until cache replacement and head publication finish.
    static func prepare(
        reference: DatabaseReference, currentData: Data, intendedData: Data,
        cacheURL: URL, keyChange: KeyChange? = nil,
        remoteBaseSHA512: Data? = nil, authenticatedMergeSources: [StoredMarker]? = nil,
        operationID: UUID = UUID(), environment: Environment = .live
    ) throws -> StoredMarker {
        let binding = try JournalBinding.capture(reference: reference, operationID: operationID, keyChange: keyChange)
        guard let current = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == reference.id }),
              current.isCloudBacked,
              binding.matchesOriginal(reference: current, operationID: operationID) else {
            throw SaveError.saveContextUnavailable
        }
        try recoverLocalCommits(for: reference.id, environment: environment)
        guard let afterRecovery = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == reference.id }),
              binding.matchesOriginal(reference: afterRecovery, operationID: operationID) else {
            throw SaveError.saveContextUnavailable
        }
        try preserveLegacyPayloads(for: reference, environment: environment)
        let currentSHA = FileDigest.sha512(currentData)
        let markers = try readJournal(for: reference.id, environment: environment).map { try recoverPrepared($0, environment: environment) }
        guard CloudJournalDecision.permitsMutation(markers.map(\.marker), changingKey: keyChange != nil),
              !markers.contains(where: { $0.marker.journalVersion == nil })
                || (authenticatedMergeSources?.count == markers.count && markers.allSatisfy { marker in
                    authenticatedMergeSources?.contains(where: { $0.id == marker.id && $0.marker == marker.marker }) == true
                        && CloudJournalDecision.permitsAuthenticatedMergeSource(marker, reference: reference)
                }) else {
            throw SaveError.saveContextUnavailable
        }
        if let keyChange {
            guard markers.isEmpty, keyChange.epoch != reference.cloudSyncMetadata?.keyEpoch else {
                throw SaveError.saveContextUnavailable
            }
        }
        let predecessor = markers.last { $0.marker.isPayloadFinalized == true && $0.marker.openTimeSHA512 == currentSHA }
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
        marker.journalVersion = 1
        marker.localCommitBaseline = LocalCommitBaseline(reference: reference)
        marker.predecessorSHA512 = currentSHA
        marker.predecessorOperationID = predecessor?.id
        marker.remoteBaseSHA512 = remoteBaseSHA512 ?? predecessor?.marker.remoteBaseSHA512 ?? (predecessor == nil ? currentSHA : nil)
        if remoteBaseSHA512 != nil {
            // A reconciled byte baseline is not evidence binding the prior reference's remote validators.
            marker.expectedRev = nil
            marker.baseRev = nil
        }
        marker.intendedPayloadSHA512 = FileDigest.sha512(intendedData)
        marker.intendedPayloadPath = try makeRelativeAppGroupPath(for: payloadURL, environment: environment)
        marker.keyEpoch = keyChange?.epoch ?? reference.cloudSyncMetadata?.keyEpoch
        marker.keyChange = keyChange
        marker.binding = binding
        let stored = StoredMarker(id: operationID, fileURL: directory.appendingPathComponent("\(operationID.uuidString).json"), marker: marker)
        try persist(stored, environment: environment)
        return stored
    }

    /// Caller holds the commit lock before replacing cache or rotating ordinary backups.
    static func preserveLegacyPayloads(for reference: DatabaseReference, environment: Environment = .live) throws {
        let backups = DatabaseListStore.recentBackups(for: reference)
        for stored in try readJournal(for: reference.id, environment: environment)
        where stored.marker.journalVersion == nil && stored.marker.isPayloadFinalized == true
            && stored.marker.intendedPayloadPath == nil && stored.marker.binding == nil {
            let candidates = [resolveAppGroupURL(for: stored.marker.encryptedBytesCacheURL, environment: environment)] + backups
            guard let bytes = candidates.lazy.compactMap({ try? environment.readData($0) })
                .first(where: { FileDigest.sha512($0) == stored.marker.openTimeSHA512 }) else { continue }
            let payloadURL = stored.fileURL.deletingPathExtension().appendingPathExtension("kdbx")
            try environment.writeMarkerAtomically(bytes, payloadURL)
            var promoted = stored
            promoted.marker.remoteBaseSHA512 = nil
            promoted.marker.intendedPayloadSHA512 = stored.marker.openTimeSHA512
            promoted.marker.intendedPayloadPath = try makeRelativeAppGroupPath(for: payloadURL, environment: environment)
            // A stale generation aborts the caller's replacement/prune instead of publishing stale ownership.
            _ = try update(promoted, environment: environment)
        }
    }

    /// Only new journals contain enough evidence to recover an interrupted finalization.
    static func recoverPrepared(_ stored: StoredMarker, environment: Environment = .live) throws -> StoredMarker {
        guard stored.marker.isPayloadFinalized == false,
              stored.marker.keyChange == nil,
              let binding = stored.marker.binding, binding.isRecognized,
              binding.databaseID == stored.marker.databaseId, binding.operationID == stored.id,
              binding.baseline == stored.marker.localCommitBaseline,
              let current = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == stored.marker.databaseId }),
              binding.matchesAuthority(reference: current, operationID: stored.id),
              (current.cloudSyncMetadata?.localHeadOperationID == binding.baseline?.headOperationID || current.cloudSyncMetadata?.localHeadOperationID == stored.id),
              let intendedSHA = stored.marker.intendedPayloadSHA512,
              let path = stored.marker.intendedPayloadPath,
              FileDigest.sha512(try environment.readData(resolveAppGroupURL(for: path, environment: environment))) == intendedSHA else {
            return stored
        }
        if FileDigest.sha512(try environment.readData(resolveAppGroupURL(for: stored.marker.encryptedBytesCacheURL, environment: environment))) == intendedSHA {
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

    /// Caller holds the commit lock. This never restores cache or publishes rekey state.
    static func recoverLocalCommit(
        _ snapshot: StoredMarker, environment: Environment = .live
    ) throws -> DatabaseListStore.CloudMetadataUpdateResult? {
        guard let stored = try readJournal(for: snapshot.marker.databaseId, environment: environment).first(where: { $0.id == snapshot.id }),
              stored.marker == snapshot.marker,
              stored.marker.keyChange == nil,
              stored.marker.isPayloadFinalized == true,
              let baseline = stored.marker.localCommitBaseline,
              let binding = stored.marker.binding, binding.isRecognized,
              binding.databaseID == stored.marker.databaseId, binding.operationID == stored.id,
              binding.baseline == baseline,
              stored.marker.keyEpoch == baseline.keyEpoch,
              let intendedSHA = stored.marker.intendedPayloadSHA512,
              stored.marker.openTimeSHA512 == intendedSHA,
              let path = stored.marker.intendedPayloadPath,
              let payload = try? environment.readData(resolveAppGroupURL(for: path, environment: environment)),
              FileDigest.sha512(payload) == intendedSHA else { return nil }
        let cache = try? environment.readData(resolveAppGroupURL(for: stored.marker.encryptedBytesCacheURL, environment: environment))
        if cache.map(FileDigest.sha512) == intendedSHA {
            if let current = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == stored.marker.databaseId }),
               binding.matchesAuthority(reference: current, operationID: stored.id),
               baseline.hasCompatibleEpoch(current),
               current.cloudSyncMetadata?.localHeadOperationID != stored.id,
               current.cloudSyncMetadata?.localHeadOperationID != baseline.headOperationID,
               let descendant = localDescendantOwner(of: stored, reference: current, environment: environment) {
                // Replaying an ancestor must prove the existing head durable, never roll it back.
                guard let descendantBinding = descendant.marker.binding else { return nil }
                return DatabaseListStore.publishCloudLocalCommit(for: current.id, operationID: descendant.id, binding: descendantBinding)
            }
            return DatabaseListStore.publishCloudLocalCommit(for: stored.marker.databaseId, operationID: stored.id, binding: binding)
        }
        guard let current = try DatabaseListStore.readDatabasesStrict().first(where: { $0.id == stored.marker.databaseId }),
              binding.matchesAuthority(reference: current, operationID: stored.id),
              current.cloudSyncMetadata?.localHeadOperationID == stored.id else { return nil }
        guard baseline.hasCompatibleEpoch(current) else { return .mismatch(current) }
        // Reconfirm only this already-visible head; cache restoration still needs confirmed-owner proof.
        return DatabaseListStore.publishCloudLocalCommit(for: current.id, operationID: stored.id, binding: binding)
    }

    /// Caller holds the commit lock. Every hop must still own its exact immutable ciphertext.
    static func localDescendantOwner(
        of ancestor: StoredMarker, reference: DatabaseReference, environment: Environment = .live
    ) -> StoredMarker? {
        guard let markers = try? readJournal(for: reference.id, environment: environment) else { return nil }
        func verified(_ stored: StoredMarker) -> Bool {
            guard stored.marker.databaseId == reference.id, stored.marker.isPayloadFinalized == true,
                  stored.marker.keyChange == nil, stored.marker.keyEpoch == reference.cloudSyncMetadata?.keyEpoch,
                  let binding = stored.marker.binding, binding.isRecognized,
                  binding.databaseID == stored.marker.databaseId, binding.operationID == stored.id,
                  binding.baseline == stored.marker.localCommitBaseline,
                  binding.matchesOrdinaryAuthority(reference: reference, operationID: stored.id),
                  let sha = stored.marker.intendedPayloadSHA512, stored.marker.openTimeSHA512 == sha,
                  let path = stored.marker.intendedPayloadPath,
                  let bytes = try? environment.readData(resolveAppGroupURL(for: path, environment: environment)) else { return false }
            return FileDigest.sha512(bytes) == sha
        }
        guard let head = markers.first(where: { $0.id == reference.cloudSyncMetadata?.localHeadOperationID }),
              verified(head) else { return nil }
        var remaining = [head]
        var visited = Set<UUID>()
        while let child = remaining.popLast() {
            guard visited.insert(child.id).inserted else { continue }
            if child.id == ancestor.id { return child.marker == ancestor.marker ? head : nil }
            for parent in markers {
                let predecessor = child.marker.predecessorOperationID == parent.id
                    && child.marker.predecessorSHA512 == parent.marker.intendedPayloadSHA512
                    && child.marker.binding?.baseline?.headOperationID == parent.id
                let absorbed = child.marker.absorbedOperationIDs?.contains(parent.id) == true
                if (predecessor || absorbed), verified(parent) { remaining.append(parent) }
            }
        }
        return nil
    }

    /// Caller holds the commit lock; marker and list locks are acquired only inside it.
    static func recoverLocalCommits(for databaseID: UUID, environment: Environment = .live) throws {
        for snapshot in try readJournal(for: databaseID, environment: environment) {
            if snapshot.marker.journalVersion != nil { _ = try readImmutablePayload(snapshot, environment: environment) }
            let stored = try recoverPrepared(snapshot, environment: environment)
            switch try recoverLocalCommit(stored, environment: environment) {
            case .published, nil: break
            case .mismatch, .removed, .writeFailed, .visibleUnconfirmed: throw SaveError.saveContextUnavailable
            }
        }
    }

    /// A remote divergence affects the whole local lineage, including descendants not attempted yet.
    static func markDatabaseConflicted(for databaseID: UUID, environment: Environment = .live) throws {
        for stored in try readJournal(for: databaseID, environment: environment) where !stored.marker.isConflicted {
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

// Creation journals are isolated from replacement markers and never grant delivery authority.
extension PendingUploadQueue {
    struct CreationIntent: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case prepared, attempting, confirmed, completed }
        let version: Int
        let operationID: UUID
        let provider: String
        let accountID: String
        let target: String
        let payloadSHA512: Data
        let referenceTemplate: DatabaseReference
        let isConflictCopy: Bool
        let conflictBatchID: UUID?
        var phase: Phase
        var receipt: DatabaseReference?
    }

    struct StoredCreation: Sendable {
        let intent: CreationIntent
        let serialized: Data
    }

    enum CreationError: LocalizedError {
        case invalid, reserved, changed

        var errorDescription: String? {
            switch self {
            case .invalid, .changed:
                String(localized: "The cloud recovery record is unavailable or has changed. Keep your encrypted copies and reopen Cloud Recovery.")
            case .reserved:
                String(localized: "A cloud creation for this location is already awaiting recovery. Open Cloud Recovery.")
            }
        }
    }

    private static func creationDirectory(_ environment: Environment) -> URL {
        environment.appGroupContainerURL().appendingPathComponent("cloud-creation-journal", isDirectory: true)
    }

    private static func creationURL(_ id: UUID, _ environment: Environment) -> URL {
        creationDirectory(environment).appendingPathComponent(id.uuidString + ".creation")
    }

    static func creationPayloadURL(_ id: UUID, _ environment: Environment) -> URL {
        creationDirectory(environment).appendingPathComponent(id.uuidString + ".kdbx")
    }

    static func creationStageURL(_ id: UUID, _ environment: Environment) -> URL {
        creationDirectory(environment).appendingPathComponent(id.uuidString + ".stage")
    }

    private static func decodeCreation(_ data: Data, id: UUID) throws -> CreationIntent {
        let value = try JSONDecoder().decode(CreationIntent.self, from: data)
        guard value.version == 1, value.operationID == id, value.payloadSHA512.count == 64,
              !value.provider.isEmpty, !value.accountID.isEmpty, !value.target.isEmpty,
              value.isConflictCopy || value.conflictBatchID == nil,
              (value.phase == .prepared || value.phase == .attempting) == (value.receipt == nil),
              value.receipt == nil || value.receipt?.id == value.referenceTemplate.id else { throw CreationError.invalid }
        if let receipt = value.receipt {
            guard receiptMatches(receipt, intent: value) else { throw CreationError.invalid }
        }
        return value
    }

    private static func receiptMatches(_ receipt: DatabaseReference, intent: CreationIntent) -> Bool {
        guard let metadata = receipt.cloudSyncMetadata, metadata.provider == intent.provider,
              metadata.accountId == intent.accountID, !metadata.fileId.isEmpty else { return false }
        var original = receipt
        original.source = intent.referenceTemplate.source
        guard original == intent.referenceTemplate else { return false }
        return metadata.localHeadOperationID == intent.operationID
    }

    static func listCreations(environment: Environment = .live) throws -> [StoredCreation] {
        let directory = creationDirectory(environment)
        try environment.createDirectory(directory)
        return try environment.listDirectory(directory).filter { $0.pathExtension == "creation" }.map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw CreationError.invalid }
            let data = try environment.readData(url)
            return StoredCreation(intent: try decodeCreation(data, id: id), serialized: data)
        }
    }

    struct CreationRecoveryListing: Sendable {
        let records: [StoredCreation]
        let hasUnreadableRecords: Bool
    }

    static func readCreation(_ id: UUID, environment: Environment = .live) throws -> StoredCreation {
        let data = try environment.readData(creationURL(id, environment))
        return StoredCreation(intent: try decodeCreation(data, id: id), serialized: data)
    }

    static func listCreationsForRecovery(environment: Environment = .live) throws -> CreationRecoveryListing {
        let directory = creationDirectory(environment)
        try environment.createDirectory(directory)
        var records: [StoredCreation] = []
        var unreadable = false
        for url in try environment.listDirectory(directory) where url.pathExtension == "creation" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                unreadable = true
                continue
            }
            do { records.append(try readCreation(id, environment: environment)) }
            catch { unreadable = true }
        }
        return CreationRecoveryListing(records: records, hasUnreadableRecords: unreadable)
    }

    private static func withCreationLock<T>(_ name: String, environment: Environment, _ body: () throws -> T) throws -> T {
        let directory = environment.appGroupContainerURL().appendingPathComponent("cloud-creation-locks", isDirectory: true)
        try environment.createDirectory(directory)
        let fd = Darwin.open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func targetLockName(_ intent: CreationIntent) throws -> String {
        let encoder = JSONEncoder()
        let bytes = try encoder.encode([intent.provider, intent.accountID, intent.target])
        return FileDigest.sha512(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func withCreationLocks<T>(_ intent: CreationIntent, environment: Environment, _ body: () throws -> T) throws -> T {
        try withCreationLock("target-" + targetLockName(intent), environment: environment) {
            try withCreationLock("operation-" + intent.operationID.uuidString, environment: environment, body)
        }
    }

    static func prepareCreation(operationID: UUID, provider: String, accountID: String, target: String,
                                payload: Data, referenceTemplate: DatabaseReference, isConflictCopy: Bool,
                                conflictBatchID: UUID? = nil, environment: Environment = .live) throws -> StoredCreation {
        let intent = CreationIntent(version: 1, operationID: operationID, provider: provider, accountID: accountID,
                                    target: target, payloadSHA512: FileDigest.sha512(payload), referenceTemplate: referenceTemplate,
                                    isConflictCopy: isConflictCopy, conflictBatchID: conflictBatchID, phase: .prepared, receipt: nil)
        return try withCreationLocks(intent, environment: environment) {
            let records = try listCreations(environment: environment)
            guard !records.contains(where: { $0.intent.operationID == operationID }) else { throw CreationError.changed }
            guard !records.contains(where: { $0.intent.phase != .completed && $0.intent.provider == provider && $0.intent.accountID == accountID && $0.intent.target == target }) else { throw CreationError.reserved }
            let payloadURL = creationPayloadURL(operationID, environment)
            guard !(try environment.listDirectory(creationDirectory(environment))).contains(where: { $0.lastPathComponent == payloadURL.lastPathComponent }) else { throw CreationError.changed }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(intent)
            _ = try decodeCreation(data, id: operationID)
            let stageURL = creationStageURL(operationID, environment)
            guard !(try environment.listDirectory(creationDirectory(environment))).contains(where: { $0.lastPathComponent == stageURL.lastPathComponent }) else { throw CreationError.changed }
            try environment.writeMarkerAtomically(payload, payloadURL)
            try environment.writeMarkerAtomically(payload, stageURL)
            try environment.writeMarkerAtomically(data, creationURL(operationID, environment))
            return StoredCreation(intent: intent, serialized: data)
        }
    }

    static func readCreationPayload(_ stored: StoredCreation, environment: Environment = .live) throws -> Data {
        let bytes = try environment.readData(creationPayloadURL(stored.intent.operationID, environment))
        guard FileDigest.sha512(bytes) == stored.intent.payloadSHA512 else { throw CreationError.invalid }
        return bytes
    }

    static func withConfirmedCreation<T>(_ stored: StoredCreation, environment: Environment = .live, _ body: () throws -> T) throws -> T {
        try withCreationLocks(stored.intent, environment: environment) {
            guard stored.intent.phase == .confirmed,
                  try environment.readData(creationURL(stored.intent.operationID, environment)) == stored.serialized,
                  try decodeCreation(stored.serialized, id: stored.intent.operationID) == stored.intent else { throw CreationError.changed }
            return try body()
        }
    }

    static func discardPreparedCreation(_ stored: StoredCreation, environment: Environment = .live) throws {
        try withCreationLocks(stored.intent, environment: environment) {
            let id = stored.intent.operationID
            let markerURL = creationURL(id, environment)
            guard stored.intent.phase == .prepared,
                  try environment.readData(markerURL) == stored.serialized,
                  try decodeCreation(stored.serialized, id: id) == stored.intent else { throw CreationError.changed }
            do {
                try environment.removeItem(markerURL)
                try environment.synchronizeRetirementDirectory(markerURL.deletingLastPathComponent())
            } catch {
                try? environment.writeMarkerAtomically(stored.serialized, markerURL)
                throw error
            }
            try? environment.removeItem(creationPayloadURL(id, environment))
            try? environment.removeItem(creationStageURL(id, environment))
        }
    }

    // Reconfirm a completed receipt before removing copies left by an interrupted cleanup.
    static func cleanCompletedCreationPayloads(environment: Environment = .live) throws {
        for stored in try listCreations(environment: environment) where stored.intent.phase == .completed {
            try withCreationLocks(stored.intent, environment: environment) {
                let id = stored.intent.operationID
                let markerURL = creationURL(id, environment)
                guard try environment.readData(markerURL) == stored.serialized,
                      try decodeCreation(stored.serialized, id: id) == stored.intent else { return }
                try environment.writeMarkerAtomically(stored.serialized, markerURL)
                try? environment.removeItem(creationPayloadURL(id, environment))
                try? environment.removeItem(creationStageURL(id, environment))
            }
        }
    }

    static func cleanCompletedConflictCopyAttempts(environment: Environment = .live) throws {
        let records = try listCreations(environment: environment)
        for completed in records where completed.intent.phase == .completed && completed.intent.isConflictCopy {
            guard let batch = completed.intent.conflictBatchID else { continue }
            let confirmed = try withCreationLocks(completed.intent, environment: environment) {
                let url = creationURL(completed.intent.operationID, environment)
                guard try environment.readData(url) == completed.serialized,
                      try decodeCreation(completed.serialized, id: completed.intent.operationID) == completed.intent else { return false }
                try environment.writeMarkerAtomically(completed.serialized, url)
                return true
            }
            guard confirmed else { continue }
            for candidate in records where candidate.intent.phase == .prepared && candidate.intent.isConflictCopy
                && candidate.intent.conflictBatchID == batch && candidate.intent.provider == completed.intent.provider
                && candidate.intent.accountID == completed.intent.accountID && candidate.intent.payloadSHA512 == completed.intent.payloadSHA512 {
                try? discardPreparedCreation(candidate, environment: environment)
            }
        }
    }

    // Only the invocation with affirmative no-commit proof may unwind its exact attempt.
    static func restoreCreationAfterNoCommit(_ stored: StoredCreation, environment: Environment = .live) throws -> StoredCreation {
        try withCreationLocks(stored.intent, environment: environment) {
            guard stored.intent.phase == .attempting,
                  try environment.readData(creationURL(stored.intent.operationID, environment)) == stored.serialized,
                  try decodeCreation(stored.serialized, id: stored.intent.operationID) == stored.intent else { throw CreationError.changed }
            var next = stored.intent
            next.phase = .prepared
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            try environment.writeMarkerAtomically(data, creationURL(next.operationID, environment))
            return StoredCreation(intent: next, serialized: data)
        }
    }

    // Normal edges are prepared -> attempting -> confirmed -> completed.
    // A failed write grants no authority, even if its rename became visible.
    static func transitionCreation(_ stored: StoredCreation, to phase: CreationIntent.Phase,
                                   receipt: DatabaseReference? = nil, environment: Environment = .live) throws -> StoredCreation {
        try withCreationLocks(stored.intent, environment: environment) {
            guard try environment.readData(creationURL(stored.intent.operationID, environment)) == stored.serialized,
                  try decodeCreation(stored.serialized, id: stored.intent.operationID) == stored.intent else { throw CreationError.changed }
            switch (stored.intent.phase, phase) {
            case (.prepared, .attempting):
                guard receipt == nil else { throw CreationError.invalid }
                _ = try readCreationPayload(stored, environment: environment)
            case (.attempting, .confirmed):
                guard let receipt, receiptMatches(receipt, intent: stored.intent) else { throw CreationError.invalid }
            case (.confirmed, .completed):
                guard receipt == nil else { throw CreationError.invalid }
            default: throw CreationError.invalid
            }
            var next = stored.intent
            next.phase = phase
            if phase == .confirmed { next.receipt = receipt }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            try environment.writeMarkerAtomically(data, creationURL(next.operationID, environment))
            if phase == .completed {
                try? environment.removeItem(creationPayloadURL(next.operationID, environment))
                try? environment.removeItem(creationStageURL(next.operationID, environment))
            }
            return StoredCreation(intent: next, serialized: data)
        }
    }
}
