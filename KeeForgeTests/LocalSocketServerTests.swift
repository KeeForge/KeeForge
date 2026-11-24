#if os(macOS)
import Darwin
import Foundation
import os
import XCTest
@testable import KeeForge

final class LocalSocketServerTests: XCTestCase {
    private struct Handler: LocalSocketConnectionHandler {
        let connection: LocalSocketServer.Connection
        var onFrame: @Sendable (Data, LocalSocketServer.Connection) -> Void = { frame, connection in
            connection.send(frame)
        }
        var onClose: @Sendable () -> Void = {}
        func receive(_ frame: Data) { onFrame(frame, connection) }
        func connectionClosed() { onClose() }
    }

    private func withPath(_ body: (String) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("s").path)
    }

    private func server(
        _ path: String,
        cap: Int = 64,
        sendTimeout: Duration? = nil,
        makeHandler: @escaping @Sendable (LocalSocketServer.Connection) -> any LocalSocketConnectionHandler = { Handler(connection: $0) }
    ) -> LocalSocketServer {
        LocalSocketServer(path: path, framing: .init(
            byteOrder: .littleEndian, maximumInboundLength: 65_536, maximumOutboundLength: 1_048_576
        ), maximumConnections: cap, sendTimeout: sendTimeout, makeHandler: makeHandler)
    }

    /// A handler that, on the first frame, sends large frames from another thread until a send fails.
    private func flooding(sendFailed: XCTestExpectation, closed: XCTestExpectation,
                          started: @escaping @Sendable (LocalSocketServer.Connection) -> Void = { _ in })
        -> @Sendable (LocalSocketServer.Connection) -> any LocalSocketConnectionHandler {
        { connection in
            Handler(connection: connection, onFrame: { _, connection in
                started(connection)
                DispatchQueue.global().async {
                    while connection.send(Data(repeating: 1, count: 65_536)) {}
                    sendFailed.fulfill()
                }
            }, onClose: { closed.fulfill() })
        }
    }

    func testSendTimeoutClosesConnectionToPeerThatNeverReads() throws {
        try withPath { path in
            let sendFailed = expectation(description: "send failed")
            let closed = expectation(description: "closed")
            let server = server(path, sendTimeout: .milliseconds(100), makeHandler: flooding(sendFailed: sendFailed, closed: closed))
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            try Client.write(Data([1, 0, 0, 0, 42]), to: client)
            wait(for: [sendFailed, closed], timeout: 5)
            XCTAssertTrue(Client.isClosed(client))
        }
    }

    func testAbandoningBlockedSendsEndsAStuckSendWithoutWaitingForTheTimeout() throws {
        try withPath { path in
            let sendFailed = expectation(description: "send failed")
            let closed = expectation(description: "closed")
            let connected = expectation(description: "first frame")
            let handle = OSAllocatedUnfairLock<LocalSocketServer.Connection?>(initialState: nil)
            let server = server(path, sendTimeout: .seconds(60), makeHandler: flooding(sendFailed: sendFailed, closed: closed) { connection in
                handle.withLock { $0 = connection }
                connected.fulfill()
            })
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            try Client.write(Data([1, 0, 0, 0, 42]), to: client)
            wait(for: [connected], timeout: 5)
            handle.withLock { $0 }?.abandonBlockedSends()
            wait(for: [sendFailed, closed], timeout: 5)
        }
    }

    func testBindModeAndStopRemovesSocket() throws {
        try withPath { path in
            let server = server(path)
            try server.start()
            defer { server.stop() }
            var status = stat()
            XCTAssertEqual(lstat(path, &status), 0)
            XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK)
            XCTAssertEqual(status.st_mode & 0o777, 0o600)
            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testStaleSocketIsReplaced() throws {
        try withPath { path in
            try Client.leaveStaleSocket(at: path)
            let server = server(path)
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            XCTAssertEqual(try Client.exchange(Data([42]), on: client), Data([42]))
        }
    }

    func testLiveSocketIsRefused() throws {
        try withPath { path in
            let first = server(path)
            try first.start()
            defer { first.stop() }
            XCTAssertThrowsError(try server(path).start()) {
                XCTAssertEqual($0 as? LocalSocketError, .socketInUse)
            }
            let client = try Client.connect(at: path)
            defer { close(client) }
            XCTAssertEqual(try Client.exchange(Data([42]), on: client), Data([42]))
        }
    }

    func testNonSocketFileIsRefusedAndPreserved() throws {
        try withPath { path in
            let contents = Data("keep".utf8)
            try contents.write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try server(path).start()) {
                XCTAssertEqual($0 as? LocalSocketError, .pathOccupied)
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), contents)
        }
    }

    func testAddressFitsPathsOfUpTo103Bytes() {
        XCTAssertTrue(LocalSocketServer.fitsAddress("/" + String(repeating: "s", count: 102)))
        XCTAssertFalse(LocalSocketServer.fitsAddress("/" + String(repeating: "s", count: 103)))
        XCTAssertFalse(LocalSocketServer.fitsAddress("/" + String(repeating: "é", count: 52)))
    }

    func testPathTooLongIsRefused() {
        XCTAssertThrowsError(try server("/" + String(repeating: "s", count: 108)).start()) {
            XCTAssertEqual($0 as? LocalSocketError, .pathTooLong)
        }
    }

    func testLittleEndianRoundTripAtInboundLimit() throws {
        try withPath { path in
            let server = server(path)
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            let body = Data(repeating: 42, count: 65_536)
            XCTAssertEqual(try Client.exchange(body, on: client), body)
        }
    }

    func testInboundFrameOverCapClosesConnection() throws {
        try withPath { path in
            let server = server(path)
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            try Client.write(Data([1, 0, 1, 0]), to: client)
            XCTAssertTrue(Client.isClosed(client))
        }
    }

    func testDelayedReplyFromAnotherThreadAtOutboundLimit() throws {
        try withPath { path in
            let received = expectation(description: "request received")
            let release = DispatchSemaphore(value: 0)
            let server = server(path) { connection in
                Handler(connection: connection, onFrame: { _, connection in
                    DispatchQueue.global().async {
                        received.fulfill()
                        guard release.wait(timeout: .now() + 5) == .success else { return }
                        connection.send(Data(repeating: 43, count: 1_048_576))
                    }
                })
            }
            try server.start()
            defer { release.signal(); server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            try Client.write(Data([1, 0, 0, 0, 42]), to: client)
            wait(for: [received], timeout: 5)
            release.signal()
            XCTAssertEqual(try Client.readFrame(client), Data(repeating: 43, count: 1_048_576))
        }
    }

    func testCloseCallbackOnPeerDisconnect() throws {
        try withPath { path in
            let closed = expectation(description: "closed")
            closed.assertForOverFulfill = true
            let server = server(path) { Handler(connection: $0, onClose: { closed.fulfill() }) }
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            XCTAssertEqual(try Client.exchange(Data([42]), on: client), Data([42]))
            close(client)
            wait(for: [closed], timeout: 5)
        }
    }

    func testHandlerCanCloseAndReceivesCloseCallback() throws {
        try withPath { path in
            let closed = expectation(description: "closed")
            closed.assertForOverFulfill = true
            let server = server(path) {
                Handler(connection: $0, onFrame: { _, connection in connection.close() }, onClose: { closed.fulfill() })
            }
            try server.start()
            defer { server.stop() }
            let client = try Client.connect(at: path)
            defer { close(client) }
            try Client.write(Data([1, 0, 0, 0, 42]), to: client)
            XCTAssertTrue(Client.isClosed(client))
            wait(for: [closed], timeout: 5)
        }
    }

    func testConnectionCapEvictsLongestWithoutCompleteRequest() throws {
        try withPath { path in
            let server = server(path, cap: 2)
            try server.start()
            defer { server.stop() }
            let first = try Client.connect(at: path)
            defer { close(first) }
            XCTAssertEqual(try Client.exchange(Data([1]), on: first), Data([1]))
            let second = try Client.connect(at: path)
            defer { close(second) }
            XCTAssertEqual(try Client.exchange(Data([2]), on: second), Data([2]))
            XCTAssertEqual(try Client.exchange(Data([3]), on: first), Data([3]))
            // A partial request must not renew the second connection's place.
            try Client.write(Data([1, 0]), to: second)
            let third = try Client.connect(at: path)
            defer { close(third) }
            XCTAssertEqual(try Client.exchange(Data([4]), on: third), Data([4]))
            XCTAssertTrue(Client.isClosed(second))
            XCTAssertEqual(try Client.exchange(Data([5]), on: first), Data([5]))
        }
    }
}

private enum Client {
    struct Failure: Error {
        let errno: Int32
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

    static func exchange(_ body: Data, on descriptor: Int32) throws -> Data {
        let length = body.count
        try write(Data([0, 8, 16, 24].map { UInt8(truncatingIfNeeded: length >> $0) }) + body, to: descriptor)
        return try readFrame(descriptor)
    }

    static func readFrame(_ descriptor: Int32) throws -> Data {
        let prefix = try read(4, from: descriptor)
        let length = prefix.reversed().reduce(0) { $0 << 8 | Int($1) }
        guard length <= 1_048_576 else { throw Failure(errno: EINVAL) }
        return try read(length, from: descriptor)
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

    /// Whether the agent ended the connection: end of stream once whatever
    /// it had already sent is read. False when the read times out instead.
    static func isClosed(_ descriptor: Int32) -> Bool {
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

    static func write(_ data: Data, to descriptor: Int32) throws {
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
