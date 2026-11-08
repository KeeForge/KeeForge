import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class CloudFileCreationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        try PendingUploadQueue.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try PendingUploadQueue.clearAll()
        try await super.tearDown()
    }

    func testCrashBoundariesResumeSameIDAndBytesThroughDurableRegistration() async throws {
        for phase in [PendingUploadQueue.CreationIntent.Phase.reserved, .attempting, .confirmed, .completed] {
            let provider = CreationTestProvider()
            let id = UUID()
            let template = creationTemplate(id: id)
            var environment = creationEnvironment(provider)
            let fault = CreationWriteFault(phase: phase)
            let writer = environment.queue.writeMarkerAtomically
            environment.queue.writeMarkerAtomically = { data, url in
                try fault.check(data, url: url)
                try writer(data, url)
            }
            do {
                _ = try await CloudFileCreationCoordinator.create(operationID: id, ownerDatabaseID: id,
                    provider: provider.id, accountID: "account", target: .init(path: "vault.kdbx", parentFileID: "folder_A"),
                    bytes: Data("ciphertext".utf8), referenceTemplate: template, environment: environment)
                XCTFail("Injected crash must stop publication")
            } catch {}
            let persisted = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
            let payload = try Data(contentsOf: PendingUploadQueue.resolveAppGroupURL(for: persisted.payloadPath))
            XCTAssertEqual(payload, Data("ciphertext".utf8))
            XCTAssertTrue(PendingUploadQueue.listMarkers(for: id).isEmpty)
            environment = creationEnvironment(provider)
            let result = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
            XCTAssertEqual(DatabaseListStore.databases.filter { $0.id == id }.count, 1)
            XCTAssertEqual(result.id, id)
            XCTAssertEqual(provider.objects.count, 1)
            XCTAssertEqual(Set(provider.createdIDs).count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: result))), payload)
            XCTAssertEqual(provider.targets.last?.parentFileID, "folder_A")
            XCTAssertTrue(try PendingUploadQueue.listCreations(for: id).isEmpty)
        }
    }

    func testFailureBeforeIntentOrPayloadPublicationNeverDispatchesContent() async throws {
        for failPayload in [false, true] {
            let provider = CreationTestProvider()
            let id = UUID()
            var environment = creationEnvironment(provider)
            let writer = environment.queue.writeMarkerAtomically
            environment.queue.writeMarkerAtomically = { data, url in
                if (failPayload && url.lastPathComponent.hasSuffix(".creation.kdbx")) || (!failPayload && url.pathExtension == "creation") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try writer(data, url)
            }
            do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
            XCTAssertTrue(provider.createdIDs.isEmpty)
            XCTAssertTrue(try PendingUploadQueue.listCreations(for: id).isEmpty)
            let recovered = try await create(id, provider: provider, environment: creationEnvironment(provider))
            XCTAssertEqual(recovered.id, id)
            XCTAssertEqual(provider.objects.count, 1)
        }
    }

    func testLostResponseRestartReconcilesExactObjectAndKeepsIndependentDuplicateNames() async throws {
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail("Expected lost response") } catch {}
        let pending = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        let reservedID = try XCTUnwrap(pending.creationID)
        let recovered = try await CloudFileCreationCoordinator.resume(operationID: id, environment: creationEnvironment(provider))
        XCTAssertEqual(recovered.cloudSyncMetadata?.fileId, reservedID)
        XCTAssertEqual(provider.createdIDs, [reservedID, reservedID])
        let independent = try await create(UUID(), provider: provider, environment: environment)
        XCTAssertNotEqual(independent.cloudSyncMetadata?.fileId, reservedID)
        XCTAssertEqual(provider.objects.count, 2)
        XCTAssertEqual(provider.targets.map(\.path), ["vault.kdbx", "vault.kdbx", "vault.kdbx"])
    }

    func testNewPreparationCannotClaimPendingOldKeyOrChangedDestination() async throws {
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
        for (operation, data, target) in [(UUID(), Data("different-key".utf8), CloudFileCreationTarget(path: "vault.kdbx")),
                                          (id, Data("ciphertext".utf8), CloudFileCreationTarget(path: "vault.kdbx", parentFileID: "other"))] {
            do {
                _ = try await CloudFileCreationCoordinator.create(operationID: operation, ownerDatabaseID: operation,
                    provider: provider.id, accountID: "account", target: target, bytes: data,
                    referenceTemplate: creationTemplate(id: operation), environment: environment)
                XCTFail("A pending action is not another preparation's success")
            } catch { XCTAssertEqual(error as? CloudProviderError, .conflict(remoteRev: nil)) }
        }
        XCTAssertEqual(provider.createdIDs.count, 1)
    }

    func testRegistrationAndCacheFailuresRetainReceiptWithoutAnotherRemoteCreate() async throws {
        for failAfterRegistration in [false, true] {
            let provider = CreationTestProvider()
            let id = UUID()
            var environment = creationEnvironment(provider)
            environment.publish = { reference, bytes in
                if failAfterRegistration { _ = try DatabaseListStore.registerCloudCreation(reference, encryptedBytes: bytes) }
                else { try writeAtomicallyAndDurably(bytes, to: DatabaseListStore.cacheLocation(for: reference)) }
                throw CocoaError(.fileWriteUnknown)
            }
            do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
            let receipt = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
            XCTAssertEqual(receipt.phase, .confirmed)
            XCTAssertNotNil(receipt.receipt)
            _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: creationEnvironment(provider))
            XCTAssertEqual(provider.createdIDs.count, 1)
            XCTAssertEqual(DatabaseListStore.databases.filter { $0.id == id }.count, 1)
        }
    }

    func testFreshProvenRejectionRetriesButEarlierUnknownRemainsUncertain() async throws {
        for generated in [false, true] {
            let provider = CreationTestProvider(generatedIDs: generated)
            provider.failNext = CloudUploadFailure(underlying: .insufficientSpace, outcome: .rejected)
            let id = UUID()
            let environment = creationEnvironment(provider)
            do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
            XCTAssertEqual(try PendingUploadQueue.listCreations(for: id).first?.phase, .reserved)
            _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
            XCTAssertEqual(provider.objects.count, 1)
        }
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment) } catch {}
        provider.failNext = CloudUploadFailure(underlying: .notAuthenticated, outcome: .notDispatched)
        do { _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment) } catch {}
        XCTAssertEqual(try PendingUploadQueue.listCreations(for: id).first?.phase, .attempting)
        let recovered = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
        XCTAssertEqual(recovered.cloudSyncMetadata?.fileId, provider.createdIDs.first)
        XCTAssertEqual(Set(provider.createdIDs).count, 1)
    }

    func testWeakTransportNeverBlindlyRetriesAmbiguousCreate() async throws {
        let provider = CreationTestProvider(generatedIDs: false)
        provider.loseNextResponse = true
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
        do { _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment); XCTFail() }
        catch { XCTAssertEqual(error as? CloudProviderError, .conflict(remoteRev: nil)) }
        XCTAssertEqual(provider.createdIDs.count, 1)
        XCTAssertEqual(provider.objects.count, 1)
        XCTAssertFalse(try PendingUploadQueue.listCreations(for: id).isEmpty)
    }

    func testRevokedAccountPausesUntilExplicitResumeAndNeverChangesAccount() async throws {
        let provider = CreationTestProvider()
        provider.connected = false
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail() } catch {}
        let pending = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        XCTAssertTrue(pending.isPaused)
        XCTAssertEqual(pending.lastIssue, .notAuthenticated)
        XCTAssertTrue(provider.createdIDs.isEmpty)
        provider.connected = true
        _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
        XCTAssertEqual(provider.accounts, ["account"])
    }

    func testCancelDuringAcceptedRequestRetainsReceiptAndPayloadUntilExplicitResume() async throws {
        let provider = CreationTestProvider()
        let id = UUID()
        let environment = creationEnvironment(provider)
        provider.afterAcceptance = { try CloudFileCreationCoordinator.cancel(operationID: id, environment: environment) }
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail() }
        catch { XCTAssertEqual(error as? CloudProviderError, .authenticationCancelled) }
        let pending = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        XCTAssertTrue(pending.isPaused)
        XCTAssertEqual(pending.phase, .confirmed)
        XCTAssertNotNil(pending.receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PendingUploadQueue.resolveAppGroupURL(for: pending.payloadPath).path))
        provider.afterAcceptance = nil
        _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
        XCTAssertEqual(provider.createdIDs.count, 1)
    }

    func testSignOutAfterAcceptancePausesWithReceiptWithoutAnotherCreate() async throws {
        let provider = CreationTestProvider()
        let id = UUID()
        let environment = creationEnvironment(provider)
        provider.afterAcceptance = { provider.signOut(accountId: "account") }
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail() }
        catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
        let pending = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        XCTAssertTrue(pending.isPaused)
        XCTAssertEqual(pending.phase, .confirmed)
        XCTAssertNotNil(pending.receipt)
        provider.afterAcceptance = nil
        _ = try await CloudFileCreationCoordinator.resume(operationID: id, environment: environment)
        XCTAssertEqual(provider.createdIDs.count, 1, "Local reference-only recovery needs no new provider mutation")
    }

    func testAutomaticResumeCannotUndoPauseAfterEarlierEnumeration() async throws {
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment) } catch {}
        XCTAssertEqual(try PendingUploadQueue.listCreations(for: id).first?.isPaused, false)
        try CloudFileCreationCoordinator.cancel(operationID: id, environment: environment)
        do { _ = try await CloudFileCreationCoordinator.resume(operationID: id, unpausing: false, environment: environment); XCTFail() }
        catch { XCTAssertEqual(error as? CloudProviderError, .authenticationCancelled) }
        XCTAssertEqual(try PendingUploadQueue.listCreations(for: id).first?.isPaused, true)
        XCTAssertEqual(provider.createdIDs.count, 1)
    }

    func testCancelBeforeDispatchRemovesOnlyUnattemptedBytes() async throws {
        let provider = CreationTestProvider()
        provider.connected = false
        let id = UUID()
        let environment = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: environment) } catch {}
        let pending = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        try CloudFileCreationCoordinator.cancel(operationID: id, environment: environment)
        XCTAssertTrue(try PendingUploadQueue.listCreations(for: id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PendingUploadQueue.resolveAppGroupURL(for: pending.payloadPath).path))
        XCTAssertTrue(provider.createdIDs.isEmpty)
    }

    func testReplacementCleanupCannotDeleteCreationCiphertext() async throws {
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        do { _ = try await create(id, provider: provider, environment: creationEnvironment(provider)) } catch {}
        let before = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        try PendingUploadQueue.removeAllMarkers(for: id)
        let after = try XCTUnwrap(PendingUploadQueue.listCreations(for: id).first)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: PendingUploadQueue.resolveAppGroupURL(for: after.payloadPath)), Data("ciphertext".utf8))
    }

    func testCompletedReplayRefusesRemovedOrModifiedRegistration() async throws {
        let provider = CreationTestProvider()
        let id = UUID()
        let environment = creationEnvironment(provider)
        let registered = try await create(id, provider: provider, environment: environment)
        try writeAtomicallyAndDurably(Data("newer-key-ciphertext".utf8), to: DatabaseListStore.cacheLocation(for: registered))
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail("Stale preparation must not unlock a newer payload") } catch {}
        DatabaseListStore.remove(id: id)
        do { _ = try await create(id, provider: provider, environment: environment); XCTFail("Replay cannot resurrect a removed reference") } catch {}
        XCTAssertEqual(provider.createdIDs.count, 1)
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == id })
    }

    func testDrainerResumesUnregisteredCreationBeforeReferenceResolution() async throws {
        let provider = CreationTestProvider()
        provider.loseNextResponse = true
        let id = UUID()
        let creation = creationEnvironment(provider)
        do { _ = try await create(id, provider: provider, environment: creation) } catch {}
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == id })
        var environment = PendingUploadDrainer.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.resumeCreation = { try await CloudFileCreationCoordinator.resume(operationID: $0, environment: creation) }
        let result = await PendingUploadDrainer(environment: environment).drain(databaseId: nil)
        XCTAssertTrue(result.drainedDatabaseIDs.contains(id))
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == id }?.cloudSyncMetadata?.fileId, provider.createdIDs.first)
        XCTAssertEqual(provider.objects.count, 1)
    }

    private func create(_ id: UUID, provider: CreationTestProvider, environment: CloudFileCreationCoordinator.Environment) async throws -> DatabaseReference {
        try await CloudFileCreationCoordinator.create(operationID: id, ownerDatabaseID: id, provider: provider.id,
            accountID: "account", target: .init(path: "vault.kdbx"), bytes: Data("ciphertext".utf8),
            referenceTemplate: creationTemplate(id: id), environment: environment)
    }
}

func creationTemplate(id: UUID) -> DatabaseReference {
    DatabaseReference(id: id, nickname: nil, filename: "vault.kdbx", bookmarkData: nil,
        keyFileBookmarkData: Data("bookmark-only".utf8), keyFileFilename: "vault.key", isQuickLaunch: false,
        lastOpenedAt: nil, addedAt: Date(timeIntervalSince1970: 100), colorTag: nil, legacyKeychainFilename: nil)
}

func creationEnvironment(_ provider: CreationTestProvider) -> CloudFileCreationCoordinator.Environment {
    var environment = CloudFileCreationCoordinator.Environment.live
    environment.queue.postDarwinNotification = { }
    environment.provider = { $0 == provider.id ? provider : nil }
    return environment
}

private final class CreationWriteFault: @unchecked Sendable {
    let phase: PendingUploadQueue.CreationIntent.Phase
    init(phase: PendingUploadQueue.CreationIntent.Phase) { self.phase = phase }
    func check(_ data: Data, url: URL) throws {
        if url.pathExtension == "creation", let intent = try? JSONDecoder().decode(PendingUploadQueue.CreationIntent.self, from: data), intent.phase == phase {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

final class CreationTestProvider: CloudProvider, @unchecked Sendable {
    let id: String
    let displayName = "Creation test"
    let iconName = "cloud"
    let generatedIDs: Bool
    let accountID: String
    private let lock = NSLock()
    private var storedObjects: [String: Data] = [:]
    private var ids: [String] = []
    private var destinations: [CloudFileCreationTarget] = []
    private var accountIDs: [String] = []
    private var losesResponse = false
    private var connection = true
    private var nextFailure: CloudUploadFailure?
    var failNext: CloudUploadFailure? { get { lock.withLock { nextFailure } } set { lock.withLock { nextFailure = newValue } } }
    private var accepted: (@Sendable () throws -> Void)?
    var objects: [String: Data] { lock.withLock { storedObjects } }
    var createdIDs: [String] { lock.withLock { ids } }
    var targets: [CloudFileCreationTarget] { lock.withLock { destinations } }
    var accounts: [String] { lock.withLock { accountIDs } }
    var connected: Bool { get { lock.withLock { connection } } set { lock.withLock { connection = newValue } } }
    var loseNextResponse: Bool { get { lock.withLock { losesResponse } } set { lock.withLock { losesResponse = newValue } } }
    var afterAcceptance: (@Sendable () throws -> Void)? { get { lock.withLock { accepted } } set { lock.withLock { accepted = newValue } } }
    init(generatedIDs: Bool = true, id: String = "googledrive", accountID: String = "account") { self.generatedIDs = generatedIDs; self.id = id; self.accountID = accountID }
    @MainActor func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount { throw CloudProviderError.authenticationCancelled }
    func isAuthenticated(accountId: String) -> Bool { connected && accountId == accountID }
    func signOut(accountId: String) { connected = false }
    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] { [] }
    func download(accountId: String, fileId: String, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata? { throw CloudProviderError.fileNotFound }
    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata { throw CloudProviderError.fileNotFound }
    func upload(accountId: String, fileId: String, data: Data, expectedRev: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata { throw CloudProviderError.writeScopeRequired }
    func prepareFileCreationID(accountId: String) async throws -> String? { generatedIDs ? "generated_" + UUID().uuidString : nil }
    func createFile(accountId: String, target: CloudFileCreationTarget, data: Data, creationID: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        let fileID = creationID ?? target.path
        let (lost, callback): (Bool, (@Sendable () throws -> Void)?) = try lock.withLock {
            ids.append(fileID); destinations.append(target); accountIDs.append(accountId)
            if let failure = nextFailure { nextFailure = nil; throw failure }
            if let prior = storedObjects[fileID], prior != data { throw CloudProviderError.conflict(remoteRev: nil) }
            storedObjects[fileID] = data
            let lost = losesResponse
            losesResponse = false
            return (lost, accepted)
        }
        try callback?()
        if lost { throw URLError(.networkConnectionLost) }
        return CloudCreatedFile(file: CloudFile(id: fileID, name: target.path, path: fileID, isFolder: false, modifiedDate: nil, size: Int64(data.count)),
            metadata: CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 100), contentHash: nil, size: Int64(data.count), rev: "1"))
    }
}
