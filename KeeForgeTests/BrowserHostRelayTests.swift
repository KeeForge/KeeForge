#if os(macOS)
import XCTest
import Foundation
import Darwin

final class BrowserHostRelayTests: XCTestCase {
    final class Harness: @unchecked Sendable {
        let input = Pipe()
        let output = Pipe()
        let path: String
        let directory: URL
        var listener: Int32 = -1
        var peer: Int32 = -1
        let done = DispatchSemaphore(value: 0)
        let launched = DispatchSemaphore(value: 0)

        init(listening: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("bh-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("b.sock").path
            if listening { try listen() }
            let relayInput = input.fileHandleForReading.fileDescriptor
            let relayOutput = output.fileHandleForWriting.fileDescriptor
            DispatchQueue.global().async { [self] in
                BrowserHostRelay(input: relayInput, output: relayOutput, socketPath: path) {
                    self.launched.signal()
                }.run()
                done.signal()
            }
            if listening { peer = try acceptPeer() }
        }

        func listen() throws {
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "path", code: 1) }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(status, 0)
            XCTAssertEqual(Darwin.listen(listener, 4), 0)
        }

        func acceptPeer() throws -> Int32 {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3000) > 0 else { throw NSError(domain: "accept timeout", code: 1) }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw NSError(domain: "accept", code: 1) }
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }

        func send(_ data: Data) throws { try input.fileHandleForWriting.write(contentsOf: data) }
        func command(_ cmd: String) throws { try send(frame("{\"v\":1,\"t\":\"host\",\"cmd\":\"\(cmd)\"}")) }
        func frame(_ string: String) -> Data { frame(Data(string.utf8)) }
        func frame(_ payload: Data) -> Data {
            let length = UInt32(payload.count)
            return Data([UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
                         UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 24)]) + payload
        }
        func read(_ fd: Int32, count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 3000) > 0 else { throw NSError(domain: "read timeout", code: 1) }
                var buffer = [UInt8](repeating: 0, count: count - result.count)
                let got = Darwin.read(fd, &buffer, buffer.count)
                guard got > 0 else { throw NSError(domain: "EOF", code: 1) }
                result.append(contentsOf: buffer.prefix(got))
            }
            return result
        }
        func event(_ event: String, reason: String? = nil) throws {
            let fd = output.fileHandleForReading.fileDescriptor
            let header = try read(fd, count: 4)
            let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            let json = try JSONSerialization.jsonObject(with: read(fd, count: length)) as! [String: Any]
            XCTAssertEqual(json["event"] as? String, event)
            XCTAssertEqual(json["reason"] as? String, reason)
            XCTAssertEqual(json["v"] as? Int, 1)
            XCTAssertEqual(json["t"] as? String, "host")
        }
        func writePeer(_ bytes: Data) throws {
            try FileHandle(fileDescriptor: peer, closeOnDealloc: false).write(contentsOf: bytes)
        }
        func finish() throws {
            try input.fileHandleForWriting.close()
            XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        }
        deinit {
            if peer >= 0 { close(peer) }
            if listener >= 0 { close(listener) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testByteExactSplitAndMultipleFramesBothDirections() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        let first = h.frame("{ \"t\":\"msg\", \"c\":\"opaque\" }")
        let second = h.frame("{\"t\":\"hello\"}")
        try h.send(Data(first.prefix(2)))
        try h.send(Data(first.dropFirst(2)) + second)
        XCTAssertEqual(try h.read(h.peer, count: first.count + second.count), first + second)
        try h.writePeer(Data(second.prefix(5)))
        try h.writePeer(Data(second.dropFirst(5)) + first)
        XCTAssertEqual(try h.read(h.output.fileHandleForReading.fileDescriptor, count: first.count + second.count), second + first)
    }

    func testDirectionalLimitsAcceptExactMaximumFrames() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        let towardApp = h.frame(Data(repeating: 97, count: 65_536))
        try h.send(towardApp)
        XCTAssertEqual(try h.read(h.peer, count: towardApp.count), towardApp)
        let towardBrowser = h.frame(Data(repeating: 98, count: 1_048_576))
        try h.writePeer(towardBrowser)
        XCTAssertEqual(try h.read(h.output.fileHandleForReading.fileDescriptor, count: towardBrowser.count), towardBrowser)
    }

    func testControlFramesNeverReachAppAndLaunchIsInjected() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        try h.command("unknown")
        try h.command("connect")
        close(h.peer)
        h.peer = try h.acceptPeer()
        try h.event("connected")
        try h.command("launch")
        XCTAssertEqual(h.launched.wait(timeout: .now() + 3), .success)
        close(h.peer)
        h.peer = try h.acceptPeer()
        try h.event("connected")
        let frame = h.frame("{\"t\":\"hello\"}")
        try h.send(frame)
        XCTAssertEqual(try h.read(h.peer, count: frame.count), frame)
    }

    func testConnectAfterQueuedFrameKeepsTheReplacementConnection() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        // One full 16 KiB relay read queues this frame; the next read, in a pass that polled for POLLOUT, carries connect.
        let prefix = "{\"t\":\"msg\",\"c\":\""
        let queued = h.frame(prefix + String(repeating: "a", count: 16_380 - prefix.utf8.count - 2) + "\"}")
        XCTAssertEqual(queued.count, 16_384)
        try h.send(queued + h.frame("{\"v\":1,\"t\":\"host\",\"cmd\":\"connect\"}"))
        let stale = h.peer
        h.peer = try h.acceptPeer()
        close(stale)
        try h.event("connected")
        let reply = h.frame("{\"t\":\"msg\",\"c\":\"reply\"}")
        try h.writePeer(reply)
        XCTAssertEqual(try h.read(h.output.fileHandleForReading.fileDescriptor, count: reply.count), reply)
        let hello = h.frame("{\"t\":\"hello\"}")
        try h.send(hello)
        XCTAssertEqual(try h.read(h.peer, count: hello.count), hello)
    }

    func testLaunchRetriesUntilAppListens() throws {
        let h = try Harness(listening: false)
        defer { try? h.finish() }
        try h.event("unavailable", reason: "not-running")
        try h.command("launch")
        XCTAssertEqual(h.launched.wait(timeout: .now() + 3), .success)
        try h.listen()
        h.peer = try h.acceptPeer()
        try h.event("connected")
    }

    func testUnavailableThenConnectAndReconnectAfterClosure() throws {
        let h = try Harness(listening: false)
        defer { try? h.finish() }
        try h.event("unavailable", reason: "not-running")
        try h.command("connect")
        try h.event("unavailable", reason: "not-running")
        try h.listen()
        try h.command("connect")
        h.peer = try h.acceptPeer()
        try h.event("connected")
        close(h.peer); h.peer = -1
        try h.event("unavailable", reason: "closed")
        try h.command("connect")
        h.peer = try h.acceptPeer()
        try h.event("connected")
        let frame = h.frame("{\"t\":\"hello\"}")
        try h.send(frame)
        XCTAssertEqual(try h.read(h.peer, count: frame.count), frame)
    }

    func testBrowserOversizeClosesSocketWithoutForwardingPartialFrame() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        var length = UInt32(65_537).littleEndian
        try h.send(Data(bytes: &length, count: 4))
        try h.event("unavailable", reason: "closed")
        var descriptor = pollfd(fd: h.peer, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&descriptor, 1, 3000), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(h.peer, &byte, 1), 0)
        try h.send(Data(repeating: 120, count: 65_537))
        try h.command("connect")
        close(h.peer)
        h.peer = try h.acceptPeer()
        try h.event("connected")
    }

    func testAppOversizeAndPartialFrameAreNotForwarded() throws {
        let h = try Harness()
        defer { try? h.finish() }
        try h.event("connected")
        var length = UInt32(1_048_577).littleEndian
        try h.writePeer(Data(bytes: &length, count: 4))
        try h.event("unavailable", reason: "closed")
        close(h.peer); h.peer = -1
        try h.command("connect")
        h.peer = try h.acceptPeer()
        try h.event("connected")
        try h.writePeer(Data(h.frame("{\"t\":\"msg\"}").prefix(7)))
        close(h.peer); h.peer = -1
        try h.event("unavailable", reason: "closed")
    }

    func testStdinEOFEndsLoopWithPartialFrame() throws {
        let h = try Harness(listening: false)
        try h.event("unavailable", reason: "not-running")
        try h.command("launch")
        XCTAssertEqual(h.launched.wait(timeout: .now() + 3), .success)
        try h.send(Data([1, 0]))
        try h.finish()
    }

    func testControlDiscriminatorIgnoresNestedAndEscapedFields() {
        XCTAssertFalse(BrowserHostControl.isHost(Data(#"{"nested":{"t":"host"},"t":"msg"}"#.utf8)))
        XCTAssertTrue(BrowserHostControl.isHost(Data(#"{"other":[{"text":"a\"b"}],"\u0074":"h\u006fst","cmd":"connect"}"#.utf8)))
    }
}
#endif
