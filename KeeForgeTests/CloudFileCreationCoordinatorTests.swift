import Foundation
import XCTest
@testable import KeeForge

final class CloudFileCreationCoordinatorTests: XCTestCase {
    private actor Transport {
        var calls = 0
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        func create() async throws -> CloudCreatedFile {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            if fails { throw CloudProviderError.networkUnavailable }
            return CloudCreatedFile(file: CloudFile(id: "remote-id", name: "vault.kdbx", path: "/vault.kdbx", isFolder: false, modifiedDate: nil, size: nil),
                metadata: CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 42), contentHash: nil, size: 3))
        }
        func count() -> Int { calls }
    }

    private func fixture() throws -> (URL, PendingUploadQueue.Environment, DatabaseReference) {
        guard AppGroupContainer.isRedirectedForTesting else { throw XCTSkip("Requires isolated test App Group") }
        let root = AppGroupContainer.url.appendingPathComponent("creation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var queue = PendingUploadQueue.Environment.live
        queue.appGroupContainerURL = { root }
        queue.createDirectory = { try createDurableDirectory(at: $0, anchor: root) }
        queue.postDarwinNotification = {}
        let reference = DatabaseReference(id: UUID(), nickname: nil, filename: "vault.kdbx", bookmarkData: nil,
            keyFileBookmarkData: Data([7]), keyFileFilename: "key", isQuickLaunch: false, lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 1), colorTag: nil, legacyKeychainFilename: nil)
        return (root, queue, reference)
    }

    private func confirmedCreation(queue: PendingUploadQueue.Environment, reference: DatabaseReference) throws -> PendingUploadQueue.StoredCreation {
        let id = UUID()
        let account = "account-" + reference.id.uuidString
        let prepared = try PendingUploadQueue.prepareCreation(operationID: id, provider: "webdav", accountID: account,
            target: "/vault", payload: Data([1, 2, 3]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        let attempting = try PendingUploadQueue.transitionCreation(prepared, to: .attempting, environment: queue)
        var receipt = reference
        receipt.source = .cloud(CloudSyncMetadata(provider: "webdav", accountId: account, fileId: "remote-id", displayPath: "/vault",
            remoteContentHash: nil, remoteModifiedAt: nil, lastSyncedAt: nil, lastSyncIssue: nil))
        receipt.updateCloudSyncMetadata { $0.localHeadOperationID = id }
        return try PendingUploadQueue.transitionCreation(attempting, to: .confirmed, receipt: receipt, environment: queue)
    }

    func testCreationRecoveryErrorsExplainSafeNextSteps() {
        XCTAssertEqual(PendingUploadQueue.CreationError.reserved.localizedDescription,
            "A cloud creation for this location is already awaiting recovery. Open Cloud Recovery.")
        for error in [PendingUploadQueue.CreationError.invalid, .changed] {
            XCTAssertEqual(error.localizedDescription,
                "The cloud recovery record is unavailable or has changed. Keep your encrypted copies and reopen Cloud Recovery.")
        }
        XCTAssertEqual(CloudFileCreationCoordinator.RecoveryError.uncertain.localizedDescription,
            "Cloud creation may have succeeded. Open Cloud Recovery to keep or recover the encrypted copy.")
        for error in [CloudFileCreationCoordinator.RecoveryError.unavailable, .registrationRejected, .registrationUnconfirmed] {
            XCTAssertEqual(error.localizedDescription,
                "Cloud recovery could not finish. Keep the encrypted copy and reopen Cloud Recovery.")
        }
    }

    func testIntentWriteFailureCannotDispatch() async throws {
        let (root, original, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var queue = original
        queue.writeMarkerAtomically = { data, url in
            if url.pathExtension == "creation" { throw CocoaError(.fileWriteUnknown) }
            try writeAtomicallyAndDurably(data, to: url)
        }
        let transport = Transport()
        var environment = CloudFileCreationCoordinator.Environment()
        environment.queue = queue
        environment.createFile = { _, _, _, _ in try await transport.create() }
        do {
            _ = try await CloudFileCreationCoordinator.create(operationID: UUID(), provider: "webdav", accountID: "account", target: "/vault", bytes: Data([1]), referenceTemplate: reference, environment: environment)
            XCTFail("Expected record write failure")
        } catch {}
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try PendingUploadQueue.listCreations(environment: queue).isEmpty)
    }

    func testConcurrentDistinctOperationsOnSameDestinationDispatchOnce() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(fails: true)
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        let captured = env
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 { group.addTask {
                _ = try? await CloudFileCreationCoordinator.create(operationID: UUID(), provider: "webdav", accountID: "account", target: "/vault", bytes: Data([1]), referenceTemplate: reference, environment: captured)
            } }
        }
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).count, 1)
    }

    func testMissingOrCorruptPayloadRetainsPreparedRecordAndCannotDispatch() async throws {
        for missing in [true, false] {
            let (root, queue, reference) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let operation = UUID()
            _ = try PendingUploadQueue.prepareCreation(operationID: operation, provider: "webdav", accountID: "account", target: "/vault", payload: Data([1]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
            let payload = PendingUploadQueue.creationPayloadURL(operation, queue)
            if missing { try FileManager.default.removeItem(at: payload) } else { try Data([2]).write(to: payload) }
            let transport = Transport()
            var env = CloudFileCreationCoordinator.Environment()
            env.queue = queue
            env.createFile = { _, _, _, _ in try await transport.create() }
            XCTAssertThrowsError(try CloudFileCreationCoordinator.export(operationID: operation, environment: env))
            do { _ = try await CloudFileCreationCoordinator.retryPrepared(operationID: operation, environment: env); XCTFail("Expected unreadable payload") } catch {}
            let count = await transport.count()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .prepared)
            XCTAssertTrue(FileManager.default.fileExists(atPath: PendingUploadQueue.creationStageURL(operation, queue).path))
            if !missing { XCTAssertEqual(try Data(contentsOf: payload), Data([2])) }
        }
    }

    func testConfirmedCreationRejectsForeignCacheAndForeignRow() throws {
        for collideCache in [true, false] {
            let (root, queue, reference) = try fixture()
            defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
            let stored = try confirmedCreation(queue: queue, reference: reference)
            let receipt = try XCTUnwrap(stored.intent.receipt)
            let cache = DatabaseListStore.cacheLocation(for: receipt)
            defer { if collideCache { try? FileManager.default.removeItem(at: cache) } }
            var foreignInode: NSNumber?
            if collideCache {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: cache)
                foreignInode = try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber
                XCTAssertNotNil(foreignInode)
            } else {
                var foreign = receipt
                foreign.keyFileBookmarkData = Data([8])
                DatabaseListStore.testUpsert(foreign)
            }
            guard case .rejected = DatabaseListStore.registerCloudCreation(stored, bytes: Data([1, 2, 3]), queue: queue) else { return XCTFail("Foreign state must be rejected") }
            XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .confirmed)
            if collideCache {
                XCTAssertEqual(try Data(contentsOf: cache), Data([1, 2, 3]))
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber, foreignInode)
            }
            else { XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == reference.id })?.keyFileBookmarkData, Data([8])) }
        }
    }

    func testStrictRecordRejectsChangedReceiptFactorsOrHead() throws {
        for changedHead in [true, false] {
            let (root, queue, reference) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let stored = try confirmedCreation(queue: queue, reference: reference)
            let path = root.appendingPathComponent("cloud-creation-journal/" + stored.intent.operationID.uuidString + ".creation")
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: stored.serialized) as? [String: Any])
            var receipt = try XCTUnwrap(record["receipt"] as? [String: Any])
            if changedHead {
                var source = try XCTUnwrap(receipt["source"] as? [String: Any])
                var cloud = try XCTUnwrap(source["cloud"] as? [String: Any])
                var metadata = try XCTUnwrap(cloud["_0"] as? [String: Any])
                metadata["localHeadOperationID"] = UUID().uuidString
                cloud["_0"] = metadata; source["cloud"] = cloud; receipt["source"] = source
            } else { receipt["keyFileBookmarkData"] = Data([8]).base64EncodedString() }
            record["receipt"] = receipt
            let altered = try JSONSerialization.data(withJSONObject: record)
            try altered.write(to: path)
            XCTAssertThrowsError(try PendingUploadQueue.listCreations(environment: queue))
            XCTAssertEqual(try Data(contentsOf: path), altered)
            XCTAssertEqual(try Data(contentsOf: PendingUploadQueue.creationPayloadURL(stored.intent.operationID, queue)), Data([1, 2, 3]))
        }
    }

    func testUnreadableCreationRecordFailsClosedWithoutCleanup() throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([1]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        var failing = queue
        let read = queue.readData
        failing.readData = { url in
            if url.pathExtension == "creation" { throw CocoaError(.fileReadNoPermission) }
            return try read(url)
        }
        XCTAssertThrowsError(try PendingUploadQueue.listCreations(environment: failing))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent, stored.intent)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(stored, environment: queue), Data([1]))
    }

    func testUnreadableCreationDoesNotHideOtherRecoveryOrPermitNewCreation() throws {
        let (root, queue, reference) = try fixture()
        defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
        let confirmed = try confirmedCreation(queue: queue, reference: reference)
        let corruptURL = root.appendingPathComponent("cloud-creation-journal/" + UUID().uuidString + ".creation")
        let corrupt = Data("not a journal".utf8)
        try corrupt.write(to: corruptURL)
        let listing = try PendingUploadQueue.listCreationsForRecovery(environment: queue)
        XCTAssertTrue(listing.hasUnreadableRecords)
        XCTAssertEqual(listing.records.map(\.intent.operationID), [confirmed.intent.operationID])
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        XCTAssertEqual(try CloudFileCreationCoordinator.export(operationID: confirmed.intent.operationID, environment: env), Data([1, 2, 3]))
        _ = try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: confirmed.intent.operationID, environment: env)
        XCTAssertEqual(try PendingUploadQueue.readCreation(confirmed.intent.operationID, environment: queue).intent.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
        XCTAssertThrowsError(try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "webdav", accountID: "another",
            target: "/another", payload: Data([4]), referenceTemplate: reference, isConflictCopy: false, environment: queue))
    }

    @MainActor
    func testDrainerDoesNotDispatchCreationRecords() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "webdav", accountID: "account", target: "/vault", payload: Data([1]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        let transport = Transport()
        var environment = PendingUploadDrainer.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.listMarkers = { PendingUploadQueue.listMarkers(for: $0, environment: queue) }
        environment.deliverMarker = { _, _ in _ = try await transport.create(); return nil }
        _ = await PendingUploadDrainer(environment: environment).drainAll()
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .prepared)
    }

    private struct RestartFixture: Codable {
        let seedPID: Int32
        let attemptingID: UUID
        let confirmedID: UUID
        let attemptingReference: DatabaseReference
        let confirmedReference: DatabaseReference
    }

    func testOptInTwoProcessRestart() async throws {
        guard let phase = ProcessInfo.processInfo.environment["KEEPFORGE_CREATION_RESTART_PHASE"],
              let path = ProcessInfo.processInfo.environment["KEEPFORGE_CREATION_RESTART_DIR"] else {
            throw XCTSkip("Two-process creation fixture is not enabled")
        }
        guard AppGroupContainer.isRedirectedForTesting, phase == "seed" || phase == "resume" else {
            throw XCTSkip("Requires the isolated test host and a valid restart phase")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path.contains("/scratch/cloud-modularization/"), root.resolvingSymlinksInPath().path == root.path,
              !root.path.hasPrefix(AppGroupContainer.url.standardizedFileURL.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let infoURL = root.appendingPathComponent("restart-fixture.json")
        var queue = PendingUploadQueue.Environment.live
        queue.appGroupContainerURL = { root }
        queue.createDirectory = { try createDurableDirectory(at: $0, anchor: root) }
        queue.postDarwinNotification = {}
        let transport = Transport(fails: phase == "seed")
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        if phase == "seed" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
            let firstReference = DatabaseReference(id: UUID(), nickname: nil, filename: "first.kdbx", bookmarkData: nil,
                keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false, lastOpenedAt: nil,
                addedAt: Date(timeIntervalSince1970: 1), colorTag: nil, legacyKeychainFilename: nil)
            let secondReference = DatabaseReference(id: UUID(), nickname: nil, filename: "second.kdbx", bookmarkData: nil,
                keyFileBookmarkData: Data([7]), keyFileFilename: "key", isQuickLaunch: false, lastOpenedAt: nil,
                addedAt: Date(timeIntervalSince1970: 1), colorTag: nil, legacyKeychainFilename: nil)
            let first = UUID(); let second = UUID()
            env.createFile = { _, _, _, _ in try await transport.create() }
            do { _ = try await CloudFileCreationCoordinator.create(operationID: first, provider: "webdav", accountID: "seed-" + first.uuidString,
                target: "/attempt", bytes: Data([1, 2, 3]), referenceTemplate: firstReference, environment: env); XCTFail("Expected lost response") }
            catch is CloudFileCreationCoordinator.UncertainCreation {}
            let successful = Transport()
            env.createFile = { _, _, _, _ in try await successful.create() }
            env.register = { _, _, _ in .notPublished(CocoaError(.fileWriteUnknown)) }
            do { _ = try await CloudFileCreationCoordinator.create(operationID: second, provider: "webdav", accountID: "seed-" + second.uuidString,
                target: "/confirmed", bytes: Data([4, 5, 6]), referenceTemplate: secondReference, environment: env); XCTFail("Expected registration failure") }
            catch {}
            let firstCount = await transport.count()
            let secondCount = await successful.count()
            XCTAssertEqual(firstCount, 1)
            XCTAssertEqual(secondCount, 1)
            let records = try PendingUploadQueue.listCreations(environment: queue)
            XCTAssertEqual(records.first(where: { $0.intent.operationID == first })?.intent.phase, .attempting)
            XCTAssertEqual(records.first(where: { $0.intent.operationID == second })?.intent.phase, .confirmed)
            let info = RestartFixture(seedPID: ProcessInfo.processInfo.processIdentifier, attemptingID: first,
                confirmedID: second, attemptingReference: firstReference, confirmedReference: secondReference)
            try writeAtomicallyAndDurably(JSONEncoder().encode(info), to: infoURL, directoryAnchor: root)
        } else {
            let info = try JSONDecoder().decode(RestartFixture.self, from: Data(contentsOf: infoURL))
            XCTAssertNotEqual(ProcessInfo.processInfo.processIdentifier, info.seedPID)
            env.createFile = { _, _, _, _ in try await transport.create() }
            do { _ = try await CloudFileCreationCoordinator.create(operationID: info.attemptingID, provider: "webdav", accountID: "seed-" + info.attemptingID.uuidString,
                target: "/attempt", bytes: Data([1, 2, 3]), referenceTemplate: info.attemptingReference, environment: env); XCTFail("Attempt must not resend") }
            catch is CloudFileCreationCoordinator.RecoveryError {}
            XCTAssertEqual(try CloudFileCreationCoordinator.export(operationID: info.attemptingID, environment: env), Data([1, 2, 3]))
            let registered = try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: info.confirmedID, environment: env)
            XCTAssertEqual(registered.id, info.confirmedReference.id)
            XCTAssertEqual(registered.keyFileBookmarkData, info.confirmedReference.keyFileBookmarkData)
            XCTAssertEqual(registered.keyFileFilename, info.confirmedReference.keyFileFilename)
            XCTAssertEqual(registered.cloudSyncMetadata?.localHeadOperationID, info.confirmedID)
            XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: registered)), Data([4, 5, 6]))
            let records = try PendingUploadQueue.listCreations(environment: queue)
            XCTAssertEqual(records.first(where: { $0.intent.operationID == info.attemptingID })?.intent.phase, .attempting)
            XCTAssertEqual(records.first(where: { $0.intent.operationID == info.confirmedID })?.intent.phase, .completed)
            let count = await transport.count()
            XCTAssertEqual(count, 0)
            XCTAssertTrue(DatabaseListStore.remove(id: registered.id))
        }
    }

    func testConfirmedConflictCopyCleansOnlyItsProvenPreparedAttempts() async throws {
        for failCleanup in [false, true] {
            let (root, queue, reference) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = UUID()
            let bytes = Data([1, 2, 3])
            let rejectedID = UUID()
            var env = CloudFileCreationCoordinator.Environment()
            env.queue = queue
            env.createFile = { _, _, _, _ in throw CloudUploadFailure(underlying: .conflict(remoteRev: nil), outcome: .rejected) }
            do {
                _ = try await CloudFileCreationCoordinator.create(operationID: rejectedID, provider: "ftp", accountID: "account",
                    target: "/taken", bytes: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: batch, environment: env)
                XCTFail("Expected a conflict")
            } catch let error as CloudProviderError {
                guard case .conflict = error else { return XCTFail("Expected conflict") }
            }
            let rejected = try PendingUploadQueue.readCreation(rejectedID, environment: queue)
            XCTAssertEqual(rejected.intent.phase, .prepared)
            let unrelated = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "ftp", accountID: "account",
                target: "/other", payload: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: UUID(), environment: queue)
            let pending = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "ftp", accountID: "account",
                target: "/uncertain", payload: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: batch, environment: queue)
            let attempting = try PendingUploadQueue.transitionCreation(pending, to: .attempting, environment: queue)
            if failCleanup {
                let remove = queue.removeItem
                env.queue.removeItem = { url in
                    if url.lastPathComponent == rejectedID.uuidString + ".creation" { throw CocoaError(.fileWriteUnknown) }
                    try remove(url)
                }
            }
            let transport = Transport()
            env.createFile = { _, _, _, _ in try await transport.create() }
            _ = try await CloudFileCreationCoordinator.create(operationID: UUID(), provider: "ftp", accountID: "account",
                target: "/success", bytes: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: batch, environment: env)
            XCTAssertEqual(try PendingUploadQueue.readCreationPayload(unrelated, environment: queue), bytes)
            XCTAssertEqual(try PendingUploadQueue.readCreationPayload(attempting, environment: queue), bytes)
            XCTAssertEqual(try PendingUploadQueue.readCreation(attempting.intent.operationID, environment: queue).intent.phase, .attempting)
            if failCleanup {
                XCTAssertEqual(try PendingUploadQueue.readCreationPayload(rejected, environment: queue), bytes)
                try PendingUploadQueue.cleanCompletedConflictCopyAttempts(environment: queue)
            }
            XCTAssertThrowsError(try PendingUploadQueue.readCreation(rejectedID, environment: queue))
            XCTAssertFalse(FileManager.default.fileExists(atPath: PendingUploadQueue.creationPayloadURL(rejectedID, queue).path))
            XCTAssertEqual(try PendingUploadQueue.readCreation(unrelated.intent.operationID, environment: queue).intent.phase, .prepared)
        }
    }

    func testConflictCleanupRequiresDurableReceiptAndRetainsRacingAttempt() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = UUID()
        let bytes = Data([1, 2, 3])
        let completedID = UUID()
        let transport = Transport()
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        _ = try await CloudFileCreationCoordinator.create(operationID: completedID, provider: "ftp", accountID: "account",
            target: "/completed", bytes: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: batch, environment: env)
        let candidate = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "ftp", accountID: "account",
            target: "/prepared", payload: bytes, referenceTemplate: reference, isConflictCopy: true, conflictBatchID: batch, environment: queue)
        let name = completedID.uuidString + ".creation"
        let write = queue.writeMarkerAtomically
        for failAfterPublication in [false, true] {
            var failed = queue
            failed.writeMarkerAtomically = { data, url in
                if url.lastPathComponent == name {
                    if failAfterPublication { try write(data, url) }
                    throw CocoaError(.fileWriteUnknown)
                }
                try write(data, url)
            }
            XCTAssertThrowsError(try PendingUploadQueue.cleanCompletedConflictCopyAttempts(environment: failed))
            XCTAssertEqual(try PendingUploadQueue.readCreationPayload(candidate, environment: queue), bytes)
        }
        var racing = queue
        racing.writeMarkerAtomically = { data, url in
            if url.lastPathComponent == name {
                _ = try PendingUploadQueue.transitionCreation(candidate, to: .attempting, environment: queue)
            }
            try write(data, url)
        }
        try PendingUploadQueue.cleanCompletedConflictCopyAttempts(environment: racing)
        let retained = try PendingUploadQueue.readCreation(candidate.intent.operationID, environment: queue)
        XCTAssertEqual(retained.intent.phase, .attempting)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(retained, environment: queue), bytes)
    }

    func testRecoveryActionsMatchPersistedPhase() {
        let actions = CloudFileCreationCoordinator.RecoveryActions.forPhase
        XCTAssertEqual(actions(.prepared), .init(export: true, retry: true, complete: false, discard: true))
        XCTAssertEqual(actions(.attempting), .init(export: true, retry: false, complete: false, discard: false))
        XCTAssertEqual(actions(.confirmed), .init(export: true, retry: false, complete: true, discard: false))
        XCTAssertEqual(actions(.completed), .init(export: false, retry: false, complete: false, discard: false))
    }

    func testPreparedDiscardRemovesExactPayloadAndReleasesDestination() throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let prepared = try PendingUploadQueue.prepareCreation(operationID: id, provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([1, 2, 3]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        try PendingUploadQueue.discardPreparedCreation(prepared, environment: queue)
        XCTAssertTrue(try PendingUploadQueue.listCreations(environment: queue).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PendingUploadQueue.creationPayloadURL(id, queue).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PendingUploadQueue.creationStageURL(id, queue).path))
        _ = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([4]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
    }

    func testDiscardRefusesStalePreparedSnapshotAfterDispatch() throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let prepared = try PendingUploadQueue.prepareCreation(operationID: id, provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([1, 2, 3]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        let attempting = try PendingUploadQueue.transitionCreation(prepared, to: .attempting, environment: queue)
        XCTAssertThrowsError(try PendingUploadQueue.discardPreparedCreation(prepared, environment: queue))
        XCTAssertThrowsError(try PendingUploadQueue.discardPreparedCreation(attempting, environment: queue))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .attempting)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(attempting, environment: queue), Data([1, 2, 3]))
    }

    func testDiscardSyncFailureRetainsPreparedRecordAndPayload() throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try PendingUploadQueue.prepareCreation(operationID: UUID(), provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([1, 2, 3]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        var failing = queue
        failing.synchronizeRetirementDirectory = { _ in throw POSIXError(.EIO) }
        XCTAssertThrowsError(try PendingUploadQueue.discardPreparedCreation(prepared, environment: failing))
        let retained = try XCTUnwrap(PendingUploadQueue.listCreations(environment: queue).first)
        XCTAssertEqual(retained.intent.phase, .prepared)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(retained, environment: queue), Data([1, 2, 3]))
        try PendingUploadQueue.discardPreparedCreation(retained, environment: queue)
        XCTAssertTrue(try PendingUploadQueue.listCreations(environment: queue).isEmpty)
    }

    func testExplicitPreparedRetryUsesPersistedPayload() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(fails: true)
        var environment = CloudFileCreationCoordinator.Environment()
        environment.queue = queue
        environment.createFile = { _, _, _, bytes in
            guard bytes == Data([1, 2, 3]) else { throw CloudProviderError.invalidConfiguration }
            return try await transport.create()
        }
        let id = UUID()
        _ = try PendingUploadQueue.prepareCreation(operationID: id, provider: "webdav", accountID: "account",
            target: "/vault", payload: Data([1, 2, 3]), referenceTemplate: reference, isConflictCopy: false, environment: queue)
        do { _ = try await CloudFileCreationCoordinator.retryPrepared(operationID: id, environment: environment); XCTFail("Expected uncertain response") }
        catch is CloudFileCreationCoordinator.UncertainCreation {}
        do { _ = try await CloudFileCreationCoordinator.retryPrepared(operationID: id, environment: environment); XCTFail("Attempting cannot retry") }
        catch is CloudFileCreationCoordinator.RecoveryError {}
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testProvenNotDispatchedRestoresPreparedAndCanRetry() async throws {
        let (root, queue, reference) = try fixture()
        defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var environment = CloudFileCreationCoordinator.Environment()
        environment.queue = queue
        environment.createFile = { _, _, _, _ in
            throw CloudFileCreationCoordinator.NotDispatched(underlying: .notAuthenticated)
        }
        let operation = UUID()
        do {
            _ = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav", accountID: "account-" + reference.id.uuidString,
                target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: environment)
            XCTFail("Expected pre-dispatch failure")
        } catch let error as CloudProviderError { XCTAssertEqual(error, .notAuthenticated) }
        let before = await transport.count()
        XCTAssertEqual(before, 0)
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .prepared)
        XCTAssertEqual(try CloudFileCreationCoordinator.export(operationID: operation, environment: environment), Data([1, 2, 3]))
        environment.createFile = { _, _, _, _ in try await transport.create() }
        let receipt = try await CloudFileCreationCoordinator.retryPrepared(operationID: operation, environment: environment)
        XCTAssertEqual(receipt.id, reference.id)
        let after = await transport.count()
        XCTAssertEqual(after, 1)
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .completed)
    }

    func testCancellationBeforeDispatchRestoresPreparedOrRetainsUncertainOnWriteFailure() async throws {
        for failRestore in [false, true] {
            let (root, base, reference) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var queue = base
            if failRestore {
                let write = base.writeMarkerAtomically
                queue.writeMarkerAtomically = { data, url in
                    if url.pathExtension == "creation",
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       object["phase"] as? String == "prepared",
                       FileManager.default.fileExists(atPath: url.path) { throw CocoaError(.fileWriteUnknown) }
                    try write(data, url)
                }
            }
            let lifetime = CloudCreationLifetime()
            let transport = Transport()
            var env = CloudFileCreationCoordinator.Environment()
            env.queue = queue
            env.afterAttemptPersisted = { lifetime.cancel() }
            env.createFile = { _, _, _, _ in try await transport.create() }
            let id = UUID()
            do {
                _ = try await CloudFileCreationCoordinator.create(operationID: id, provider: "webdav", accountID: "account",
                    target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, lifetime: lifetime, environment: env)
                XCTFail("Expected cancellation")
            } catch {
                if failRestore { XCTAssertTrue(error is CloudFileCreationCoordinator.UncertainCreation) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let count = await transport.count()
            XCTAssertEqual(count, 0)
            let record = try PendingUploadQueue.readCreation(id, environment: queue)
            XCTAssertEqual(record.intent.phase, failRestore ? .attempting : .prepared)
            XCTAssertEqual(try PendingUploadQueue.readCreationPayload(record, environment: queue), Data([1, 2, 3]))
        }
    }

    func testUnexpectedPreDispatchProviderErrorRestoresPrepared() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in throw CloudCreationNotDispatched(underlying: CocoaError(.fileReadUnknown)) }
        let id = UUID()
        do {
            _ = try await CloudFileCreationCoordinator.create(operationID: id, provider: "webdav", accountID: "account",
                target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: env)
            XCTFail("Expected underlying pre-dispatch error")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadUnknown.rawValue) }
        let record = try PendingUploadQueue.readCreation(id, environment: queue)
        XCTAssertEqual(record.intent.phase, .prepared)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(record, environment: queue), Data([1, 2, 3]))
    }

    func testTaskCancellationBeforeDispatchRestoresPrepared() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.afterAttemptPersisted = { withUnsafeCurrentTask { $0?.cancel() } }
        env.createFile = { _, _, _, _ in try await transport.create() }
        let captured = env
        let id = UUID()
        let task = Task {
            try await CloudFileCreationCoordinator.create(operationID: id, provider: "webdav", accountID: "account",
                target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: captured)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        let record = try PendingUploadQueue.readCreation(id, environment: queue)
        XCTAssertEqual(record.intent.phase, .prepared)
        XCTAssertEqual(try PendingUploadQueue.readCreationPayload(record, environment: queue), Data([1, 2, 3]))
    }

    func testMissingProviderCredentialsRestorePreparedWithoutDispatch() async throws {
        let providers: [any CloudProvider] = [
            WebDAVCloudProvider(credentialLoader: { _ in nil }),
            FTPCloudProvider(credentialLoader: { _ in nil })
        ]
        for provider in providers {
            let (root, queue, reference) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var env = CloudFileCreationCoordinator.Environment()
            env.queue = queue
            env.createFile = { _, account, path, bytes in
                try await provider.createFile(accountId: account, path: path, data: bytes, progress: { _ in })
            }
            let id = UUID()
            do {
                _ = try await CloudFileCreationCoordinator.create(operationID: id, provider: provider.id,
                    accountID: "missing", target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: env)
                XCTFail("Expected a pre-dispatch authentication error")
            } catch let error as CloudProviderError { XCTAssertEqual(error, .notAuthenticated) }
            let record = try PendingUploadQueue.readCreation(id, environment: queue)
            XCTAssertEqual(record.intent.phase, .prepared)
            XCTAssertEqual(try PendingUploadQueue.readCreationPayload(record, environment: queue), Data([1, 2, 3]))
        }
    }

    func testProviderNotAuthenticatedAfterDispatchRemainsUncertain() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = CloudFileCreationCoordinator.Environment()
        environment.queue = queue
        environment.createFile = { _, _, _, _ in throw CloudProviderError.notAuthenticated }
        let operation = UUID()
        do {
            _ = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav", accountID: "account",
                target: "/vault", bytes: Data([1]), referenceTemplate: reference, environment: environment)
            XCTFail("Expected uncertain attempt")
        } catch let error as CloudFileCreationCoordinator.UncertainCreation {
            XCTAssertEqual(error.underlying as? CloudProviderError, .notAuthenticated)
        }
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .attempting)
    }

    func testLostResponseCannotResendAndRetainsBytes() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport(fails: true)
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        let operation = UUID()
        for _ in 0..<2 {
            do { _ = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav", accountID: "account-" + reference.id.uuidString, target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: env); XCTFail("Expected failure") } catch {}
        }
        let count = await transport.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try CloudFileCreationCoordinator.export(operationID: operation, environment: env), Data([1, 2, 3]))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .attempting)
    }

    func testKnownReceiptRetriesRegistrationWithoutNetwork() async throws {
        let (root, queue, reference) = try fixture()
        defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        env.register = { stored, bytes, queue in
            var io = DurableFileWriteIO()
            io.afterPublication = { _ in throw CocoaError(.fileWriteUnknown) }
            return DatabaseListStore.registerCloudCreation(stored, bytes: bytes, queue: queue, registryIO: io)
        }
        let operation = UUID()
        do { _ = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav", accountID: "account-" + reference.id.uuidString, target: "/vault-" + operation.uuidString, bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: env); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .confirmed)
        env.register = { DatabaseListStore.registerCloudCreation($0, bytes: $1, queue: $2) }
        let registered = try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: operation, environment: env)
        XCTAssertEqual(registered.id, reference.id)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: registered)), Data([1, 2, 3]))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .completed)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testKnownReceiptFinishesAfterPresentationChangesWithoutResending() async throws {
        let (root, queue, reference) = try fixture()
        defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        env.register = { stored, bytes, queue in
            var io = DurableFileWriteIO()
            io.afterPublication = { _ in throw CocoaError(.fileWriteUnknown) }
            return DatabaseListStore.registerCloudCreation(stored, bytes: bytes, queue: queue, registryIO: io)
        }
        let operation = UUID()
        do {
            _ = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav",
                accountID: "account-" + reference.id.uuidString, target: "/vault-" + operation.uuidString,
                bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: env)
            XCTFail("Expected unconfirmed publication")
        } catch {}
        var existing = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        existing.nickname = "Renamed"
        existing.colorTag = "blue"
        existing.lastOpenedAt = Date(timeIntervalSince1970: 100)
        DatabaseListStore.testUpsert(existing)
        env.register = { DatabaseListStore.registerCloudCreation($0, bytes: $1, queue: $2) }
        _ = try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: operation, environment: env)
        let retained = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(retained, existing)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: retained)), Data([1, 2, 3]))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .completed)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testCompletedRecordDoesNotResurrectRemovedReference() async throws {
        let (root, queue, reference) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        let operation = UUID()
        let receipt = try await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav",
            accountID: "account-" + reference.id.uuidString, target: "/vault", bytes: Data([1, 2, 3]),
            referenceTemplate: reference, environment: env)
        XCTAssertTrue(DatabaseListStore.remove(id: receipt.id))
        XCTAssertThrowsError(try CloudFileCreationCoordinator.resumeKnownRegistration(operationID: operation, environment: env))
        XCTAssertFalse(DatabaseListStore.databases.contains(where: { $0.id == receipt.id }))
        XCTAssertEqual(try PendingUploadQueue.listCreations(environment: queue).first?.intent.phase, .completed)
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }

    func testConcurrentAttemptsDispatchAtMostOnce() async throws {
        let (root, queue, reference) = try fixture()
        defer { _ = DatabaseListStore.remove(id: reference.id); try? FileManager.default.removeItem(at: root) }
        let transport = Transport(fails: true)
        var env = CloudFileCreationCoordinator.Environment()
        env.queue = queue
        env.createFile = { _, _, _, _ in try await transport.create() }
        let operation = UUID()
        let captured = env
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 { group.addTask {
                _ = try? await CloudFileCreationCoordinator.create(operationID: operation, provider: "webdav", accountID: "account-" + reference.id.uuidString, target: "/vault", bytes: Data([1, 2, 3]), referenceTemplate: reference, environment: captured)
            } }
        }
        let count = await transport.count()
        XCTAssertEqual(count, 1)
    }
}
