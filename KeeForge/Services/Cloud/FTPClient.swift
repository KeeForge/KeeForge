import Foundation
import Network
import os

/// One TCP connection as the FTP engine sees it.
protocol FTPByteStream: Sendable {
    func send(_ data: Data) async throws
    /// The next chunk, or nil once the peer has closed its side.
    func receive() async throws -> Data?
    /// Half-closes the write side so the server sees the end of an upload.
    func finishSending() async throws
    func close()
}

struct FTPReply: Equatable, Sendable {
    let code: Int
    let lines: [String]

    var message: String {
        lines.joined(separator: "\n")
    }

    var isPositiveCompletion: Bool {
        (200..<300).contains(code)
    }
}

/// A failure the engine can describe better than the transport: a reply the
/// provider has to interpret in context, or a transport that stopped
/// answering.
enum FTPClientError: Error, Equatable {
    case unexpectedReply(FTPReply)
    /// RNTO refused: the server will not create or replace the destination.
    case renameRefused(FTPReply)
    /// The server refused to show a path it may hold, so neither its absence
    /// nor its contents can be established.
    case accessDenied(FTPReply)
    case malformedReply(String)
    case connectionClosed
    case timedOut
    case illegalArgument
}

/// Opens authenticated FTP sessions. Each operation gets its own session, so
/// there is no connection state to share or invalidate between accounts.
struct FTPClient: Sendable {
    typealias Connector = @Sendable (_ host: String, _ port: UInt16) async throws -> any FTPByteStream

    let connector: Connector
    let timeout: Duration

    init(connector: @escaping Connector = FTPNetworkStream.connect, timeout: Duration = .seconds(30)) {
        self.connector = connector
        self.timeout = timeout
    }

    func withSession<T: Sendable>(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        _ body: (FTPSession) async throws -> T
    ) async throws -> T {
        let connector = connector
        let control = try await withFTPTimeout(timeout) { try await connector(host, port) }
        let session = FTPSession(host: host, control: control, client: self)
        do {
            try await session.login(username: username, password: password)
            let result = try await body(session)
            await session.quit()
            return result
        } catch {
            control.close()
            throw error
        }
    }
}

/// A logged-in control connection. Not shared across tasks: one operation
/// drives it from start to finish.
final class FTPSession {
    private let host: String
    private let control: any FTPByteStream
    private let client: FTPClient
    private var buffer = Data()

    fileprivate init(host: String, control: any FTPByteStream, client: FTPClient) {
        self.host = host
        self.control = control
        self.client = client
    }

    // MARK: - Session lifecycle

    fileprivate func login(username: String, password: String) async throws {
        var greeting = try await readReply()
        while greeting.code == 120 {
            greeting = try await readReply()
        }
        guard greeting.code == 220 else { throw FTPClientError.unexpectedReply(greeting) }

        var reply = try await command("USER", username)
        if reply.code == 331 {
            reply = try await command("PASS", password)
        }
        guard reply.code == 230 || reply.code == 202 else {
            throw FTPClientError.unexpectedReply(reply)
        }

        // Advertises UTF-8 paths on servers that want to be asked; the answer
        // does not matter because paths are sent as UTF-8 either way.
        _ = try await command("OPTS", "UTF8 ON")

        let type = try await command("TYPE", "I")
        guard type.code == 200 else { throw FTPClientError.unexpectedReply(type) }
    }

    fileprivate func quit() async {
        _ = try? await command("QUIT")
        control.close()
    }

    // MARK: - Operations

    /// Changes into `path` (relative to the login directory unless it starts
    /// with a slash). An empty path stays in the login directory.
    func changeDirectory(_ path: String) async throws {
        guard !path.isEmpty else { return }
        let reply = try await command("CWD", path)
        guard reply.isPositiveCompletion else { throw FTPClientError.unexpectedReply(reply) }
    }

    /// Lists the current directory, preferring MLSD and falling back to LIST
    /// on servers that do not implement it (vsftpd, for one).
    func listCurrentDirectory() async throws -> [FTPListEntry] {
        try await list(nil, strict: false).entries
    }

    /// Lists `path` (the login directory when empty), for sweeping scratch
    /// files. Some LIST implementations leave hidden names out.
    func listDirectory(_ path: String) async throws -> [FTPListEntry] {
        try await list(path, strict: true).entries
    }

    /// Size and modification time of a file, or nil only once the server has
    /// shown it is not there. RFC 3659 and RFC 959 both allow 550 for "not
    /// found" and "not allowed to look", so a 550 is checked against SIZE and
    /// then a listing of the parent; if neither settles it, `accessDenied`.
    func stat(_ path: String) async throws -> FTPListEntry? {
        let mlst = try await command("MLST", path)
        if mlst.code == 250 {
            let entries = mlst.lines.dropFirst().compactMap(FTPListingParser.parseMachineEntry)
            guard let entry = entries.first else {
                throw FTPClientError.malformedReply(mlst.message)
            }
            return entry
        }
        guard mlst.code == 550 || Self.isNotImplemented(mlst) else { throw FTPClientError.unexpectedReply(mlst) }

        let size = try await command("SIZE", path)
        if size.code == 213 {
            guard let byteCount = Int64(size.message.trimmingCharacters(in: .whitespaces)) else {
                throw FTPClientError.unexpectedReply(size)
            }
            return FTPListEntry(
                name: FTPListingParser.lastComponent(of: path),
                isFolder: false,
                size: byteCount,
                modifiedStamp: try await modificationStamp(of: path)
            )
        }
        guard size.code == 550 || Self.isNotImplemented(size) else { throw FTPClientError.unexpectedReply(size) }

        return try await entryInParentListing(of: path, refusal: size.code == 550 ? size : mlst)
    }

    private func modificationStamp(of path: String) async throws -> String? {
        let mdtm = try await command("MDTM", path)
        if mdtm.code == 213 {
            let value = mdtm.message.trimmingCharacters(in: .whitespaces)
            return FTPListingParser.isTimeVal(value) ? value : nil
        }
        guard mdtm.code == 550 || Self.isNotImplemented(mdtm) else { throw FTPClientError.unexpectedReply(mdtm) }
        return nil
    }

    private func entryInParentListing(of path: String, refusal: FTPReply) async throws -> FTPListEntry? {
        let name = FTPListingParser.lastComponent(of: path)
        let listing: (entries: [FTPListEntry], isMachineListing: Bool)
        do {
            listing = try await list(FTPListingParser.parentPath(of: path), strict: true)
        } catch FTPClientError.unexpectedReply {
            throw FTPClientError.accessDenied(refusal)
        }

        // A case-only match counts: on a case-insensitive server that name is
        // the same file.
        if let entry = listing.entries.first(where: { $0.name == name })
            ?? listing.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return entry
        }
        // vsftpd's LIST leaves dotfiles out by default, so it cannot prove a
        // hidden name absent.
        guard listing.isMachineListing || !name.hasPrefix(".") else {
            throw FTPClientError.accessDenied(refusal)
        }
        return nil
    }

    func retrieve(_ path: String) async throws -> Data {
        let dataConnection = try await openDataConnection()
        defer { dataConnection.close() }

        let start = try await command("RETR", path)
        guard start.code == 150 || start.code == 125 else {
            throw FTPClientError.unexpectedReply(start)
        }

        var bytes = Data()
        while let chunk = try await timed({ try await dataConnection.receive() }) {
            bytes.append(chunk)
        }
        dataConnection.close()

        let done = try await readReply()
        guard done.code == 226 || done.code == 250 else { throw FTPClientError.unexpectedReply(done) }
        return bytes
    }

    func store(_ path: String, data: Data) async throws {
        let dataConnection = try await openDataConnection()
        defer { dataConnection.close() }

        let start = try await command("STOR", path)
        guard start.code == 150 || start.code == 125 else {
            throw FTPClientError.unexpectedReply(start)
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.uploadChunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            try await timed { try await dataConnection.send(chunk) }
            offset = end
        }
        try await timed { try await dataConnection.finishSending() }

        // Closed only after 226 (by the defer): the server confirms it has
        // every byte before the connection can go away.
        let done = try await readReply()
        guard done.code == 226 || done.code == 250 else { throw FTPClientError.unexpectedReply(done) }
    }

    /// Renames `source` to `destination`. Whether an existing destination is
    /// replaced is up to the server: Unix servers replace it atomically, IIS
    /// refuses.
    func rename(_ source: String, to destination: String) async throws {
        let from = try await command("RNFR", source)
        guard from.code == 350 else { throw FTPClientError.unexpectedReply(from) }
        let to = try await command("RNTO", destination)
        guard to.isPositiveCompletion else { throw FTPClientError.renameRefused(to) }
    }

    func delete(_ path: String) async throws {
        let reply = try await command("DELE", path)
        guard reply.isPositiveCompletion else { throw FTPClientError.unexpectedReply(reply) }
    }

    // MARK: - Data connections

    /// MLSD, or LIST where MLSD is not implemented. `strict` refuses the
    /// 450/550 some servers send for an empty directory, because the same
    /// reply also means the listing was denied.
    private func list(
        _ path: String?,
        strict: Bool
    ) async throws -> (entries: [FTPListEntry], isMachineListing: Bool) {
        let path = path?.isEmpty == true ? nil : path
        if let lines = try await readListing(verb: "MLSD", path: path, treatMissingAsEmpty: false) {
            return (lines.compactMap(FTPListingParser.parseMachineEntry), true)
        }
        let lines = try await readListing(verb: "LIST", path: path, treatMissingAsEmpty: !strict) ?? []
        return (lines.compactMap(FTPListingParser.parseListLine), false)
    }

    private func readListing(verb: String, path: String?, treatMissingAsEmpty: Bool) async throws -> [String]? {
        let dataConnection = try await openDataConnection()
        defer { dataConnection.close() }

        let start = try await command(verb, path)
        if Self.isNotImplemented(start) {
            return nil
        }
        // Some servers answer LIST in an empty directory with 450/550 rather
        // than an empty transfer.
        if treatMissingAsEmpty, start.code == 450 || start.code == 550 {
            return []
        }
        guard start.code == 150 || start.code == 125 else {
            throw FTPClientError.unexpectedReply(start)
        }

        var bytes = Data()
        while let chunk = try await timed({ try await dataConnection.receive() }) {
            bytes.append(chunk)
        }
        dataConnection.close()

        let done = try await readReply()
        guard done.code == 226 || done.code == 250 else { throw FTPClientError.unexpectedReply(done) }

        return Self.decode(bytes)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func openDataConnection() async throws -> any FTPByteStream {
        let extended = try await command("EPSV")
        let port: UInt16
        if extended.code == 229 {
            guard let extendedPort = FTPListingParser.extendedPassivePort(from: extended.message) else {
                throw FTPClientError.malformedReply(extended.message)
            }
            port = extendedPort
        } else if Self.isNotImplemented(extended) || extended.code == 501 {
            let passive = try await command("PASV")
            guard passive.code == 227 else { throw FTPClientError.unexpectedReply(passive) }
            guard let passivePort = FTPListingParser.passivePort(from: passive.message) else {
                throw FTPClientError.malformedReply(passive.message)
            }
            port = passivePort
        } else {
            throw FTPClientError.unexpectedReply(extended)
        }

        let connector = client.connector
        let host = host
        return try await timed { try await connector(host, port) }
    }

    // MARK: - Control channel

    @discardableResult
    private func command(_ verb: String, _ argument: String? = nil) async throws -> FTPReply {
        var line = verb
        if let argument {
            // A CR or LF would end the command early and let the rest of the
            // argument run as a second command. Checked per scalar: "\r\n" is
            // one Character and would slip past a Character comparison.
            guard !argument.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
                throw FTPClientError.illegalArgument
            }
            line += " " + argument
        }
        let bytes = Data((line + "\r\n").utf8)
        let control = control
        try await timed { try await control.send(bytes) }
        return try await readReply()
    }

    private func readReply() async throws -> FTPReply {
        let first = try await readLine()
        guard first.count >= 3,
              let code = Int(first.prefix(3)),
              (100..<600).contains(code) else {
            throw FTPClientError.malformedReply(first)
        }

        let codeText = String(first.prefix(3))
        guard first.dropFirst(3).first == "-" else {
            return FTPReply(code: code, lines: [Self.text(afterCodeIn: first)])
        }

        var lines = [Self.text(afterCodeIn: first)]
        while true {
            let line = try await readLine()
            if line == codeText || line.hasPrefix(codeText + " ") {
                lines.append(Self.text(afterCodeIn: line))
                return FTPReply(code: code, lines: lines)
            }
            lines.append(line)
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var lineBytes = buffer[buffer.startIndex..<newline]
                if lineBytes.last == UInt8(ascii: "\r") {
                    lineBytes = lineBytes.dropLast()
                }
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Self.decode(Data(lineBytes))
            }
            guard buffer.count < Self.maximumLineLength else {
                throw FTPClientError.malformedReply(Self.decode(buffer.prefix(80)))
            }
            let control = control
            guard let chunk = try await timed({ try await control.receive() }) else {
                throw FTPClientError.connectionClosed
            }
            buffer.append(chunk)
        }
    }

    private func timed<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withFTPTimeout(client.timeout, operation)
    }

    private static func text(afterCodeIn line: String) -> String {
        String(line.dropFirst(4))
    }

    /// Paths and listings are UTF-8 on every current server; Latin-1 keeps an
    /// older server's listing readable instead of failing the whole folder.
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func isNotImplemented(_ reply: FTPReply) -> Bool {
        reply.code == 500 || reply.code == 502 || reply.code == 504
    }

    private static let maximumLineLength = 64 * 1024
    private static let uploadChunkSize = 64 * 1024
}

/// Runs `operation`, cancelling it and throwing `timedOut` once `timeout`
/// passes. The transports cancel their connection on task cancellation, so
/// the abandoned operation does not linger.
private func withFTPTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FTPClientError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

// MARK: - Live transport

/// `FTPByteStream` over a Network.framework TCP connection. Cancelling the
/// awaiting task cancels the connection, which is what lets the sync
/// coordinator's open-probe deadline abandon an unresponsive server.
final class FTPNetworkStream: FTPByteStream {
    private let connection: NWConnection
    private let reachedEnd = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "com.keeforge.ftp.connection")

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(host: String, port: UInt16) async throws -> any FTPByteStream {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CloudProviderError.invalidConfiguration
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let resumed = OSAllocatedUnfairLock(initialState: false)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                @Sendable func finish(_ result: Result<Void, Error>) {
                    let shouldResume = resumed.withLock { alreadyResumed in
                        defer { alreadyResumed = true }
                        return !alreadyResumed
                    }
                    guard shouldResume else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(with: result)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    // `.waiting` means no route right now; Network.framework
                    // would wait indefinitely for one, and a sync must not.
                    case .waiting(let error), .failed(let error):
                        connection.cancel()
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }

        return FTPNetworkStream(connection: connection)
    }

    func send(_ data: Data) async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive() async throws -> Data? {
        guard !reachedEnd.withLock({ $0 }) else { return nil }
        let connection = connection
        let reachedEnd = reachedEnd
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if isComplete {
                        reachedEnd.withLock { $0 = true }
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func finishSending() async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() {
        connection.cancel()
    }
}
