import Foundation
@testable import KeeForge

/// An in-memory FTP server that speaks the control protocol over fake byte
/// streams, so `FTPClient` runs its real command/reply/data-connection logic
/// without sockets. Paths are relative to the login directory; a leading
/// slash means the same thing.
final class FakeFTPServer: @unchecked Sendable {
    struct File: Equatable {
        var data: Data
        var modified: String
    }

    static let controlPort: UInt16 = 21

    private let lock = NSLock()

    // MARK: Server behavior (set before use)

    var username = "alex"
    var password = "secret"
    var supportsMachineListing = true
    var supportsExtendedPassive = true
    var supportsModificationTime = true
    var renameReplacesExisting = true
    var refusesConnections = false
    /// Advertised in PASV replies; the client must ignore it and reuse the
    /// control host.
    var passiveAddress = "10,9,8,7"
    /// Verbs that never get an answer, to exercise the client timeout.
    var silentVerbs: Set<String> = []

    // MARK: State

    private var directories: Set<String> = [""]
    private var files: [String: File] = [:]
    private var replyOverrides: [String: [String]] = [:]
    private var commandHooks: [String: [@Sendable () -> Void]] = [:]
    private var log: [String] = []
    private var connectedEndpoints: [String] = []
    private var pendingData: [UInt16: FakeFTPStream] = [:]
    private var nextDataPort: UInt16 = 40_000
    private var stampCounter = 0

    // MARK: Test surface

    func addDirectory(_ path: String) {
        lock.withLock { directories.insert(Self.normalize(path)) }
    }

    func setFile(_ path: String, data: Data, modified: String? = nil) {
        lock.withLock {
            let key = Self.normalize(path)
            files[key] = File(data: data, modified: modified ?? nextStampLocked())
        }
    }

    func file(_ path: String) -> File? {
        lock.withLock { files[Self.normalize(path)] }
    }

    var filePaths: [String] {
        lock.withLock { files.keys.sorted() }
    }

    /// The commands received, in order, with PASS arguments redacted.
    var commandLog: [String] {
        lock.withLock { log }
    }

    var connectionLog: [String] {
        lock.withLock { connectedEndpoints }
    }

    /// Answers the next `verb` with `reply` instead of handling it.
    func overrideNextReply(to verb: String, with reply: String) {
        lock.withLock { replyOverrides[verb, default: []].append(reply) }
    }

    /// Runs `hook` just before the next `verb` is handled — the moment another
    /// client could have changed the server.
    func beforeNext(_ verb: String, _ hook: @escaping @Sendable () -> Void) {
        lock.withLock { commandHooks[verb, default: []].append(hook) }
    }

    func makeClient(timeout: Duration = .seconds(5)) -> FTPClient {
        FTPClient(connector: { [self] host, port in try self.connect(host: host, port: port) }, timeout: timeout)
    }

    // MARK: Connections

    private func connect(host: String, port: UInt16) throws -> any FTPByteStream {
        try lock.withLock {
            connectedEndpoints.append("\(host):\(port)")
            if refusesConnections {
                throw POSIXError(.ECONNREFUSED)
            }
            if port == Self.controlPort {
                let session = ControlSession()
                let stream = FakeFTPStream { [weak self, session] data in
                    self?.receiveControl(data, session: session)
                }
                session.stream = stream
                stream.deliver("220 Fake FTP ready\r\n")
                return stream
            }
            guard let stream = pendingData.removeValue(forKey: port) else {
                throw POSIXError(.ECONNREFUSED)
            }
            return stream
        }
    }

    private final class ControlSession: @unchecked Sendable {
        weak var stream: FakeFTPStream?
        var buffer = Data()
        var pendingUser: String?
        var loggedIn = false
        var cwd = ""
        var renameFrom: String?
        var dataStream: FakeFTPStream?
    }

    private func receiveControl(_ data: Data, session: ControlSession) {
        session.buffer.append(data)
        while let newline = session.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = session.buffer[session.buffer.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            session.buffer = Data(session.buffer[session.buffer.index(after: newline)...])

            let line = String(decoding: lineData, as: UTF8.self)
            let verb: String
            let argument: String?
            if let space = line.firstIndex(of: " ") {
                verb = line[..<space].uppercased()
                argument = String(line[line.index(after: space)...])
            } else {
                verb = line.uppercased()
                argument = nil
            }
            handle(verb: verb, argument: argument, session: session)
        }
    }

    // MARK: Command handling

    private func handle(verb: String, argument: String?, session: ControlSession) {
        let hooks: [@Sendable () -> Void] = lock.withLock {
            log.append(verb == "PASS" ? "PASS ***" : [verb, argument].compactMap { $0 }.joined(separator: " "))
            return commandHooks.removeValue(forKey: verb) ?? []
        }
        hooks.forEach { $0() }

        let (silent, override) = lock.withLock { () -> (Bool, String?) in
            if silentVerbs.contains(verb) { return (true, nil) }
            guard var queue = replyOverrides[verb], !queue.isEmpty else { return (false, nil) }
            let reply = queue.removeFirst()
            replyOverrides[verb] = queue
            return (false, reply)
        }
        if silent { return }
        if let override {
            reply(override, session)
            return
        }

        switch verb {
        case "USER":
            session.pendingUser = argument
            reply("331 Password required", session)
        case "PASS":
            let accepted = lock.withLock { session.pendingUser == username && argument == password }
            session.loggedIn = accepted
            reply(accepted ? "230 Logged in" : "530 Login incorrect", session)
        case "QUIT":
            reply("221 Bye", session)
        default:
            guard session.loggedIn else {
                reply("530 Please log in", session)
                return
            }
            handleAuthenticated(verb: verb, argument: argument, session: session)
        }
    }

    private func handleAuthenticated(verb: String, argument: String?, session: ControlSession) {
        switch verb {
        case "OPTS":
            reply("200 UTF8 set to on", session)
        case "TYPE":
            reply("200 Switching to Binary mode", session)
        case "CWD":
            let path = resolve(argument ?? "", in: session)
            if lock.withLock({ directories.contains(path) }) {
                session.cwd = path
                reply("250 Directory changed", session)
            } else {
                reply("550 Failed to change directory", session)
            }
        case "EPSV":
            guard supportsExtendedPassive else { return reply("500 Unknown command", session) }
            let port = openDataChannel(session)
            reply("229 Entering Extended Passive Mode (|||\(port)|)", session)
        case "PASV":
            let port = openDataChannel(session)
            reply("227 Entering Passive Mode (\(passiveAddress),\(port / 256),\(port % 256)).", session)
        case "MLSD":
            guard supportsMachineListing else { return reply("500 Unknown command", session) }
            let lines = ["type=cdir;modify=20260101000000; ."] + listing(of: session.cwd).map { entry in
                if entry.isFolder {
                    return "type=dir;modify=20260101000000; \(entry.name)"
                }
                return "Type=file;Size=\(entry.file?.data.count ?? 0);Modify=\(entry.file?.modified ?? ""); \(entry.name)"
            }
            sendListing(lines, session: session)
        case "LIST":
            let lines = ["total 8"] + listing(of: session.cwd).map { entry in
                if entry.isFolder {
                    return "drwxr-xr-x    2 alex     staff        4096 Jan 01 12:00 \(entry.name)"
                }
                return "-rw-r--r--    1 alex     staff   \(entry.file?.data.count ?? 0) Sep 18  2026 \(entry.name)"
            }
            sendListing(lines, session: session)
        case "MLST":
            guard supportsMachineListing else { return reply("500 Unknown command", session) }
            let path = resolve(argument ?? "", in: session)
            guard let file = lock.withLock({ files[path] }) else { return reply("550 No such file", session) }
            reply(
                "250-Listing \(argument ?? "")\r\n Type=file;Size=\(file.data.count);Modify=\(file.modified); /\(path)\r\n250 End",
                session
            )
        case "SIZE":
            let path = resolve(argument ?? "", in: session)
            guard let file = lock.withLock({ files[path] }) else { return reply("550 Could not get file size", session) }
            reply("213 \(file.data.count)", session)
        case "MDTM":
            guard supportsModificationTime else { return reply("502 Command not implemented", session) }
            let path = resolve(argument ?? "", in: session)
            guard let file = lock.withLock({ files[path] }) else { return reply("550 Could not get file modification time", session) }
            reply("213 \(file.modified)", session)
        case "RETR":
            let path = resolve(argument ?? "", in: session)
            guard let file = lock.withLock({ files[path] }) else { return reply("550 Failed to open file", session) }
            guard let dataStream = session.dataStream else { return reply("425 Use PASV first", session) }
            session.dataStream = nil
            reply("150 Opening BINARY mode data connection", session)
            dataStream.deliver(file.data)
            dataStream.deliverEnd()
            reply("226 Transfer complete", session)
        case "STOR":
            let path = resolve(argument ?? "", in: session)
            guard let dataStream = session.dataStream else { return reply("425 Use PASV first", session) }
            session.dataStream = nil
            reply("150 Ok to send data", session)
            dataStream.onFinishUpload = { [weak self, session] uploaded in
                guard let self else { return }
                self.lock.withLock {
                    self.files[path] = File(data: uploaded, modified: self.nextStampLocked())
                }
                self.reply("226 Transfer complete", session)
            }
        case "RNFR":
            let path = resolve(argument ?? "", in: session)
            guard lock.withLock({ files[path] != nil }) else { return reply("550 RNFR command failed", session) }
            session.renameFrom = path
            reply("350 Ready for RNTO", session)
        case "RNTO":
            let destination = resolve(argument ?? "", in: session)
            guard let source = session.renameFrom else { return reply("503 RNFR required first", session) }
            session.renameFrom = nil
            let succeeded = lock.withLock { () -> Bool in
                if files[destination] != nil, !renameReplacesExisting { return false }
                files[destination] = files.removeValue(forKey: source)
                return true
            }
            reply(succeeded ? "250 Rename successful" : "550 Cannot rename: file exists", session)
        case "DELE":
            let path = resolve(argument ?? "", in: session)
            let removed = lock.withLock { files.removeValue(forKey: path) != nil }
            reply(removed ? "250 Delete operation successful" : "550 Delete operation failed", session)
        default:
            reply("502 Command not implemented", session)
        }
    }

    private func openDataChannel(_ session: ControlSession) -> UInt16 {
        lock.withLock {
            let port = nextDataPort
            nextDataPort += 1
            let stream = FakeFTPStream { _ in }
            pendingData[port] = stream
            session.dataStream = stream
            return port
        }
    }

    private func sendListing(_ lines: [String], session: ControlSession) {
        guard let dataStream = session.dataStream else { return reply("425 Use PASV first", session) }
        session.dataStream = nil
        reply("150 Here comes the directory listing", session)
        dataStream.deliver(lines.map { $0 + "\r\n" }.joined())
        dataStream.deliverEnd()
        reply("226 Directory send OK", session)
    }

    private struct ListingEntry {
        let name: String
        let isFolder: Bool
        let file: File?
    }

    private func listing(of directory: String) -> [ListingEntry] {
        lock.withLock {
            let prefix = directory.isEmpty ? "" : directory + "/"
            func isChild(_ path: String) -> Bool {
                path.hasPrefix(prefix) && !path.isEmpty && !path.dropFirst(prefix.count).contains("/")
            }
            let folders = directories.filter { $0 != directory && isChild($0) }
                .map { ListingEntry(name: String($0.dropFirst(prefix.count)), isFolder: true, file: nil) }
            let fileEntries = files.filter { isChild($0.key) }
                .map { ListingEntry(name: String($0.key.dropFirst(prefix.count)), isFolder: false, file: $0.value) }
            return (folders + fileEntries).sorted { $0.name < $1.name }
        }
    }

    private func reply(_ text: String, _ session: ControlSession) {
        session.stream?.deliver(text + "\r\n")
    }

    private func resolve(_ argument: String, in session: ControlSession) -> String {
        if argument.hasPrefix("/") {
            return Self.normalize(argument)
        }
        return Self.normalize(session.cwd.isEmpty ? argument : session.cwd + "/" + argument)
    }

    private static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                _ = components.popLast()
                continue
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

    private func nextStampLocked() -> String {
        stampCounter += 1
        return String(format: "20260918%06d", 120_000 + stampCounter)
    }
}

/// One side of a fake connection: `deliver` feeds what the client will
/// `receive`, and client sends are handed to the server synchronously.
final class FakeFTPStream: FTPByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var ended = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Data?, Error>?
    private var uploaded = Data()
    private let onSend: @Sendable (Data) -> Void
    var onFinishUpload: ((Data) -> Void)?

    init(onSend: @escaping @Sendable (Data) -> Void) {
        self.onSend = onSend
    }

    func deliver(_ text: String) {
        deliver(Data(text.utf8))
    }

    func deliver(_ data: Data) {
        let waiting: CheckedContinuation<Data?, Error>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter
            }
            chunks.append(data)
            return nil
        }
        waiting?.resume(returning: data)
    }

    func deliverEnd() {
        let waiting: CheckedContinuation<Data?, Error>? = lock.withLock {
            ended = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    func send(_ data: Data) async throws {
        let isData = lock.withLock { () -> Bool in
            guard onFinishUpload != nil else { return false }
            uploaded.append(data)
            return true
        }
        if !isData {
            onSend(data)
        }
    }

    func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: chunk)
                } else if ended {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<Data?, Error>? = lock.withLock {
                cancelled = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    func finishSending() async throws {
        let (handler, bytes): (((Data) -> Void)?, Data) = lock.withLock {
            defer { onFinishUpload = nil }
            return (onFinishUpload, uploaded)
        }
        handler?(bytes)
    }

    func close() {}
}
