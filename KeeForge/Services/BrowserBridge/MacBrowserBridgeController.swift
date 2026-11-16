#if os(macOS)
import CryptoKit
import Foundation
import Observation
import os

/// Owns the browser bridge socket while the bridge is started and switched on,
/// and the paired browsers and pending pairing that Settings shows.
@MainActor @Observable
final class MacBrowserBridgeController {
    typealias SessionsProvider = BrowserBridgeRequestHandler.SessionsProvider
    typealias Sleep = @Sendable (Duration) async throws -> Void

    enum Unavailability: Equatable {
        case noGroupContainer
        /// Another listener, such as a second copy of KeeForge, serves the path.
        case socketInUse
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
    @ObservationIgnored private let sleep: Sleep
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
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        reveal: @escaping @MainActor (UUID, UUID) -> Void = { _, _ in },
        unlock: @escaping @MainActor (UUID?) -> Void = { _ in },
        authenticateDeviceOwner: @escaping BrowserBridgeRequestHandler.DeviceOwnerAuthenticator = BrowserBridgeRequestHandler.deviceOwnerGate
    ) {
        self.defaults = defaults
        self.store = store
        self.socketPath = socketPath
        self.appVersion = appVersion
        self.sessionsProvider = sessionsProvider
        self.sleep = sleep
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

    func answerPairing(_ allow: Bool) {
        guard let pending = pendingPairing, let pairing else { return }
        let connection = pairing.connection
        let key = pairing.key
        clearPairing()
        guard allow else { connection.answer(false); return }
        let token = generation
        let runtime = runtime
        // The connection keeps the runtime's pairing slot until it is answered or closes.
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
        let runtime = BrowserBridgeRuntime(browsers: browsers)
        let appVersion = appVersion
        let framing = LocalSocketServer.Framing(byteOrder: .littleEndian,
                                                maximumInboundLength: BrowserBridgeFraming.maximumAppPayload,
                                                maximumOutboundLength: BrowserBridgeFraming.maximumExtensionPayload)
        let server = LocalSocketServer(path: path, framing: framing, refusesExcessConnections: true) { [weak self] socket in
            BrowserBridgeConnection(socket: socket, runtime: runtime, key: key, appVersion: appVersion) { [weak self] connection, events, closed in
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
                // Admission is decided off the main actor; this only guards an alert not yet cleared.
                guard pendingPairing == nil else { connection.answer(false); continue }
                let id = UUID()
                pairingFailed = false
                pendingPairing = PendingPairing(id: id, browserName: name, code: code)
                let timeout = Task { [weak self, sleep] in
                    do { try await sleep(.seconds(120)) } catch { return }
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
            authenticateDeviceOwner: authenticate
        )
        handlers[connection.id] = handler
        return handler
    }
}

/// State one listening server shares with its connections' queues: the client-key
/// snapshot the session's synchronous lookup reads, and the single pairing slot.
private final class BrowserBridgeRuntime: Sendable {
    private struct State {
        var active = true
        var keys: [String: Data]
        var pairingConnection: UUID?
        var connections: [UUID: BrowserBridgeConnection] = [:]
        var clients: [UUID: String] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>

    init(browsers: [PairedBrowser]) {
        let keys = Dictionary(browsers.map { ($0.clientID, $0.publicKey) }, uniquingKeysWith: { _, new in new })
        state = OSAllocatedUnfairLock(initialState: State(keys: keys))
    }

    var isActive: Bool { state.withLock { $0.active } }
    var isPairingAvailable: Bool { state.withLock { $0.active && $0.pairingConnection == nil } }
    func lookup(_ clientID: String) -> Data? { state.withLock { $0.keys[clientID] } }

    func register(_ connection: BrowserBridgeConnection) -> Bool {
        state.withLock { state in
            guard state.active else { return false }
            state.connections[connection.id] = connection
            return true
        }
    }

    /// Two connections can both pass `isPairingAvailable` before either reveals; only one is admitted.
    func admitPairing(_ id: UUID) -> Bool {
        state.withLock { state in
            guard state.active, state.pairingConnection == nil else { return false }
            state.pairingConnection = id
            return true
        }
    }

    func releasePairing(_ id: UUID) {
        state.withLock { if $0.pairingConnection == id { $0.pairingConnection = nil } }
    }

    /// Checked under the lock `remove` takes, so a removed client never ends up established.
    func establish(_ id: UUID, clientID: String) -> Bool {
        state.withLock { state in
            guard state.active, state.keys[clientID] != nil else { return false }
            state.clients[id] = clientID
            return true
        }
    }

    func closed(_ id: UUID) {
        state.withLock { state in
            state.connections[id] = nil
            state.clients[id] = nil
            if state.pairingConnection == id { state.pairingConnection = nil }
        }
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
private final class BrowserBridgeConnection: LocalSocketConnectionHandler, @unchecked Sendable {
    typealias Report = @Sendable (BrowserBridgeConnection, [BrowserBridgeSession.Event], Bool) -> Void

    let id = UUID()
    private let runtime: BrowserBridgeRuntime
    private let socket: LocalSocketServer.Connection
    private let queue = DispatchQueue(label: "com.keevault.app.browser-bridge.connection")
    /// Touched only on `queue`.
    private let session: BrowserBridgeSession
    private let report: Report
    private let open = OSAllocatedUnfairLock(initialState: true)

    var isActive: Bool { runtime.isActive && open.withLock { $0 } }

    init(socket: LocalSocketServer.Connection, runtime: BrowserBridgeRuntime,
         key: Curve25519.KeyAgreement.PrivateKey, appVersion: String, report: @escaping Report) {
        self.socket = socket
        self.runtime = runtime
        self.report = report
        session = BrowserBridgeSession(appKey: key, appVersion: appVersion,
                                       lookupClient: { runtime.lookup($0) },
                                       pairingAvailable: { runtime.isPairingAvailable })
        if !runtime.register(self) { close() }
    }

    func receive(_ payload: Data) {
        queue.async {
            guard self.isActive, let frame = try? BrowserBridgeFraming.encode(payload, toward: .towardApp) else { return }
            self.process(self.session.receive(frame))
        }
    }

    func answer(_ allow: Bool) {
        queue.async {
            guard self.isActive, self.session.state == .awaitingAnswer else { return }
            self.runtime.releasePairing(self.id)
            self.process(self.session.pairingAnswered(allow))
        }
    }

    func timedOut() {
        queue.async {
            guard self.isActive else { return }
            self.process(self.session.pairingTimedOut())
        }
    }

    func reply(_ result: BrowserBridgeReply.Result, to request: BrowserBridgeRequest) {
        queue.async {
            guard self.isActive else { return }
            self.process(self.session.reply(result, to: request))
        }
    }

    /// Runs after the runtime is deactivated: the only output still written then.
    func disable() {
        queue.async { self.process(self.session.disable(), disabling: true) }
    }

    func close() {
        open.withLock { $0 = false }
        socket.close()
    }

    func connectionClosed() {
        open.withLock { $0 = false }
        runtime.closed(id)
        queue.async { self.process(self.session.close()) }
    }

    private func process(_ output: BrowserBridgeSession.Output, disabling: Bool = false) {
        for event in output.events {
            switch event {
            case .pairingRequested where !runtime.admitPairing(id):
                process(session.pairingAnswered(false))
                return
            case .established(let clientID) where !runtime.establish(id, clientID: clientID):
                process(session.disable(), disabling: true)
                return
            default:
                break
            }
        }
        if disabling || isActive {
            for frame in output.frames {
                guard let payload = try? BrowserBridgeFraming.decode(frame, toward: .towardExtension),
                      socket.send(payload) else { break }
            }
        }
        if output.close {
            close()
            runtime.releasePairing(id)
        }
        guard output.close || (!output.events.isEmpty && isActive) else { return }
        report(self, output.events, output.close)
    }
}
#endif
