#if os(macOS)
import Darwin
import Foundation
import os

enum LocalSocketError: Error, Equatable {
    case pathTooLong
    /// Something other than a socket already exists at the path.
    case pathOccupied
    /// Another server listens on the path.
    case socketInUse
    case system(errno: Int32)
}

/// Callbacks run serially on the connection's reader thread, never under a transport lock.
protocol LocalSocketConnectionHandler: Sendable {
    func receive(_ frame: Data)
    func connectionClosed()
}

/// A same-user Unix socket transport with bounded, length-prefixed frames.
final class LocalSocketServer: Sendable {
    static let defaultMaximumConnections = 64

    struct Framing: Sendable {
        enum ByteOrder: Sendable { case bigEndian, littleEndian }
        let byteOrder: ByteOrder
        let maximumInboundLength: Int
        let maximumOutboundLength: Int

        fileprivate func prefix(for length: Int) -> Data {
            let shifts = byteOrder == .bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]
            return Data(shifts.map { UInt8(truncatingIfNeeded: length >> $0) })
        }
    }

    /// Retain this handle for delayed replies. Writes are serialized across threads;
    /// close interrupts blocked I/O, and sends after closure return false.
    final class Connection: Sendable {
        private let descriptor: Int32
        private let framing: Framing
        private let lifecycle = OSAllocatedUnfairLock(initialState: false)
        private let writer = NSLock()

        fileprivate init(descriptor: Int32, framing: Framing) {
            self.descriptor = descriptor
            self.framing = framing
        }

        @discardableResult
        func send(_ frame: Data) -> Bool {
            guard !frame.isEmpty, frame.count <= framing.maximumOutboundLength else {
                close()
                return false
            }
            writer.lock()
            defer { writer.unlock() }
            guard !lifecycle.withLock({ $0 }) else { return false }
            let success = LocalSocketServer.writeBytes(framing.prefix(for: frame.count) + frame, to: descriptor)
            if !success { close() }
            return success
        }

        fileprivate var isClosed: Bool { lifecycle.withLock { $0 } }

        func close() {
            lifecycle.withLock { closed in
                guard !closed else { return }
                closed = true
                shutdown(descriptor, SHUT_RDWR)
            }
        }

        fileprivate func finish() {
            close()
            // Shutdown wakes a blocked writer before waiting to release the descriptor.
            writer.lock()
            Darwin.close(descriptor)
            writer.unlock()
        }
    }

    let path: String
    private let framing: Framing
    private let makeHandler: @Sendable (Connection) -> any LocalSocketConnectionHandler
    private let maximumConnections: Int
    private let acceptQueue = DispatchQueue(label: "com.keevault.app.local-socket")
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var listener: (any DispatchSourceRead)?
        /// The socket file this server bound, so `stop()` never removes one
        /// that another agent has since put at the path.
        var boundFile: FileIdentity?
        /// Each open connection and when it last sent a complete request, or
        /// was accepted if it has sent none.
        var connections: [Int32: (connection: Connection, lastRequest: ContinuousClock.Instant)] = [:]
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    init(
        path: String,
        framing: Framing,
        maximumConnections: Int = LocalSocketServer.defaultMaximumConnections,
        makeHandler: @escaping @Sendable (Connection) -> any LocalSocketConnectionHandler
    ) {
        self.path = path
        precondition(maximumConnections > 0)
        precondition(framing.maximumInboundLength > 0 && framing.maximumOutboundLength > 0)
        precondition(framing.maximumInboundLength <= UInt32.max && framing.maximumOutboundLength <= UInt32.max)
        self.framing = framing
        self.makeHandler = makeHandler
        self.maximumConnections = maximumConnections
    }

    deinit {
        stop()
    }

    func start() throws {
        guard state.withLockUnchecked({ $0.listener == nil }) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalSocketError.system(errno: errno) }
        let boundFile: FileIdentity
        do {
            boundFile = try bindSocket(descriptor)
            guard listen(descriptor, SOMAXCONN) == 0,
                  fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
            else { throw LocalSocketError.system(errno: errno) }
        } catch {
            close(descriptor)
            throw error
        }

        let listener = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        listener.setEventHandler { [weak self] in
            self?.acceptConnections(from: descriptor)
        }
        listener.setCancelHandler {
            close(descriptor)
        }
        state.withLockUnchecked {
            $0.listener = listener
            $0.boundFile = boundFile
        }
        listener.resume()
    }

    /// Stops listening, removes the socket file if it is still the one this
    /// server bound, and ends every open connection; a request already being
    /// answered gets no reply.
    func stop() {
        let (listener, boundFile) = state.withLockUnchecked { state -> ((any DispatchSourceRead)?, FileIdentity?) in
            // Shut down under the lock: `serve` deregisters a descriptor under
            // the same lock before closing it, so none of these can have been
            // closed and reused for another file.
            for value in state.connections.values {
                value.connection.close()
            }
            defer {
                state.listener = nil
                state.boundFile = nil
            }
            return (state.listener, state.boundFile)
        }
        guard let listener else { return }
        listener.cancel()
        if let boundFile, Self.fileIdentity(at: path) == boundFile {
            unlink(path)
        }
    }

    private static func fileIdentity(at path: String) -> FileIdentity? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// Binds `descriptor` at `path` and returns the socket file it created.
    private func bindSocket(_ descriptor: Int32) throws -> FileIdentity {
        var address = try Self.address(path)
        try removeStaleSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw LocalSocketError.system(errno: errno) }
        // Owner-only whatever the umask; the container directory already is.
        guard chmod(path, S_IRUSR | S_IWUSR) == 0, let boundFile = Self.fileIdentity(at: path) else {
            let error = errno
            unlink(path)
            throw LocalSocketError.system(errno: error)
        }
        return boundFile
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalSocketError.pathTooLong
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return address
    }

    /// A socket left by a previous run that did not stop cleanly: nothing
    /// accepts a connection on it.
    private func removeStaleSocket() throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw LocalSocketError.pathOccupied }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw LocalSocketError.system(errno: errno) }
        defer { close(probe) }
        var address = try Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 {
            throw LocalSocketError.socketInUse
        }
        switch errno {
        case ECONNREFUSED:
            unlink(path)
        case ENOENT:
            break
        default:
            throw LocalSocketError.system(errno: errno)
        }
    }

    private func acceptConnections(from listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                return
            }
            guard Self.isCurrentUser(connection) else {
                close(connection)
                continue
            }
            var noSIGPIPE: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
            // Accepted sockets inherit the listener's non-blocking mode.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            let handle = Connection(descriptor: connection, framing: framing)
            let isAccepted = state.withLockUnchecked { state -> Bool in
                guard state.listener != nil else { return false }
                if state.connections.count >= maximumConnections {
                    guard let stalled = state.connections.min(by: { $0.value.lastRequest < $1.value.lastRequest })?.key else { return false }
                    // Its thread wakes from the read or write it is blocked
                    // in and closes the descriptor.
                    state.connections[stalled]?.connection.close()
                    state.connections[stalled] = nil
                }
                state.connections[connection] = (handle, .now)
                return true
            }
            guard isAccepted else {
                close(connection)
                continue
            }
            Thread.detachNewThread {
                self.serve(connection, handle: handle)
            }
        }
    }

    private func serve(_ descriptor: Int32, handle: Connection) {
        let handler = makeHandler(handle)
        defer {
            state.withLockUnchecked { $0.connections[descriptor] = nil }
            handle.finish()
            handler.connectionClosed()
        }
        while !handle.isClosed, let request = readMessage(from: descriptor) {
            let active = state.withLockUnchecked { state in
                guard state.connections[descriptor] != nil else { return false }
                state.connections[descriptor]?.lastRequest = .now
                return true
            }
            guard active, !handle.isClosed else { return }
            handler.receive(request)
        }
    }

    private static func isCurrentUser(_ connection: Int32) -> Bool {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        return getpeereid(connection, &userID, &groupID) == 0 && userID == geteuid()
    }

    /// One length-prefixed message body, or `nil` at end of stream, on error,
    /// or for a length the protocol does not allow.
    private func readMessage(from connection: Int32) -> Data? {
        guard let prefix = Self.readBytes(4, from: connection) else { return nil }
        let bytes = framing.byteOrder == .bigEndian ? Array(prefix) : Array(prefix.reversed())
        let length = bytes.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= framing.maximumInboundLength else { return nil }
        return Self.readBytes(length, from: connection)
    }

    private static func readBytes(_ count: Int, from connection: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = buffer.withUnsafeMutableBytes { bytes in
                bytes.baseAddress.map { Darwin.read(connection, $0 + received, count - received) } ?? -1
            }
            if result > 0 {
                received += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(buffer)
    }

    private static func writeBytes(_ data: Data, to connection: Int32) -> Bool {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress.map { Darwin.write(connection, $0 + sent, bytes.count - sent) } ?? -1
            }
            if result > 0 {
                sent += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
#endif
