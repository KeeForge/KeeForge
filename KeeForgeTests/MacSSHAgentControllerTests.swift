#if os(macOS)
import CryptoKit
import Darwin
import XCTest
@testable import KeeForge

/// The SSH agent against a real unlocked session: which entries it serves,
/// the lock lifecycle, the per-database selection, and a round trip through
/// the socket an SSH client connects to.
@MainActor
final class MacSSHAgentControllerTests: XCTestCase {
    private typealias Keys = SSHAgentTestKeys

    private let fixturePassword = "testpassword123"
    private let enabledDefaultsKey = "KeeForge.macSSHAgentEnabled"
    private let selectionDefaultsKey = "KeeForge.macSSHAgentSelectedEntryIDs"

    private let ed25519EntryID = UUID()
    private let rsaEntryID = UUID()
    private let protectedEntryID = UUID()
    private let legacyEntryID = UUID()

    private var session: DatabaseViewModel?
    private var controller: MacSSHAgentController?
    private var socketDirectory: URL?

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: enabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: selectionDefaultsKey)
    }

    override func tearDown() async throws {
        controller?.stop()
        controller = nil
        session?.lockRequest(force: true)
        session = nil
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        UserDefaults.standard.removeObject(forKey: enabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: selectionDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - What the agent offers

    func testAgentIsOffByDefaultAndOffersNothing() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.keySources().isEmpty)
    }

    func testOffersOnlyTheChosenEntriesOfTheUnlockedSession() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true

        XCTAssertTrue(controller.keySources().isEmpty, "Nothing is chosen yet")

        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        controller.setSelected(true, entryID: UUID(), inDatabase: session.databaseReference.id)

        let sources = controller.keySources()
        XCTAssertEqual(sources.map(\.entryID), [ed25519EntryID])
        XCTAssertEqual(sources.first?.lease.lockCycleID, session.lockCycleID)
        XCTAssertEqual(sources.first?.privateKeyFile, Keys.ed25519.fileData)
    }

    func testChoiceForAnotherDatabaseOffersNothing() async throws {
        _ = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true

        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: UUID())

        XCTAssertTrue(controller.keySources().isEmpty)
    }

    func testTurningTheAgentOffWithdrawsItsKeys() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        XCTAssertFalse(controller.keySources().isEmpty)

        controller.isEnabled = false

        XCTAssertTrue(controller.keySources().isEmpty)
    }

    func testLockingTheDatabaseWithdrawsItsKeysImmediately() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        let handler = SSHAgentRequestHandler {
            MainActor.assumeIsolated { controller.keySources() }
        }
        XCTAssertEqual(try Self.identities(in: handler.response(to: Self.requestIdentities)), [Keys.ed25519.publicKeyData])

        session.lockRequest(force: true)

        XCTAssertTrue(controller.keySources().isEmpty)
        XCTAssertEqual(try Self.identities(in: handler.response(to: Self.requestIdentities)), [])
        XCTAssertEqual(handler.response(to: Self.signRequest(for: Keys.ed25519.publicKeyData)), Self.failure)
    }

    func testClosingTheDatabaseWithdrawsItsKeys() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        XCTAssertFalse(controller.keySources().isEmpty)

        controller.sessionProvider = { nil }

        XCTAssertTrue(controller.keySources().isEmpty)
    }

    /// Unsaved work can defer a lock indefinitely; the agent treats the
    /// requested lock as already done.
    func testLockWaitingOnUnsavedWorkWithdrawsTheKeys() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.isEnabled = true
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        let editorID = UUID()
        session.setEditorHasUnsavedChanges(true, editorID: editorID)
        defer { session.setEditorHasUnsavedChanges(false, editorID: editorID) }

        session.lockRequest()

        XCTAssertEqual(session.state, .unlocked)
        XCTAssertNotNil(session.pendingLockRequest)
        XCTAssertTrue(controller.keySources().isEmpty)
    }

    // MARK: - Settings

    func testCandidatesDescribeEveryEntryWithAPrivateKey() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()

        let candidates = await controller.candidates(in: session)

        XCTAssertEqual(candidates.map(\.id), [rsaEntryID, ed25519EntryID, legacyEntryID, protectedEntryID])
        XCTAssertEqual(candidates.map(\.title), ["Build Server", "Laptop", "Legacy Key", "Old Key"])
        XCTAssertEqual(candidates.map(\.status), [
            .supported(algorithm: "RSA 2048", fingerprint: Keys.rsa.fingerprint),
            .supported(algorithm: "Ed25519", fingerprint: Keys.ed25519.fingerprint),
            .unsupported,
            .passphraseProtected,
        ])
    }

    func testLockedSessionHasNoCandidates() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        session.lockRequest(force: true)

        let candidates = await controller.candidates(in: session)

        XCTAssertTrue(candidates.isEmpty)
    }

    func testChoicesAreKeptPerDatabaseAndPersist() throws {
        let controller = try makeController()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryID = UUID()

        controller.setSelected(true, entryID: entryID, inDatabase: databaseA)

        XCTAssertTrue(controller.isSelected(entryID: entryID, inDatabase: databaseA))
        XCTAssertFalse(controller.isSelected(entryID: entryID, inDatabase: databaseB))
        let relaunched = MacSSHAgentController(socketPath: controller.socketPath)
        XCTAssertTrue(relaunched.isSelected(entryID: entryID, inDatabase: databaseA))
        XCTAssertFalse(relaunched.isEnabled)

        controller.setSelected(false, entryID: entryID, inDatabase: databaseA)

        XCTAssertTrue(SettingsService.macSSHAgentSelectedEntryIDs.isEmpty)
        XCTAssertNil(UserDefaults.standard.object(forKey: selectionDefaultsKey))
    }

    // MARK: - Socket

    func testSSHClientRoundTripEndsWhenTheDatabaseLocks() async throws {
        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        controller.isEnabled = true
        controller.start()
        let path = controller.socketPath

        XCTAssertFalse(controller.isUnavailable)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let unlocked = try await Self.exchange([Self.requestIdentities, Self.signRequest(for: Keys.ed25519.publicKeyData)], at: path)
        XCTAssertEqual(try Self.identities(in: unlocked[0]), [Keys.ed25519.publicKeyData])
        XCTAssertTrue(try Self.isValidEd25519Signature(unlocked[1]))

        session.lockRequest(force: true)

        let locked = try await Self.exchange([Self.requestIdentities, Self.signRequest(for: Keys.ed25519.publicKeyData)], at: path)
        XCTAssertEqual(try Self.identities(in: locked[0]), [])
        XCTAssertEqual(locked[1], Self.failure)
    }

    func testTurningTheAgentOffRemovesTheSocket() async throws {
        let controller = try makeController()
        controller.isEnabled = true
        controller.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.socketPath))

        controller.isEnabled = false

        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.socketPath))
        XCTAssertFalse(controller.isUnavailable)
    }

    /// A run that ends without stopping the agent leaves its socket file
    /// behind with nobody listening.
    func testStaleSocketFromAnEarlierRunIsReplaced() async throws {
        let controller = try makeController()
        try SSHAgentTestClient.leaveStaleSocket(at: controller.socketPath)
        XCTAssertThrowsError(try SSHAgentTestClient.exchange([Self.requestIdentities], at: controller.socketPath))

        controller.isEnabled = true
        controller.start()

        XCTAssertFalse(controller.isUnavailable)
        let answer = try await Self.exchange([Self.requestIdentities], at: controller.socketPath)
        XCTAssertEqual(try Self.identities(in: answer[0]), [])
    }

    func testSomethingElseAtTheSocketPathIsLeftAlone() throws {
        let controller = try makeController()
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: controller.socketPath))

        controller.isEnabled = true
        controller.start()

        XCTAssertTrue(controller.isUnavailable)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: controller.socketPath)), Data("keep me".utf8))
    }

    // MARK: - Helpers

    private static let requestIdentities = Data([SSHAgentRequestHandler.MessageType.requestIdentities.rawValue])
    private static let failure = Data([SSHAgentRequestHandler.MessageType.failure.rawValue])

    private func makeUnlockedSession() async throws -> DatabaseViewModel {
        let pool = [
            Keys.ed25519.fileData,
            Keys.rsa.fileData,
            Keys.ed25519PassphraseProtected.fileData,
            Data(Keys.rsaTraditionalPEM.utf8),
            Data("plain notes".utf8),
        ]
        let entries = [
            KPEntry(id: ed25519EntryID, title: "Laptop", attachments: [KPAttachment(name: "id_ed25519", ref: 0)]),
            KPEntry(id: rsaEntryID, title: "Build Server", attachments: [KPAttachment(name: "id_rsa", ref: 1)]),
            KPEntry(id: protectedEntryID, title: "Old Key", attachments: [KPAttachment(name: "id_old", ref: 2)]),
            KPEntry(id: legacyEntryID, title: "Legacy Key", attachments: [KPAttachment(name: "id_legacy", ref: 3)]),
            KPEntry(title: "Notes", attachments: [KPAttachment(name: "notes.txt", ref: 4)]),
            KPEntry(title: "No Attachments"),
        ]
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: url),
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference,
                    rootGroup: KPGroup(name: "Root", entries: entries),
                    meta: KPMeta(recycleBinUUID: nil, hasRecycleBinUUIDElement: false),
                    formatVersion: .kdbx4(minor: 1),
                    sessionKey: SymmetricKey(size: .bits256),
                    openTimeSHA512: Data("injected-tree-hash".utf8),
                    binaryPool: BinaryPool(rawFields: pool.map { Data([0x01]) + $0 })
                )
            }
        )
        self.session = session
        await session.unlock(password: fixturePassword)
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(session.state, .unlocked)
        return session
    }

    private func makeController() throws -> MacSSHAgentController {
        // Short, because a socket path must fit in `sockaddr_un.sun_path`.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kf-ssh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let controller = MacSSHAgentController(
            socketPath: directory.appendingPathComponent("agent.sock").path,
            sessionProvider: { [weak self] in self?.session }
        )
        self.controller = controller
        return controller
    }

    private static func signRequest(for publicKeyBlob: Data) -> Data {
        var writer = SSHWireWriter()
        writer.writeByte(SSHAgentRequestHandler.MessageType.signRequest.rawValue)
        writer.writeString(publicKeyBlob)
        writer.writeString(Keys.message)
        writer.writeUInt32(0)
        return writer.data
    }

    private static func identities(in response: Data) throws -> [Data] {
        var reader = SSHWireReader(response)
        guard try reader.readByte() == SSHAgentRequestHandler.MessageType.identitiesAnswer.rawValue else {
            throw SSHAgentKeyError.malformed
        }
        let count = try reader.readUInt32()
        var blobs: [Data] = []
        for _ in 0 ..< count {
            blobs.append(try reader.readString())
            _ = try reader.readString()
        }
        return blobs
    }

    private static func isValidEd25519Signature(_ response: Data) throws -> Bool {
        var reader = SSHWireReader(response)
        guard try reader.readByte() == SSHAgentRequestHandler.MessageType.signResponse.rawValue else { return false }
        var signature = SSHWireReader(try reader.readString())
        _ = try signature.readString()
        let bytes = try signature.readString()
        var publicKey = SSHWireReader(Keys.ed25519.publicKeyData)
        _ = try publicKey.readString()
        return try Curve25519.Signing.PublicKey(rawRepresentation: try publicKey.readString())
            .isValidSignature(bytes, for: Keys.message)
    }

    /// Sends each request over one connection, the way `ssh` talks to an
    /// agent. Runs off the main actor, which the agent needs to read the session.
    private static func exchange(_ requests: [Data], at path: String) async throws -> [Data] {
        try await Task.detached {
            try SSHAgentTestClient.exchange(requests, at: path)
        }.value
    }
}

/// A blocking SSH agent client over the agent's Unix-domain socket.
private enum SSHAgentTestClient {
    struct Failure: Error {
        let errno: Int32
    }

    static func exchange(_ requests: [Data], at path: String) throws -> [Data] {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(errno: errno) }
        defer { close(descriptor) }

        var address = Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure(errno: errno) }
        // Fail the test rather than hang it if the agent never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return try requests.map { request in
            var framed = SSHWireWriter()
            framed.writeString(request)
            try write(framed.data, to: descriptor)
            let length = try read(4, from: descriptor).reduce(0) { $0 << 8 | Int($1) }
            return try read(length, from: descriptor)
        }
    }

    /// Binds a socket file at `path` and closes it without listening.
    static func leaveStaleSocket(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(errno: errno) }
        defer { close(descriptor) }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Failure(errno: errno) }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return address
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress.map { Darwin.write(descriptor, $0 + sent, bytes.count - sent) } ?? -1
            }
            guard result > 0 else { throw Failure(errno: errno) }
            sent += result
        }
    }

    private static func read(_ count: Int, from descriptor: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = buffer.withUnsafeMutableBytes { bytes in
                bytes.baseAddress.map { Darwin.read(descriptor, $0 + received, count - received) } ?? -1
            }
            guard result > 0 else { throw Failure(errno: errno) }
            received += result
        }
        return Data(buffer)
    }
}
#endif
