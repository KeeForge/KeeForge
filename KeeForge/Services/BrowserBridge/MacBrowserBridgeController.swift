#if os(macOS)
import CryptoKit
import Foundation
import Observation
import os

/// The bridge's monotonic clock; tests inject one they advance by hand.
struct BrowserBridgeClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = BrowserBridgeClock(now: { .now }, sleep: { try await Task.sleep(until: $0, clock: .continuous) })
}

/// Owns the browser bridge socket while the bridge is started and switched on,
/// and the paired browsers and pending pairing that Settings shows.
@MainActor @Observable
final class MacBrowserBridgeController {
    typealias SessionsProvider = BrowserBridgeRequestHandler.SessionsProvider
    static let pairingAnswerTimeout: Duration = .seconds(120)
    static let sendTimeout: Duration = .seconds(5)

    enum Unavailability: Equatable {
        case noGroupContainer
        /// Another listener, such as a second copy of KeeForge, serves the path.
        case socketInUse
        /// The socket path in the group container is longer than a socket address holds.
        case pathTooLong
        /// The bridge key could not be read from or created in the Keychain.
        case bridgeKey
        case failed
    }

    struct PendingPairing: Identifiable, Equatable {
        let id: UUID
        let browserName: String
        let code: String
    }

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            SettingsService.setBrowserBridgeEnabled(isEnabled, in: defaults)
            restart()
        }
    }
    /// Why the socket is not listening while the bridge is started and switched on.
    private(set) var unavailability: Unavailability?
    private(set) var isListening = false
    private(set) var pairedBrowsers: [PairedBrowser] = []
    private(set) var pendingPairing: PendingPairing?
    /// An allowed pairing could not be saved; cleared by the next pairing request or by Settings.
    private(set) var pairingFailed = false

    @ObservationIgnored var sessionsProvider: SessionsProvider
    @ObservationIgnored var reveal: @MainActor (UUID, UUID) -> Void
    @ObservationIgnored var unlock: @MainActor (UUID?) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: BrowserPairingStore
    @ObservationIgnored private let socketPath: String?
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let clock: BrowserBridgeClock
    @ObservationIgnored private let pairingGate: BrowserPairingGate
    @ObservationIgnored private let authenticate: BrowserBridgeRequestHandler.DeviceOwnerAuthenticator
    @ObservationIgnored private var started = false
    /// Bumped whenever the runtime ends; late callbacks from an older one are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listRevision = 0
    @ObservationIgnored private var runtime: BrowserBridgeRuntime?
    @ObservationIgnored private var server: LocalSocketServer?
    @ObservationIgnored private var pairing: (connection: BrowserBridgeConnection, key: Data, timeout: Task<Void, Never>)?
    @ObservationIgnored private var pairingWrite: Task<Void, Never>?
    @ObservationIgnored private var handlers: [UUID: BrowserBridgeRequestHandler] = [:]
    @ObservationIgnored private var requestTasks: [UUID: [UUID: Task<Void, Never>]] = [:]

    init(
        defaults: UserDefaults = .standard,
        store: BrowserPairingStore = BrowserPairingStore(),
        socketPath: String? = BrowserBridgeIdentifiers.socketURL()?.path,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        sessionsProvider: @escaping SessionsProvider = { [] },
        clock: BrowserBridgeClock = .continuous,
        reveal: @escaping @MainActor (UUID, UUID) -> Void = { _, _ in },
        unlock: @escaping @MainActor (UUID?) -> Void = { _ in },
        authenticateDeviceOwner: @escaping BrowserBridgeRequestHandler.DeviceOwnerAuthenticator = BrowserBridgeRequestHandler.deviceOwnerGate
    ) {
        self.defaults = defaults
        self.store = store
        self.socketPath = socketPath
        self.appVersion = appVersion
        self.sessionsProvider = sessionsProvider
        self.clock = clock
        pairingGate = BrowserPairingGate(now: clock.now)
        self.reveal = reveal
        self.unlock = unlock
        authenticate = authenticateDeviceOwner
        isEnabled = SettingsService.browserBridgeEnabled(in: defaults)
    }

    func start() {
        guard !started else { return }
        started = true
        restart()
    }

    /// Returns at once; open connections get `disabled` and close on their own queues.
    func stop() {
        started = false
        endRuntime()
    }

    /// An answer for any pairing but the pending one is ignored.
    func answerPairing(id: UUID, allow: Bool) {
        guard let pending = pendingPairing, pending.id == id, let pairing else { return }
        let connection = pairing.connection
        let key = pairing.key
        clearPairing()
        guard allow else { connection.answer(false); return }
        let token = generation
        let runtime = runtime
        // The connection keeps the pairing slot until it is answered or closes.
        pairingWrite = Task { [weak self, store] in
            let browser = PairedBrowser(clientID: BrowserBridgeCrypto.clientID(key), publicKey: key,
                                        name: pending.browserName, pairedAt: Date())
            do {
                try await store.addOrReplace(browser)
            } catch {
                guard let self, self.generation == token else { return }
                self.pairingFailed = true
                connection.close()
                return
            }
            guard let self, self.generation == token else { return }
            // The extension may send `hello` right after `pair-result`, on this or another connection.
            runtime?.add(clientID: browser.clientID, publicKey: key)
            connection.answer(true)
            await self.refreshBrowsers()
        }
    }

    /// Settings calls this when it is shown again, so a failure is reported once.
    func clearPairingFailure() {
        pairingFailed = false
    }

    /// Closes the browser's connections; its next `hello` is `unpaired`.
    func removeBrowser(clientID: String) async throws {
        await pairingWrite?.value
        closeConnections(of: clientID)
        do {
            try await store.remove(clientID: clientID)
        } catch {
            await refreshBrowsers()
            throw error
        }
        // A runtime that started while the record was being removed may have loaded it.
        closeConnections(of: clientID)
        await refreshBrowsers()
    }

    /// Removes every pairing and the bridge key; the next start creates a new key.
    func removeAllBrowsers() async throws {
        endRuntime()
        await pairingWrite?.value
        defer { restart() }
        try await store.reset()
        listRevision += 1
        pairedBrowsers = []
    }

    private func closeConnections(of clientID: String) {
        for connection in runtime?.remove(clientID: clientID) ?? [] {
            retireHandler(connection.id)
            connection.close()
        }
    }

    private func refreshBrowsers() async {
        listRevision += 1
        let revision = listRevision
        guard let browsers = try? await store.list(), revision == listRevision else { return }
        pairedBrowsers = browsers
    }

    private func endRuntime() {
        generation += 1
        clearPairing()
        for tasks in requestTasks.values {
            for task in tasks.values { task.cancel() }
        }
        requestTasks.removeAll()
        handlers.removeAll()
        let connections = runtime?.deactivate() ?? []
        runtime = nil
        pairingGate.abandon()
        // Each connection writes `disabled` and closes itself after the file is gone.
        server?.stop(closeConnections: false)
        for connection in connections { connection.disable() }
        server = nil
        isListening = false
        unavailability = nil
    }

    private func restart() {
        endRuntime()
        guard started else { return }
        let token = generation
        let writing = pairingWrite
        Task { [weak self, store] in
            await writing?.value
            guard let self, self.generation == token else { return }
            guard self.isEnabled else { await self.refreshBrowsers(); return }
            guard let path = self.socketPath else {
                self.unavailability = .noGroupContainer
                await self.refreshBrowsers()
                return
            }
            let key: Curve25519.KeyAgreement.PrivateKey
            do {
                key = try await store.staticPrivateKey()
            } catch {
                if self.generation == token { self.unavailability = .bridgeKey }
                await self.refreshBrowsers()
                return
            }
            // Read after the key so the snapshot is current when the server starts listening.
            let browsers: [PairedBrowser]
            do {
                browsers = try await store.list()
            } catch {
                if self.generation == token { self.unavailability = .failed }
                return
            }
            guard self.generation == token else { return }
            self.listRevision += 1
            self.pairedBrowsers = browsers
            self.listen(at: path, key: key, browsers: browsers)
        }
    }

    private func listen(at path: String, key: Curve25519.KeyAgreement.PrivateKey, browsers: [PairedBrowser]) {
        let token = generation
        let runtime = BrowserBridgeRuntime(browsers: browsers, pairingGate: pairingGate)
        let appVersion = appVersion
        let clock = clock
        let framing = LocalSocketServer.Framing(byteOrder: .littleEndian,
                                                maximumInboundLength: BrowserBridgeFraming.maximumAppPayload,
                                                maximumOutboundLength: BrowserBridgeFraming.maximumExtensionPayload)
        let server = LocalSocketServer(path: path, framing: framing, refusesExcessConnections: true,
                                       sendTimeout: Self.sendTimeout) { [weak self] socket in
            BrowserBridgeConnection(socket: socket, runtime: runtime, key: key, appVersion: appVersion, clock: clock) { [weak self] connection, events, closed in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.handle(events, from: connection, closed: closed)
                }
            }
        }
        do {
            try server.start()
            self.runtime = runtime
            self.server = server
            isListening = true
        } catch LocalSocketError.socketInUse {
            unavailability = .socketInUse
        } catch LocalSocketError.pathTooLong {
            unavailability = .pathTooLong
        } catch {
            unavailability = .failed
        }
    }

    private func clearPairing() {
        pairing?.timeout.cancel()
        pairing = nil
        pendingPairing = nil
    }

    private func retireHandler(_ id: UUID) {
        handlers[id] = nil
        if let tasks = requestTasks.removeValue(forKey: id) {
            for task in tasks.values { task.cancel() }
        }
    }

    private func handle(_ events: [BrowserBridgeSession.Event], from connection: BrowserBridgeConnection, closed: Bool) {
        if closed {
            retireHandler(connection.id)
            if pairing?.connection === connection { clearPairing() }
            return
        }
        guard connection.isActive else { return }
        for event in events {
            switch event {
            case .pairingRequested(let key, let name, let code):
                // The slot was taken at commit; an alert still shown belongs to a connection that has just ended.
                guard pendingPairing == nil else { connection.refuseBusy(); continue }
                let id = UUID()
                pairingFailed = false
                pendingPairing = PendingPairing(id: id, browserName: name, code: code)
                let deadline = clock.now() + Self.pairingAnswerTimeout
                let timeout = Task { [weak self, clock] in
                    do { try await clock.sleep(deadline) } catch { return }
                    guard let self, self.pendingPairing?.id == id else { return }
                    self.clearPairing()
                    connection.timedOut()
                }
                pairing = (connection, key, timeout)
            case .established(let clientID):
                Task { [weak self, store] in
                    try? await store.touch(clientID: clientID)
                    await self?.refreshBrowsers()
                }
            case .request(let request):
                let handler = handlers[connection.id] ?? makeHandler(for: connection)
                let work = UUID()
                requestTasks[connection.id, default: [:]][work] = Task { [weak self] in
                    let reply = await handler.response(to: request)
                    self?.requestTasks[connection.id]?[work] = nil
                    guard !Task.isCancelled else { return }
                    connection.reply(reply.result, to: request)
                }
            case .paired, .pairingCancelled:
                break
            }
        }
    }

    private func makeHandler(for connection: BrowserBridgeConnection) -> BrowserBridgeRequestHandler {
        let handler = BrowserBridgeRequestHandler(
            sessionsProvider: { [weak self] in self?.sessionsProvider() ?? [] },
            appVersion: appVersion,
            reveal: { [weak self] in self?.reveal($0, $1) },
            unlock: { [weak self] in self?.unlock($0) },
            authenticateDeviceOwner: authenticate,
            now: clock.now
        )
        handlers[connection.id] = handler
        return handler
    }
}

/// The bridge's one pairing slot and its limits. It outlives each listening runtime, so
/// switching the bridge off and on resets neither. The slot is taken at `pair-commit`,
/// before any `pair-key`, so a relay gets at most `attemptLimit` code guesses a minute.
final class BrowserPairingGate: Sendable {
    static let attemptLimit = 5
    static let attemptWindow: Duration = .seconds(60)
    static let cooldown: Duration = .seconds(10)

    private struct State {
        var holder: UUID?
        var attempts: [ContinuousClock.Instant] = []
        var cooldownEnd: ContinuousClock.Instant?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    /// Counts an attempt and gives the slot to `id`, unless it is held, cooling down, or the minute's attempts are spent.
    func admit(_ id: UUID) -> Bool {
        let instant = now()
        return state.withLock { state in
            state.attempts.removeAll { instant - $0 >= Self.attemptWindow }
            guard state.holder == nil, state.cooldownEnd.map({ instant >= $0 }) ?? true,
                  state.attempts.count < Self.attemptLimit else { return false }
            state.attempts.append(instant)
            state.holder = id
            return true
        }
    }

    /// A slot freed without a pairing (declined, timed out, closed) starts the cooldown.
    func release(_ id: UUID, paired: Bool) {
        let instant = now()
        state.withLock { state in
            guard state.holder == id else { return }
            state.holder = nil
            if !paired { state.cooldownEnd = instant + Self.cooldown }
        }
    }

    /// Frees the slot of a runtime that has ended.
    func abandon() {
        let instant = now()
        state.withLock { state in
            guard state.holder != nil else { return }
            state.holder = nil
            state.cooldownEnd = instant + Self.cooldown
        }
    }
}

/// State one listening server shares with its connections' queues: the client-key
/// snapshot the session's synchronous lookup reads, and its connections.
final class BrowserBridgeRuntime: Sendable {
    private struct State {
        var active = true
        var keys: [String: Data]
        var connections: [UUID: BrowserBridgeConnection] = [:]
        var clients: [UUID: String] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    private let pairingGate: BrowserPairingGate

    init(browsers: [PairedBrowser], pairingGate: BrowserPairingGate) {
        let keys = Dictionary(browsers.map { ($0.clientID, $0.publicKey) }, uniquingKeysWith: { _, new in new })
        state = OSAllocatedUnfairLock(initialState: State(keys: keys))
        self.pairingGate = pairingGate
    }

    var isActive: Bool { state.withLock { $0.active } }
    func lookup(_ clientID: String) -> Data? { state.withLock { $0.keys[clientID] } }

    func register(_ connection: BrowserBridgeConnection) -> Bool {
        state.withLock { state in
            guard state.active else { return false }
            state.connections[connection.id] = connection
            return true
        }
    }

    /// Under the lock `deactivate` takes, so a runtime that has ended never takes the slot.
    func admitPairing(_ id: UUID) -> Bool {
        state.withLock { state in state.active && pairingGate.admit(id) }
    }

    func releasePairing(_ id: UUID, paired: Bool) {
        pairingGate.release(id, paired: paired)
    }

    /// Nil when `id` may be established; otherwise the error that ends its handshake.
    /// Checked under the lock `remove` takes, so a removed client never ends up established.
    func establish(_ id: UUID, clientID: String) -> BrowserBridgeErrorCode? {
        state.withLock { state in
            guard state.active else { return .disabled }
            guard state.keys[clientID] != nil else { return .unpaired }
            state.clients[id] = clientID
            return nil
        }
    }

    func closed(_ id: UUID) {
        state.withLock { state in
            state.connections[id] = nil
            state.clients[id] = nil
        }
        pairingGate.release(id, paired: false)
    }

    func add(clientID: String, publicKey: Data) {
        state.withLock { $0.keys[clientID] = publicKey }
    }

    /// Forgets the client and returns its established connections.
    func remove(clientID: String) -> [BrowserBridgeConnection] {
        state.withLock { state in
            state.keys[clientID] = nil
            return state.clients.filter { $0.value == clientID }.compactMap { state.connections[$0.key] }
        }
    }

    func deactivate() -> [BrowserBridgeConnection] {
        state.withLock { state in
            state.active = false
            return Array(state.connections.values)
        }
    }
}

/// One socket connection. Every session call and every write runs on `queue`.
final class BrowserBridgeConnection: LocalSocketConnectionHandler, @unchecked Sendable {
    typealias Report = @Sendable (BrowserBridgeConnection, [BrowserBridgeSession.Event], Bool) -> Void
    /// Work waiting on `queue`: a peer that stops reading stalls the writer while frames keep arriving.
    static let backlogLimit = 64
    /// How long a new connection has for `hello` or `pair-commit`, and a commitment for `pair-reveal`.
    static let handshakeDeadline: Duration = .seconds(10)

    let id: UUID
    private let runtime: BrowserBridgeRuntime
    private let socket: LocalSocketServer.Connection
    private let clock: BrowserBridgeClock
    private let queue = DispatchQueue(label: "com.keevault.app.browser-bridge.connection")
    /// Touched only on `queue`.
    private let session: BrowserBridgeSession
    private let report: Report
    private let status = OSAllocatedUnfairLock(initialState: (open: true, backlog: 0))
    private let deadlines = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])

    var isActive: Bool { runtime.isActive && status.withLock { $0.open } }

    init(socket: LocalSocketServer.Connection, runtime: BrowserBridgeRuntime, key: Curve25519.KeyAgreement.PrivateKey,
         appVersion: String, clock: BrowserBridgeClock, report: @escaping Report) {
        let id = UUID()
        self.id = id
        self.socket = socket
        self.runtime = runtime
        self.clock = clock
        self.report = report
        session = BrowserBridgeSession(appKey: key, appVersion: appVersion,
                                       lookupClient: { runtime.lookup($0) },
                                       admitPairing: { runtime.admitPairing(id) })
        guard runtime.register(self) else { close(); return }
        expire(ifStill: .fresh, at: clock.now() + Self.handshakeDeadline)
    }

    func receive(_ payload: Data) {
        enqueue { connection in
            guard connection.isActive, let frame = try? BrowserBridgeFraming.encode(payload, toward: .towardApp) else { return }
            let before = connection.session.state
            // Read before `pair-key` is written, so the deadline never starts after the peer saw it.
            let deadline = connection.clock.now() + Self.handshakeDeadline
            connection.process(connection.session.receive(frame))
            if before == .fresh, connection.session.state == .committed { connection.expire(ifStill: .committed, at: deadline) }
        }
    }

    func answer(_ allow: Bool) {
        enqueue { connection in
            guard connection.isActive, connection.session.state == .awaitingAnswer else { return }
            connection.runtime.releasePairing(connection.id, paired: allow)
            connection.process(connection.session.pairingAnswered(allow))
        }
    }

    func refuseBusy() {
        enqueue { connection in
            guard connection.isActive, connection.session.state == .awaitingAnswer else { return }
            connection.process(connection.session.refuse(.pairingBusy))
        }
    }

    func timedOut() {
        enqueue { connection in
            guard connection.isActive else { return }
            connection.process(connection.session.pairingTimedOut())
        }
    }

    func reply(_ result: BrowserBridgeReply.Result, to request: BrowserBridgeRequest) {
        enqueue { connection in
            guard connection.isActive else { return }
            connection.process(connection.session.reply(result, to: request))
        }
    }

    /// Runs after the runtime is deactivated: the only output still written then.
    /// A peer that is not reading gets no `disabled`; its connection just closes.
    func disable() {
        socket.abandonBlockedSends()
        queue.async { self.process(self.session.refuse(.disabled), disabling: true) }
    }

    func close() {
        status.withLock { $0.open = false }
        socket.close()
    }

    func connectionClosed() {
        status.withLock { $0.open = false }
        runtime.closed(id)
        deadlines.withLock { tasks in
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
        queue.async { self.process(self.session.close()) }
    }

    private func enqueue(_ work: @escaping @Sendable (BrowserBridgeConnection) -> Void) {
        let admitted = status.withLock { status -> Bool in
            guard status.backlog < Self.backlogLimit else { return false }
            status.backlog += 1
            return true
        }
        guard admitted else { close(); return }
        queue.async {
            work(self)
            self.status.withLock { $0.backlog -= 1 }
        }
    }

    /// Closes the connection, freeing its pairing slot, if the session is still in `state` at `deadline`.
    private func expire(ifStill state: BrowserBridgeSession.State, at deadline: ContinuousClock.Instant) {
        let task = Task { [weak self, clock] in
            do { try await clock.sleep(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.enqueue { connection in
                guard connection.session.state == state else { return }
                connection.runtime.releasePairing(connection.id, paired: false)
                connection.close()
            }
        }
        deadlines.withLock { $0.append(task) }
    }

    private func process(_ output: BrowserBridgeSession.Output, disabling: Bool = false) {
        for event in output.events {
            if case .established(let clientID) = event, let refusal = runtime.establish(id, clientID: clientID) {
                process(session.refuse(refusal), disabling: true)
                return
            }
        }
        // Freed before the error frame, so a peer that sees it can already try again.
        if output.close { runtime.releasePairing(id, paired: false) }
        if disabling || isActive {
            for frame in output.frames {
                guard let payload = try? BrowserBridgeFraming.decode(frame, toward: .towardExtension),
                      socket.send(payload) else { break }
            }
        }
        if output.close { close() }
        guard output.close || (!output.events.isEmpty && isActive) else { return }
        report(self, output.events, output.close)
    }
}
#endif
