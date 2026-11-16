#if os(macOS)
import CryptoKit
import Darwin
import Observation
import XCTest
@testable import KeeForge

private final class BridgeSocket: @unchecked Sendable {
    let fd: Int32
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in bytes.withUnsafeBytes { destination.copyMemory(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(fd) }
    func close() { shutdown(fd, SHUT_RDWR) }
    func write(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
    }
    func send(_ envelope: BrowserBridgeEnvelope) throws {
        try write(BrowserBridgeFraming.encode(BrowserBridgeJSON.encode(envelope), toward: .towardApp))
    }
    private func read(_ count: Int) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if n == 0 { return nil }
            guard n > 0 else { throw POSIXError(.EIO) }
            offset += n
        }
        return Data(bytes)
    }
    func receive() async throws -> BrowserBridgeEnvelope? {
        try await Task.detached { [self] in
            guard let prefix = try read(4) else { return nil }
            let length = prefix.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length <= BrowserBridgeFraming.maximumExtensionPayload, let payload = try read(length) else { throw POSIXError(.EIO) }
            return try BrowserBridgeJSON.decode(BrowserBridgeEnvelope.self, from: payload)
        }.value
    }
}

/// Sleepers wait until `advance()`, cancelled ones included, so tests count sleeps rather than poll.
private actor BridgeTestClock {
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var sleeps = 0
    private(set) var duration: Duration?
    func sleep(_ duration: Duration) async throws {
        self.duration = duration
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            sleeps += 1
            let ready = watchers.filter { $0.count <= sleeps }
            watchers.removeAll { $0.count <= sleeps }
            ready.forEach { $0.continuation.resume() }
        }
    }
    func waitForSleeps(_ count: Int) async {
        if sleeps >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }
    func advance() { let all = waiting; waiting = []; all.forEach { $0.resume() } }
}

@MainActor
final class MacBrowserBridgeControllerTests: XCTestCase {
    private var controller: MacBrowserBridgeController!
    private var defaults: UserDefaults!
    private var suite = ""
    private var directory: URL!
    private var store: BrowserPairingStore!
    private var keychain: FakeBrowserBridgeKeychain!
    private var sessions: [DatabaseViewModel] = []
    private var clock: BridgeTestClock!
    private var sockets: [BridgeSocket] = []
    private var path: String { directory.appendingPathComponent("b").path }

    override func setUp() async throws {
        suite = "BridgeController.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keychain = FakeBrowserBridgeKeychain()
        store = BrowserPairingStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain)
        clock = BridgeTestClock()
    }
    override func tearDown() async throws {
        controller?.stop()
        sockets.forEach { $0.close() }; sockets = []
        for session in sessions { session.lockRequest(force: true) }
        sessions = []
        await clock.advance()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        controller = nil
    }
    private func waitFor(_ predicate: @escaping @MainActor () -> Bool) async {
        let done = expectation(description: "Observed bridge state")
        Self.observe(predicate, done: done)
        await fulfillment(of: [done], timeout: 5)
    }
    private static func observe(_ predicate: @escaping @MainActor () -> Bool, done: XCTestExpectation) {
        if predicate() { done.fulfill(); return }
        withObservationTracking { _ = predicate() } onChange: {
            Task { @MainActor in Self.observe(predicate, done: done) }
        }
    }
    private func start(gate: @escaping BrowserBridgeRequestHandler.DeviceOwnerAuthenticator = { _ in true }) async {
        controller = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: path,
            appVersion: "test", sessionsProvider: { [weak self] in self?.sessions ?? [] },
            sleep: { [clock = clock!] in try await clock.sleep($0) }, authenticateDeviceOwner: gate)
        controller.isEnabled = true
        controller.start()
        await waitFor { self.controller.isListening || self.controller.unavailability != nil }
    }
    private func connect() throws -> BridgeSocket {
        let socket = try BridgeSocket(path); sockets.append(socket); return socket
    }
    private func client() -> BrowserBridgeTestClient {
        .init(key: .init(), ephemeral: .init(), nonce: Data(repeating: 9, count: 32))
    }
    private func beginPair(_ client: BrowserBridgeTestClient, _ socket: BridgeSocket) async throws -> Data {
        try socket.send(client.commit)
        let reply = try await socket.receive()
        guard case .pairKey(let app, let ephemeral) = reply else { XCTFail("Expected pair key"); throw POSIXError(.EIO) }
        try socket.send(client.reveal)
        await waitFor { self.controller.pendingPairing != nil }
        XCTAssertEqual(controller.pendingPairing?.code, client.code(app: app, appEphemeral: ephemeral))
        return app
    }
    private func pair(_ client: inout BrowserBridgeTestClient, _ socket: BridgeSocket) async throws -> Data {
        let app = try await beginPair(client, socket)
        controller.answerPairing(true)
        let result = try await socket.receive()
        XCTAssertEqual(result, .pairResult(ok: true))
        try socket.send(client.hello)
        let hello = try await socket.receive()
        try client.establish(XCTUnwrap(hello), app: app)
        return app
    }
    private func request(_ operation: BrowserBridgeRequest.Operation, id: Int, client: inout BrowserBridgeTestClient, socket: BridgeSocket) async throws -> BrowserBridgeReply.Result {
        try socket.send(client.send(.init(id: id, operation: operation)))
        let reply = try await socket.receive()
        return try client.receive(XCTUnwrap(reply)).result
    }

    private func makeSession() async throws -> (DatabaseViewModel, KPEntry) {
        let key = SymmetricKey(size: .bits256)
        let entry = KPEntry(title: "Bridge entry", username: "entry-user", password: try .encrypt("entry-password", using: key), url: "https://example.com")
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url)
        reference.autoFillEnabled = true
        let session = DatabaseViewModel(databaseReference: reference,
            reloadOperation: { reference, _ in
                .init(reference: reference, rootGroup: KPGroup(name: "Root", entries: [entry]),
                      meta: KPMeta(), formatVersion: .kdbx4(minor: 1), sessionKey: key,
                      openTimeSHA512: Data("test-hash".utf8), binaryPool: BinaryPool(rawFields: []))
            }, quickUnlockKeyPersistOperation: { _, _, _ in false },
            expressUnlockKeySaveOperation: { _, _ in }, storedKeyPresenceCheck: { _ in false },
            storedKeyStoreOperation: { _, _ in }, storedKeyDeleteOperation: { _ in },
            deviceOwnerAuthAvailabilityCheck: { false }, quickUnlockAvailabilityCheck: { false },
            secretAccess: SecretAccessGate(isAuthenticationAvailable: { false }))
        sessions.append(session)
        await session.unlock(password: "testpassword123")
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(session.state, .unlocked)
        return (session, entry)
    }

    func testRealSessionMatchesCredentialRevealAndUnlock() async throws {
        let (session, entry) = try await makeSession()
        await start()
        var reveals: [UUID] = []; var unlocks: [UUID?] = []
        controller.reveal = { reveals = [$0, $1] }
        controller.unlock = { unlocks.append($0) }
        var client = client(); let socket = try connect()
        _ = try await pair(&client, socket)
        let matches = try await request(.matches(origin: "https://example.com"), id: 1, client: &client, socket: socket)
        guard case .matches(let entries, _) = matches else { return XCTFail("Expected matches") }
        XCTAssertEqual(entries.map(\.entry), [entry.id])
        XCTAssertEqual(entries.map(\.db), [session.databaseReference.id])
        let credential = try await request(.credential(entry: entry.id, db: session.databaseReference.id, origin: "https://example.com", totp: nil), id: 2, client: &client, socket: socket)
        XCTAssertEqual(credential, .credential(username: "entry-user", password: "entry-password", totp: nil))
        let reveal = try await request(.reveal(entry: entry.id, db: session.databaseReference.id), id: 3, client: &client, socket: socket)
        XCTAssertEqual(reveal, .empty)
        XCTAssertEqual(reveals, [entry.id, session.databaseReference.id])
        for (index, id) in [session.databaseReference.id, nil].enumerated() {
            let unlock = try await request(.unlock(db: id), id: 4 + index, client: &client, socket: socket)
            XCTAssertEqual(unlock, .empty)
        }
        XCTAssertEqual(unlocks, [session.databaseReference.id, nil])
    }

    func testHeldCredentialAllowsStatusAndDisableDropsCredential() async throws {
        let (session, entry) = try await makeSession()
        let entered = expectation(description: "Device owner gate entered")
        var release: CheckedContinuation<Bool, Never>?
        await start(gate: { _ in
            await withCheckedContinuation { release = $0; entered.fulfill() }
        })
        var client = client(); let socket = try connect()
        _ = try await pair(&client, socket)
        _ = try await request(.matches(origin: "https://example.com"), id: 1, client: &client, socket: socket)
        try socket.send(client.send(.init(id: 2, operation: .credential(entry: entry.id, db: session.databaseReference.id, origin: "https://example.com", totp: nil))))
        await fulfillment(of: [entered], timeout: 5)
        let status = try await request(.status, id: 3, client: &client, socket: socket)
        XCTAssertEqual(status, .status(app: "test", unlocked: 1, locked: 0))
        controller.isEnabled = false
        release?.resume(returning: true)
        let disabled = try await socket.receive(); XCTAssertEqual(disabled, .error(.disabled))
        let eof = try await socket.receive(); XCTAssertNil(eof)
    }

    func testKeyFailureAndMissingContainerNeverListen() async throws {
        keychain.fails = true
        await start()
        XCTAssertEqual(controller.unavailability, .bridgeKey)
        XCTAssertFalse(controller.isListening)
        XCTAssertThrowsError(try BridgeSocket(path))
        controller.stop()
        controller = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: nil)
        controller.start()
        await waitFor { self.controller.unavailability != nil }
        XCTAssertEqual(controller.unavailability, .noGroupContainer)
    }

    func testLiveListenerIsPreserved() async throws {
        await start()
        let other = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: path)
        other.start()
        await waitFor { other.unavailability != nil }
        XCTAssertEqual(other.unavailability, .socketInUse)
        other.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        var client = client(); let socket = try connect(); _ = try await pair(&client, socket)
        let status = try await request(.status, id: 1, client: &client, socket: socket)
        XCTAssertEqual(status, .status(app: "test", unlocked: 0, locked: 0))
    }

    func testPairSameConnectionReconnectUnknownAndStatus() async throws {
        await start()
        var client = client(); let socket = try connect()
        let app = try await pair(&client, socket)
        let status = try await request(.status, id: 1, client: &client, socket: socket)
        XCTAssertEqual(status, .status(app: "test", unlocked: 0, locked: 0))
        let records = try await store.list()
        XCTAssertEqual(records.first?.clientID, client.id)
        await waitFor { self.controller.pairedBrowsers.first?.lastUsedAt != nil }
        XCTAssertEqual(controller.pairedBrowsers.first?.clientID, client.id)
        let next = try connect()
        try next.send(client.hello)
        let hello = try await next.receive()
        try client.establish(XCTUnwrap(hello), app: app)
        let again = try await request(.status, id: 2, client: &client, socket: next)
        XCTAssertEqual(again, status)
        let unknown = try connect()
        try unknown.send(self.client().hello)
        let rejected = try await unknown.receive()
        XCTAssertEqual(rejected, .error(.unpaired))
        // Pairing the same public key again replaces its record.
        var repeated = client; let repair = try connect()
        _ = try await pair(&repeated, repair)
        let replaced = try await store.list()
        XCTAssertEqual(replaced.map(\.clientID), [client.id])
    }

    func testDeclineTimeoutCloseAndPairingAdmission() async throws {
        await start()
        let first = try connect(); let client = client()
        _ = try await beginPair(client, first)
        let pending = controller.pendingPairing
        let second = try connect(); try second.send(self.client().commit)
        let busy = try await second.receive()
        XCTAssertEqual(busy, .error(.pairingBusy))
        XCTAssertEqual(controller.pendingPairing, pending)
        controller.answerPairing(false)
        let declined = try await first.receive()
        XCTAssertEqual(declined, .error(.pairingDeclined))
        XCTAssertNil(controller.pendingPairing)
        let timeout = try connect(); _ = try await beginPair(client, timeout)
        await clock.waitForSleeps(2)
        let duration = await clock.duration
        XCTAssertEqual(duration, .seconds(120))
        await clock.advance()
        let timedOut = try await timeout.receive()
        XCTAssertEqual(timedOut, .error(.pairingDeclined))
        XCTAssertNil(controller.pendingPairing)
        let closing = try connect(); _ = try await beginPair(client, closing)
        closing.close()
        await waitFor { self.controller.pendingPairing == nil }
        controller.answerPairing(true)
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
    }

    func testDisableTwoConnectionsRestartStopAndRemove() async throws {
        await start()
        var a = client(); let one = try connect(); let app = try await pair(&a, one)
        var b = client(); let two = try connect(); let bApp = try await pair(&b, two)
        controller.isEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        for socket in [one, two] {
            let disabled = try await socket.receive(); XCTAssertEqual(disabled, .error(.disabled))
            let eof = try await socket.receive(); XCTAssertNil(eof)
        }
        XCTAssertThrowsError(try BridgeSocket(path))
        controller.isEnabled = true
        await waitFor { self.controller.isListening }
        let three = try connect(); try three.send(a.hello)
        let hello = try await three.receive(); try a.establish(XCTUnwrap(hello), app: app)
        let four = try connect(); try four.send(b.hello)
        let bHello = try await four.receive(); try b.establish(XCTUnwrap(bHello), app: bApp)
        try await controller.removeBrowser(clientID: a.id)
        let closed = try await three.receive(); XCTAssertNil(closed)
        let unknown = try connect(); try unknown.send(a.hello)
        let unpaired = try await unknown.receive(); XCTAssertEqual(unpaired, .error(.unpaired))
        let alive = try await request(.status, id: 5, client: &b, socket: four)
        XCTAssertEqual(alive, .status(app: "test", unlocked: 0, locked: 0))
        let instant = ContinuousClock.now
        controller.stop()
        XCTAssertLessThan(ContinuousClock.now - instant, .seconds(1))
        controller.start(); await waitFor { self.controller.isListening }
        try await controller.removeAllBrowsers()
        XCTAssertGreaterThan(keychain.deletions, 0)
        XCTAssertTrue(controller.pairedBrowsers.isEmpty)
    }

    func testTwoCommittedPairingsKeepFirstPendingAndAllowIt() async throws {
        await start()
        var first = client(); let one = try connect()
        let second = client(); let two = try connect()
        try one.send(first.commit)
        let key = try await one.receive()
        guard case .pairKey(let app, _) = key else { return XCTFail("Expected pair key") }
        try two.send(second.commit)
        let secondKey = try await two.receive()
        guard case .pairKey = secondKey else { return XCTFail("Expected second commitment accepted") }
        try one.send(first.reveal)
        await waitFor { self.controller.pendingPairing != nil }
        let pending = controller.pendingPairing
        try two.send(second.reveal)
        let rejected = try await two.receive()
        XCTAssertEqual(rejected, .error(.pairingDeclined))
        XCTAssertEqual(controller.pendingPairing, pending)
        controller.answerPairing(true)
        let allowed = try await one.receive(); XCTAssertEqual(allowed, .pairResult(ok: true))
        try one.send(first.hello)
        let hello = try await one.receive(); try first.establish(XCTUnwrap(hello), app: app)
        let status = try await request(.status, id: 1, client: &first, socket: one)
        XCTAssertEqual(status, .status(app: "test", unlocked: 0, locked: 0))
        let records = try await store.list()
        XCTAssertEqual(records.map(\.clientID), [first.id])
    }

    func testRemoveAllClosesEveryConnectionAndReplacesInstallationKey() async throws {
        await start()
        var a = client(); let one = try connect(); _ = try await pair(&a, one)
        var b = client(); let two = try connect(); _ = try await pair(&b, two)
        let oldKey = try keychain.readPrivateKey()
        try await controller.removeAllBrowsers()
        XCTAssertGreaterThan(keychain.deletions, 0)
        for socket in [one, two] {
            let disabled = try await socket.receive(); XCTAssertEqual(disabled, .error(.disabled))
            let eof = try await socket.receive(); XCTAssertNil(eof)
        }
        await waitFor { self.controller.isListening }
        let newKey = try keychain.readPrivateKey()
        XCTAssertNotNil(newKey)
        XCTAssertNotEqual(oldKey, newKey)
        let records = try await store.list(); XCTAssertTrue(records.isEmpty)
        let socket = try connect(); try socket.send(a.hello)
        let unpaired = try await socket.receive(); XCTAssertEqual(unpaired, .error(.unpaired))
    }

    func testPersistenceFailureDoesNotEstablish() async throws {
        await start()
        let socket = try connect(); let client = client()
        _ = try await beginPair(client, socket)
        SettingsService.setBrowserBridgePairings(Data([0]), in: defaults)
        controller.answerPairing(true)
        let closed = try await socket.receive(); XCTAssertNil(closed)
        XCTAssertTrue(controller.pairingFailed)
        XCTAssertNil(controller.unavailability)
        XCTAssertNil(controller.pendingPairing)
        SettingsService.setBrowserBridgePairings(nil, in: defaults)
        let next = try connect(); try next.send(client.hello)
        let unpaired = try await next.receive(); XCTAssertEqual(unpaired, .error(.unpaired))
    }

    func testHostOversizeSecondHelloAndConnectionCap() async throws {
        await start()
        let host = try connect(); try host.send(.host)
        let rejected = try await host.receive(); XCTAssertEqual(rejected, .error(.badRequest))
        let hostClosed = try await host.receive(); XCTAssertNil(hostClosed)
        let oversize = try connect(); try oversize.write(Data([1, 0, 1, 0]))
        let eof = try await oversize.receive(); XCTAssertNil(eof)
        var client = client(); let established = try connect(); _ = try await pair(&client, established)
        try established.send(client.hello)
        let second = try await established.receive(); XCTAssertEqual(second, .error(.badRequest))
        let secondClosed = try await established.receive(); XCTAssertNil(secondClosed)
        controller.stop(); controller.start()
        await waitFor { self.controller.isListening }
        // A response barrier proves each connection has been accepted before the next connect.
        var live: [BridgeSocket] = []
        for _ in 0..<64 {
            let socket = try connect()
            try socket.send(client.commit)
            let response = try await socket.receive()
            guard case .pairKey = response else { return XCTFail("Expected accepted connection") }
            live.append(socket)
        }
        let extra = try connect()
        let refused = try await extra.receive(); XCTAssertNil(refused)
        let stopTime = ContinuousClock.now
        controller.stop()
        XCTAssertLessThan(ContinuousClock.now - stopTime, .seconds(1))
        XCTAssertEqual(live.count, 64)
    }
}
#endif
