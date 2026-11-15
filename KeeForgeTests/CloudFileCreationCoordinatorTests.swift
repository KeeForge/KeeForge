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
