#if os(macOS)
import Darwin
import Foundation
import os

enum SSHAgentSocketError: Error, Equatable {
    case pathTooLong
    /// Something other than a socket already exists at the path.
    case pathOccupied
    case system(errno: Int32)
}

/// Serves `SSHAgentRequestHandler` on a Unix-domain socket that only the
/// current user can connect to. Each connection is read on its own thread:
/// requests are tiny, but a client may hold its connection open for as long
/// as its SSH session runs.
final class SSHAgentSocketServer: Sendable {
    let path: String
    private let handler: SSHAgentRequestHandler
    private let acceptQueue = DispatchQueue(label: "com.keevault.app.ssh-agent")
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var listener: (any DispatchSourceRead)?
        var connections: Set<Int32> = []
    }

    init(path: String, handler: SSHAgentRequestHandler) {
        self.path = path
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        guard state.withLockUnchecked({ $0.listener == nil }) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SSHAgentSocketError.system(errno: errno) }
        do {
            try bindSocket(descriptor)
            guard listen(descriptor, SOMAXCONN) == 0,
                  fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
            else { throw SSHAgentSocketError.system(errno: errno) }
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
        state.withLockUnchecked { $0.listener = listener }
        listener.resume()
    }

    /// Stops listening, removes the socket file, and ends every open
    /// connection; a request already being answered gets no reply.
    func stop() {
        let listener = state.withLockUnchecked { state -> (any DispatchSourceRead)? in
            // Shut down under the lock: `serve` deregisters a descriptor under
            // the same lock before closing it, so none of these can have been
            // closed and reused for another file.
            for connection in state.connections {
                shutdown(connection, SHUT_RDWR)
            }
            defer { state.listener = nil }
            return state.listener
        }
        guard let listener else { return }
        listener.cancel()
        unlink(path)
    }

    private func bindSocket(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SSHAgentSocketError.pathTooLong
        }
        try removeStaleSocket()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw SSHAgentSocketError.system(errno: errno) }
        // Owner-only whatever the umask; the container directory already is.
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let error = errno
            unlink(path)
            throw SSHAgentSocketError.system(errno: error)
        }
    }

    /// A socket left by a previous run that did not stop cleanly.
    private func removeStaleSocket() throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw SSHAgentSocketError.pathOccupied }
        unlink(path)
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
            let isListening = state.withLockUnchecked { state -> Bool in
                guard state.listener != nil else { return false }
                state.connections.insert(connection)
                return true
            }
            guard isListening else {
                close(connection)
                continue
            }
            Thread.detachNewThread {
                self.serve(connection)
            }
        }
    }

    private func serve(_ connection: Int32) {
        defer {
            state.withLockUnchecked { _ = $0.connections.remove(connection) }
            close(connection)
        }
        while let request = Self.readMessage(from: connection) {
            guard Self.writeMessage(handler.response(to: request), to: connection) else { return }
        }
    }

    private static func isCurrentUser(_ connection: Int32) -> Bool {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        return getpeereid(connection, &userID, &groupID) == 0 && userID == geteuid()
    }

    /// One length-prefixed message body, or `nil` at end of stream, on error,
    /// or for a length the protocol does not allow.
    private static func readMessage(from connection: Int32) -> Data? {
        guard let prefix = readBytes(4, from: connection) else { return nil }
        let length = prefix.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= SSHAgentRequestHandler.maximumMessageLength else { return nil }
        return readBytes(length, from: connection)
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

    private static func writeMessage(_ body: Data, to connection: Int32) -> Bool {
        var framed = SSHWireWriter()
        framed.writeString(body)
        let bytes = [UInt8](framed.data)
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
