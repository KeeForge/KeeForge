import Foundation
import KDBXKit
@testable import KeeForge

/// Uses production storage and publication; only provider responses are scripted.
struct CloudJournalTestContext: Sendable {
    let reference: DatabaseReference
    let base: Data
    let payload: Data
    let stored: PendingUploadQueue.StoredMarker

    init(reference: DatabaseReference, base: Data = Data("base-ciphertext".utf8),
         payload: Data = Data("intended-ciphertext".utf8), install: Bool = true) throws {
        self.reference = reference
        self.base = base
        self.payload = payload
        let existing = try? Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        if existing != base { try DatabaseListStore.cacheDatabaseCopy(base, for: reference) }
        stored = try PendingUploadQueue.withCommitLock(for: reference.id) {
            let prepared = try PendingUploadQueue.prepare(reference: reference, currentData: base,
                intendedData: payload, cacheURL: DatabaseListStore.cacheLocation(for: reference))
            guard install else { return prepared }
            let replacement = try LocalDatabaseSaver.replaceFileAtomically(payload,
                at: DatabaseListStore.cacheLocation(for: reference), expectedSHA512: FileDigest.sha512(base),
                authorization: .init(databaseID: reference.id, enforcesEpoch: false, targetIsSharedCopy: true))
            guard case .replaced = replacement else { throw SaveError.saveContextUnavailable }
            var final = prepared
            final.marker.openTimeSHA512 = FileDigest.sha512(payload)
            final = try PendingUploadQueue.finalize(final)
            guard case .published? = try PendingUploadQueue.recoverLocalCommit(final) else {
                throw SaveError.saveContextUnavailable
            }
            return final
        }
    }

    var cacheURL: URL { DatabaseListStore.cacheLocation(for: reference) }
    var payloadURL: URL {
        get throws {
            guard let path = stored.marker.intendedPayloadPath else { throw SaveError.saveContextUnavailable }
            return PendingUploadQueue.resolveAppGroupURL(for: path)
        }
    }

    func environment(transport: CloudJournalTransport = CloudJournalTransport()) -> CloudDatabaseSaver.Environment {
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = { _ in try transport.metadata(byteCount: base.count) }
        environment.downloadRemoteData = { _ in transport.download(fallback: base) }
        environment.upload = { _, bytes, rev, _ in try await transport.upload(bytes, revision: rev) }
        environment.revisionIdentifiesContent = { _, _ in false }
        environment.writeGuarantee = { _, _, _ in .preflightOnly }
        return environment
    }

    func drainerEnvironment(saver: CloudDatabaseSaver.Environment) -> PendingUploadDrainer.Environment {
        var environment = PendingUploadDrainer.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.deliverMarker = { try await CloudDatabaseSaver.deliver($0, reference: $1, environment: saver) }
        return environment
    }
}

final class CloudJournalTransport: @unchecked Sendable {
    struct Upload: Sendable, Equatable {
        let bytes: Data
        let revision: String?
    }
    struct Effects: Sendable {
        var metadataCalls = 0
        var downloads = 0
        var uploads: [Upload] = []
    }
    private let lock = NSLock()
    private var recorded = Effects()
    let remote: Data?
    let revision: String?
    let contentHash: String?
    let response: CloudFileMetadata
    let metadataError: CloudProviderError?
    let uploadError: CloudProviderError?
    let beforeUpload: (@Sendable () async throws -> Void)?

    init(remote: Data? = nil, revision: String? = "rev-1", contentHash: String? = nil,
         response: CloudFileMetadata = .init(modifiedDate: Date(timeIntervalSince1970: 2_000), contentHash: "uploaded-hash", size: 0, rev: "rev-2"),
         metadataError: CloudProviderError? = nil, uploadError: CloudProviderError? = nil,
         beforeUpload: (@Sendable () async throws -> Void)? = nil) {
        self.remote = remote
        self.revision = revision
        self.contentHash = contentHash
        self.response = response
        self.metadataError = metadataError
        self.uploadError = uploadError
        self.beforeUpload = beforeUpload
    }

    var effects: Effects { lock.withLock { recorded } }

    func metadata(byteCount: Int) throws -> CloudFileMetadata {
        lock.withLock { recorded.metadataCalls += 1 }
        if let metadataError { throw metadataError }
        return .init(modifiedDate: Date(timeIntervalSince1970: 1_000), contentHash: contentHash, size: Int64(byteCount), rev: revision)
    }

    func download(fallback: Data) -> Data {
        lock.withLock { recorded.downloads += 1 }
        return remote ?? fallback
    }

    func upload(_ bytes: Data, revision: String?) async throws -> CloudFileMetadata {
        lock.withLock { recorded.uploads.append(.init(bytes: bytes, revision: revision)) }
        try await beforeUpload?()
        if let uploadError { throw uploadError }
        return response
    }
}

enum CloudJournalReadFault: CaseIterable {
    case missingPayload, unknownSchema

    func install(in context: CloudJournalTestContext) throws {
        switch self {
        case .missingPayload:
            try FileManager.default.removeItem(at: context.payloadURL)
        case .unknownSchema:
            var marker = context.stored
            marker.marker.journalVersion = 999
            _ = try PendingUploadQueue.update(marker)
        }
    }
}

final class CloudJournalEffectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}
