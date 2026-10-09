#if os(macOS)
import AppKit
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
    /// The agent's settings go to a suite of this run's own, so the tests
    /// leave the agent a developer set up in the hosting app alone.
    private let defaultsSuiteName = "MacSSHAgentControllerTests.\(UUID().uuidString)"

    private let ed25519EntryID = UUID()
    private let rsaEntryID = UUID()
    private let protectedEntryID = UUID()
    private let legacyEntryID = UUID()

    private var session: DatabaseViewModel?
    private var controller: MacSSHAgentController?
    private var socketDirectory: URL?
    private var defaults: UserDefaults?
    private let notificationCenter = NotificationCenter()

    override func setUp() async throws {
        try await super.setUp()
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    override func tearDown() async throws {
        controller?.stop()
        controller = nil
        session?.lockRequest(force: true)
        session = nil
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
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
        let defaults = try XCTUnwrap(defaults)
        let appEnabled = UserDefaults.standard.object(forKey: enabledDefaultsKey) as? NSObject
        let appSelection = UserDefaults.standard.object(forKey: selectionDefaultsKey) as? NSObject
        let controller = try makeController()
        let databaseA = UUID()
        let databaseB = UUID()
        let entryID = UUID()

        controller.setSelected(true, entryID: entryID, inDatabase: databaseA)
        controller.isEnabled = true

        XCTAssertTrue(controller.isSelected(entryID: entryID, inDatabase: databaseA))
        XCTAssertFalse(controller.isSelected(entryID: entryID, inDatabase: databaseB))
        let relaunched = MacSSHAgentController(socketPath: controller.socketPath, defaults: defaults)
        XCTAssertTrue(relaunched.isSelected(entryID: entryID, inDatabase: databaseA))
        XCTAssertTrue(relaunched.isEnabled)

        controller.setSelected(false, entryID: entryID, inDatabase: databaseA)

        XCTAssertTrue(SettingsService.macSSHAgentSelectedEntryIDs(in: defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: selectionDefaultsKey))
        XCTAssertEqual(UserDefaults.standard.object(forKey: enabledDefaultsKey) as? NSObject, appEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: selectionDefaultsKey) as? NSObject, appSelection)
    }

    /// The key list names entries and fingerprints in a window that gets no
    /// privacy cover, so it is concealed for as long as another app is in front.
    func testKeyListIsConcealedWhileAnotherAppIsFrontmost() throws {
        let controller = try makeController()
        controller.start()

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(controller.concealsKeyList)

        notificationCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(controller.concealsKeyList)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(controller.concealsKeyList)
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

    /// The agent against OpenSSH's own tools instead of this suite's client:
    /// `ssh-add -L` lists the chosen keys, and `ssh-keygen -Y sign` gets a
    /// signature for each that `ssh-keygen` itself accepts. RSA goes through
    /// the SHA-2 flags the real client sets.
    func testOpenSSHToolsListAndSignThroughTheAgent() async throws {
        // A sandboxed test host cannot hand its container socket to a tool.
        try XCTSkipIf(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        let tools = ["/usr/bin/ssh-add", "/usr/bin/ssh-keygen"]
        try XCTSkipUnless(tools.allSatisfy(FileManager.default.isExecutableFile(atPath:)))

        let session = try await makeUnlockedSession()
        let controller = try makeController()
        controller.setSelected(true, entryID: ed25519EntryID, inDatabase: session.databaseReference.id)
        controller.setSelected(true, entryID: rsaEntryID, inDatabase: session.databaseReference.id)
        controller.isEnabled = true
        controller.start()
        let socketPath = controller.socketPath
        let directory = try XCTUnwrap(socketDirectory)

        let listed = try await Self.runTool("/usr/bin/ssh-add", ["-L"], socketPath: socketPath)
        XCTAssertEqual(listed.status, 0, listed.output)
        XCTAssertTrue(listed.output.contains("ssh-ed25519 \(Keys.ed25519.publicKeyBlob)"), listed.output)
        XCTAssertTrue(listed.output.contains("ssh-rsa \(Keys.rsa.publicKeyBlob)"), listed.output)

        for (name, publicKey) in [
            ("ed25519", "ssh-ed25519 \(Keys.ed25519.publicKeyBlob)"),
            ("rsa", "ssh-rsa \(Keys.rsa.publicKeyBlob)"),
        ] {
            let publicKeyFile = directory.appendingPathComponent("\(name).pub")
            let message = directory.appendingPathComponent("\(name).txt")
            try Data("\(publicKey)\n".utf8).write(to: publicKeyFile)
            try Keys.message.write(to: message)

            let signed = try await Self.runTool(
                "/usr/bin/ssh-keygen",
                ["-Y", "sign", "-U", "-f", publicKeyFile.path, "-n", "keeforge-test", message.path],
                socketPath: socketPath
            )
            XCTAssertEqual(signed.status, 0, "\(name): \(signed.output)")

            let checked = try await Self.runTool(
                "/usr/bin/ssh-keygen",
                ["-Y", "check-novalidate", "-n", "keeforge-test", "-s", message.path + ".sig"],
                socketPath: socketPath,
                input: Keys.message
            )
            XCTAssertEqual(checked.status, 0, "\(name): \(checked.output)")
        }

        session.lockRequest(force: true)

        let locked = try await Self.runTool("/usr/bin/ssh-add", ["-L"], socketPath: socketPath)
        XCTAssertFalse(locked.output.contains(Keys.ed25519.publicKeyBlob), locked.output)
        XCTAssertFalse(locked.output.contains(Keys.rsa.publicKeyBlob), locked.output)
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

    /// Every connection costs the app a thread, so only so many are open at
    /// once. A client that holds its place without using it, whichever way
    /// it stalls, gives the place up as soon as another client needs it.
    func testAStalledConnectionGivesItsPlaceToANewOne() async throws {
        let controller = try makeController()
        let path = controller.socketPath
        let server = SSHAgentSocketServer(path: path, handler: SSHAgentRequestHandler { [] }, maximumConnections: 1)
        try server.start()
        defer { server.stop() }

        let request = Self.requestIdentities
        try await Task.detached {
            let stalls: [(name: String, stall: (Int32) throws -> Void)] = [
                ("sends nothing", { _ in }),
                ("stops inside a message", { try SSHAgentTestClient.send(Data([0, 0, 0]), on: $0) }),
                ("never reads its answers", { try SSHAgentTestClient.sendWithoutReading(request, count: 4000, on: $0) }),
            ]
            for (name, stall) in stalls {
                let stalled = try SSHAgentTestClient.connect(at: path)
                defer { close(stalled) }
                try stall(stalled)

                XCTAssertEqual(try SSHAgentTestClient.exchange([request], at: path).count, 1, name)
                XCTAssertTrue(SSHAgentTestClient.isClosedByTheAgent(stalled), name)
            }
        }.value
    }

    /// Past the limit, the connection that has gone longest without a
    /// request is the one that makes room.
    func testTheConnectionIdleLongestMakesRoomPastTheLimit() async throws {
        let controller = try makeController()
        let path = controller.socketPath
        let server = SSHAgentSocketServer(path: path, handler: SSHAgentRequestHandler { [] }, maximumConnections: 2)
        try server.start()
        defer { server.stop() }

        let request = Self.requestIdentities
        try await Task.detached {
            let first = try SSHAgentTestClient.connect(at: path)
            let second = try SSHAgentTestClient.connect(at: path)
            defer { close(first); close(second) }
            XCTAssertEqual(try SSHAgentTestClient.exchange([request], on: first).count, 1)
            XCTAssertEqual(try SSHAgentTestClient.exchange([request], on: second).count, 1)
            XCTAssertEqual(try SSHAgentTestClient.exchange([request], on: first).count, 1)

            let third = try SSHAgentTestClient.connect(at: path)
            defer { close(third) }
            XCTAssertEqual(try SSHAgentTestClient.exchange([request], on: third).count, 1)

            XCTAssertTrue(SSHAgentTestClient.isClosedByTheAgent(second))
            XCTAssertEqual(try SSHAgentTestClient.exchange([request], on: first).count, 1)
        }.value
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
            defaults: try XCTUnwrap(defaults),
            notificationCenter: notificationCenter,
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

    /// Runs an OpenSSH tool pointed at the agent, off the main actor, which
    /// the agent needs to read the session.
    private static func runTool(
        _ path: String,
        _ arguments: [String],
        socketPath: String,
        input: Data? = nil
    ) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ["SSH_AUTH_SOCK": socketPath, "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(input)
            }
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
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
        let descriptor = try connect(at: path)
        defer { close(descriptor) }
        return try exchange(requests, on: descriptor)
    }

    /// An open connection the caller closes.
    static func connect(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(errno: errno) }
        var address = Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = Failure(errno: errno)
            close(descriptor)
            throw failure
        }
        // Fail the test rather than hang it if the agent never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSIGPIPE: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func exchange(_ requests: [Data], on descriptor: Int32) throws -> [Data] {
        try requests.map { request in
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

    /// Bytes that are not a whole message, with no answer to wait for.
    static func send(_ data: Data, on descriptor: Int32) throws {
        try write(data, to: descriptor)
    }

    /// Sends `request` until the socket takes no more, reading no answer, so
    /// the agent ends up blocked writing to a client that does not listen.
    static func sendWithoutReading(_ request: Data, count: Int, on descriptor: Int32) throws {
        var receiveBuffer: Int32 = 4096
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var framed = SSHWireWriter()
        framed.writeString(request)
        let bytes = [UInt8](framed.data)
        for _ in 0 ..< count {
            let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard result == bytes.count else {
                if result < 0, errno == EAGAIN { return }
                throw Failure(errno: errno)
            }
        }
    }

    /// Whether the agent ended the connection: end of stream once whatever
    /// it had already sent is read. False when the read times out instead.
    static func isClosedByTheAgent(_ descriptor: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let result = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if result == 0 || (result < 0 && errno == ECONNRESET) {
                return true
            }
            if result < 0, errno != EINTR {
                return false
            }
        }
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
