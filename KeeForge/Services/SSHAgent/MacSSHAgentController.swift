#if os(macOS)
import AppKit
import Foundation
import Observation

/// An entry of an unlocked database that holds a private key, as Settings
/// lists it.
struct MacSSHAgentCandidate: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case supported(algorithm: String, fingerprint: String)
        case passphraseProtected
        case unsupported
    }

    let id: UUID
    let title: String
    let status: Status

    var isSupported: Bool {
        if case .supported = status { return true }
        return false
    }

    /// `nil` when the entry has no attachment that looks like a private key.
    init?(source: SSHAgentKeySource) {
        guard let file = source.privateKeyFile else { return nil }
        id = source.entryID
        title = source.entryTitle
        do {
            let key = try SSHAgentKey(privateKeyFile: file)
            status = .supported(algorithm: key.algorithm.displayName, fingerprint: key.fingerprint)
        } catch SSHAgentKeyError.passphraseProtected {
            status = .passphraseProtected
        } catch {
            status = .unsupported
        }
    }
}

/// Owns the opt-in SSH agent: the socket while it is turned on, the entries
/// each database serves through it, and the key list Settings shows.
///
/// Every request reads the chosen entries of every open session at that
/// moment. A session offers nothing while it is locked, closed, or has a lock
/// pending (`DatabaseViewModel.isLockPending`), whatever the others do, and a
/// lock that lands mid-signature withholds the signature
/// (`SSHAgentRequestHandler`). Parsed keys are kept per session, only for the
/// lease they were read under (`SSHAgentKeyCache`), and dropped the moment it
/// ends. Window focus plays no part.
@MainActor
@Observable
final class MacSSHAgentController {
    typealias SessionsProvider = @MainActor () -> [DatabaseViewModel]

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            SettingsService.setMacSSHAgentEnabled(isEnabled, in: defaults)
            apply()
        }
    }

    enum Unavailability: Equatable {
        /// Another agent, such as a second copy of KeeForge, serves the path.
        case socketInUse
        case failed
    }

    /// Why the socket could not be created while the agent is turned on.
    private(set) var unavailability: Unavailability?

    /// The entries served per database, keyed by `DatabaseReference.id`.
    private(set) var selectedEntryIDs: [UUID: Set<UUID>]

    /// The database Settings ▸ SSH Agent lists keys for, when the user picked
    /// one; see `settingsSession`.
    var settingsDatabaseID: UUID?

    /// True while another app is frontmost. The Settings window receives the
    /// privacy cover, and the SSH tab also removes its key rows from the view.
    private(set) var concealsKeyList = false

    let socketPath: String

    /// The open sessions in a stable order; the first holding a key lists it.
    @ObservationIgnored var sessionsProvider: SessionsProvider
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    @ObservationIgnored private let keyCache: SSHAgentKeyCache
    /// Per session, the lease whose end `keyCache` is being watched for.
    @ObservationIgnored private var watchedLeases: [ObjectIdentifier: SSHAgentLease] = [:]
    @ObservationIgnored private var server: SSHAgentSocketServer?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Inside the App Sandbox the home directory is the app's container, which
    /// only this user can enter, and its path has no spaces to quote.
    static var defaultSocketPath: String {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("ssh-agent.sock")
            .path
    }

    init(
        socketPath: String = MacSSHAgentController.defaultSocketPath,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        keyCache: SSHAgentKeyCache = SSHAgentKeyCache(),
        sessionsProvider: @escaping SessionsProvider = { [] }
    ) {
        self.socketPath = socketPath
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.keyCache = keyCache
        self.sessionsProvider = sessionsProvider
        isEnabled = SettingsService.macSSHAgentEnabled(in: defaults)
        selectedEntryIDs = SettingsService.macSSHAgentSelectedEntryIDs(in: defaults)
    }

    /// The `~/.ssh/config` lines that point every host at this agent.
    var configurationSnippet: String {
        "Host *\n  IdentityAgent \"\(socketPath)\"\n"
    }

    func start() {
        guard isStarted == false else { return }
        isStarted = true
        concealsKeyList = NSApplication.shared.isActive == false
        observe(NSApplication.willTerminateNotification) { $0.stopServer() }
        observe(NSApplication.didResignActiveNotification) { $0.concealsKeyList = true }
        observe(NSApplication.didBecomeActiveNotification) { $0.concealsKeyList = false }
        apply()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
        stopServer()
    }

    func isSelected(entryID: UUID, inDatabase databaseID: UUID) -> Bool {
        selectedEntryIDs[databaseID]?.contains(entryID) == true
    }

    func setSelected(_ isSelected: Bool, entryID: UUID, inDatabase databaseID: UUID) {
        var entryIDs = selectedEntryIDs[databaseID] ?? []
        if isSelected {
            entryIDs.insert(entryID)
        } else {
            entryIDs.remove(entryID)
        }
        selectedEntryIDs[databaseID] = entryIDs.isEmpty ? nil : entryIDs
        SettingsService.setMacSSHAgentSelectedEntryIDs(selectedEntryIDs, in: defaults)
        for session in sessionsProvider() where session.databaseReference.id == databaseID {
            keyCache.removeAll(forSession: ObjectIdentifier(session))
        }
    }

    /// The chosen entries of every open session, read at the moment of a
    /// request, in session order. Empty unless the agent is on; a session
    /// contributes only while it is unlocked with no lock pending.
    func keySources() -> [SSHAgentKeySource] {
        guard isEnabled else { return [] }
        let sessions = sessionsProvider()
        forgetLeases(ofSessionsOtherThan: sessions)
        return sessions.flatMap(keySources(in:))
    }

    private func keySources(in session: DatabaseViewModel) -> [SSHAgentKeySource] {
        guard session.state == .unlocked,
              session.isLockPending == false,
              let entryIDs = selectedEntryIDs[session.databaseReference.id]
        else { return [] }
        let lease = SSHAgentLease(session: ObjectIdentifier(session), lockCycleID: session.lockCycleID)
        emptyKeyCacheWhenLeaseEnds(lease, of: session)
        return session.allEntries.compactMap { entry in
            guard entryIDs.contains(entry.id) else { return nil }
            return Self.keySource(for: entry, in: session, lease: lease)
        }
    }

    /// A session that is no longer open takes its keys and its watch with it;
    /// a later session at the same address must be watched afresh.
    private func forgetLeases(ofSessionsOtherThan sessions: [DatabaseViewModel]) {
        let open = Set(sessions.map(ObjectIdentifier.init))
        for id in watchedLeases.keys where open.contains(id) == false {
            watchedLeases[id] = nil
            keyCache.removeAll(forSession: id)
        }
    }

    /// A lock has to take the session's parsed keys with it at once, not at
    /// the next request, which may never come. The change handler runs inside
    /// the session's own mutation, on the main actor, before the new value is
    /// set. Other sessions' keys stay.
    private func emptyKeyCacheWhenLeaseEnds(_ lease: SSHAgentLease, of session: DatabaseViewModel) {
        let id = lease.session
        guard watchedLeases[id] != lease else { return }
        // The handler captures the cache generation before reading sources.
        // Invalidating an empty initial lease would discard its first parse.
        if watchedLeases[id] != nil {
            keyCache.removeAll(forSession: id)
        }
        watchedLeases[id] = lease
        withObservationTracking {
            _ = session.state
            _ = session.lockCycleID
            _ = session.isLockPending
            _ = session.contentRevision
        } onChange: { [weak self, keyCache] in
            keyCache.removeAll(forSession: id)
            MainActor.assumeIsolated {
                if self?.watchedLeases[id] == lease {
                    self?.watchedLeases[id] = nil
                }
            }
        }
    }

    /// The unlocked sessions Settings can list keys for, in session order.
    var settingsSessions: [DatabaseViewModel] {
        sessionsProvider().filter { $0.state == .unlocked }
    }

    /// The session Settings lists keys for: the one the user picked while it
    /// is open and unlocked, otherwise the first unlocked session.
    var settingsSession: DatabaseViewModel? {
        let sessions = settingsSessions
        return sessions.first { $0.databaseReference.id == settingsDatabaseID } ?? sessions.first
    }

    /// Every live entry of `session` whose attachments include a private key,
    /// supported or not, sorted by title. Keys are parsed off the main actor.
    func candidates(in session: DatabaseViewModel) async -> [MacSSHAgentCandidate] {
        guard session.state == .unlocked else { return [] }
        let lease = SSHAgentLease(session: ObjectIdentifier(session), lockCycleID: session.lockCycleID)
        let sources = session.allEntries.compactMap { Self.keySource(for: $0, in: session, lease: lease) }
        return await Task.detached(priority: .userInitiated) {
            sources.compactMap(MacSSHAgentCandidate.init(source:))
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    private func apply() {
        guard isStarted else { return }
        guard isEnabled else {
            stopServer()
            return
        }
        guard server == nil else { return }
        let handler = SSHAgentRequestHandler(keySources: { [weak self] in
            guard let self else { return [] }
            return Self.onMainActor { self.keySources() }
        }, keyCache: keyCache)
        let server = SSHAgentSocketServer(path: socketPath, handler: handler)
        do {
            try server.start()
            self.server = server
            unavailability = nil
        } catch SSHAgentSocketError.socketInUse {
            unavailability = .socketInUse
        } catch {
            unavailability = .failed
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        unavailability = nil
        keyCache.removeAll()
    }

    /// `queue: nil` runs the handler inside the post, on the main thread
    /// AppKit posts these from, so `concealsKeyList` is set before the app
    /// has finished resigning.
    private func observe(_ name: Notification.Name, handler: @escaping @MainActor (MacSSHAgentController) -> Void) {
        observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        })
    }

    private static func keySource(
        for entry: KPEntry,
        in session: DatabaseViewModel,
        lease: SSHAgentLease
    ) -> SSHAgentKeySource? {
        let attachments = entry.attachments.compactMap { attachment in
            session.attachmentBytes(for: attachment).map { SSHAgentAttachment(name: attachment.name, data: $0) }
        }
        guard attachments.isEmpty == false else { return nil }
        return SSHAgentKeySource(entryID: entry.id, entryTitle: entry.title, attachments: attachments, lease: lease)
    }

    /// Runs `body` on the main actor from a socket thread, or inline when a
    /// caller is already there.
    private nonisolated static func onMainActor<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}
#endif
