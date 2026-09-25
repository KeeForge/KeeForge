import Foundation

/// Finds the bytes of AutoFill saves whose upload conflicted, so an unlocked
/// session can merge them into the cloud copy it opened.
///
/// A conflicted marker's payload is rarely still the cache: opening the
/// database downloads the newer cloud copy over it, and the only copy left is
/// the pre-overwrite backup (`CloudSyncCoordinator.downloadLatestCopy`). Both
/// are candidates, and a file only counts when it hashes to the marker's
/// recorded SHA-512, so a wrong or partial file can never stand in for it.
enum PendingUploadRecovery {
    struct Payload: Sendable {
        let storedMarker: PendingUploadQueue.StoredMarker
        let data: Data
        /// Where the bytes were found, so a refused merge can point the user
        /// at the file that actually holds the change.
        let location: Location
    }

    enum Location: Sendable, Equatable {
        case cache
        case backup(URL)
    }

    enum Lookup: Sendable {
        case noConflicts
        case recovered([Payload])
        /// At least one conflicted marker has no readable payload, or one
        /// written under a master key the database no longer uses. Nothing is
        /// merged then: a partial merge would clear some conflicts while the
        /// change the user is looking for stays stranded.
        case unavailable
    }

    struct Environment: Sendable {
        var listMarkers: @Sendable (UUID) -> [PendingUploadQueue.StoredMarker]
        var cacheURL: @Sendable (PendingUploadQueue.Marker) -> URL
        /// Newest first, like the Backups list in Database Details.
        var backupURLs: @Sendable (DatabaseReference) -> [URL]
        var readData: @Sendable (URL) throws -> Data
        var dropMarker: @Sendable (PendingUploadQueue.StoredMarker) throws -> Void

        static let live = Environment(
            listMarkers: { databaseId in
                PendingUploadQueue.listMarkers(for: databaseId)
            },
            cacheURL: { marker in
                PendingUploadQueue.resolveAppGroupURL(for: marker.encryptedBytesCacheURL)
            },
            backupURLs: { reference in
                DatabaseListStore.recentBackups(for: reference)
            },
            readData: { url in
                try CoordinatedFileReader.readData(from: url)
            },
            dropMarker: { storedMarker in
                _ = try PendingUploadQueue.dropIfUnchanged(storedMarker)
            }
        )
    }

    static func hasConflicts(for reference: DatabaseReference, environment: Environment = .live) -> Bool {
        environment.listMarkers(reference.id).contains(where: \.marker.isConflicted)
    }

    static func lookUpPayloads(for reference: DatabaseReference, environment: Environment = .live) -> Lookup {
        let conflictedMarkers = environment.listMarkers(reference.id).filter(\.marker.isConflicted)
        guard conflictedMarkers.isEmpty == false else { return .noConflicts }

        var payloads: [Payload] = []
        for storedMarker in conflictedMarkers {
            // Same rule as the drainer: bytes saved before a master-key change
            // are ciphertext under the old key.
            if let rekeyedAt = reference.lastMasterKeyChangeAt,
               storedMarker.marker.createdAt < rekeyedAt {
                return .unavailable
            }
            // A provisional marker hashes the pre-save base, not the AutoFill
            // result. Recovering a matching backup would merge no change and
            // strand the real payload while falsely reporting success.
            guard storedMarker.marker.isPayloadFinalized else { return .unavailable }
            let candidates: [(url: URL, location: Location)] =
                [(environment.cacheURL(storedMarker.marker), .cache)]
                + environment.backupURLs(reference).map { ($0, .backup($0)) }
            let match = candidates.lazy
                .compactMap { candidate in
                    (try? environment.readData(candidate.url)).map { (data: $0, location: candidate.location) }
                }
                .first { KDBXCrypto.sha512($0.data) == storedMarker.marker.openTimeSHA512 }
            guard let match else { return .unavailable }
            payloads.append(Payload(storedMarker: storedMarker, data: match.data, location: match.location))
        }
        return .recovered(payloads)
    }

    /// Only for markers whose payload is already part of an uploaded save. A
    /// marker that fails to drop stays conflicted, and merging it again is a
    /// no-op, so the failure is not surfaced.
    static func dropMarkers(_ storedMarkers: [PendingUploadQueue.StoredMarker], environment: Environment = .live) {
        for storedMarker in storedMarkers {
            try? environment.dropMarker(storedMarker)
        }
    }
}
