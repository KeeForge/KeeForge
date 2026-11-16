#if os(macOS)
import Foundation
import Darwin

struct BrowserHostFrames {
    var buffer = Data()
    var discarding: UInt64 = 0
    let limit: Int

    mutating func append(_ data: Data, frame: (Data) -> Void, oversized: () -> Void) {
        buffer.append(data)
        while true {
            if discarding > 0 {
                let count = min(UInt64(buffer.count), discarding)
                buffer.removeFirst(Int(count))
                discarding -= count
                if discarding > 0 { return }
            }
            guard buffer.count >= 4 else { return }
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            if length > limit {
                buffer.removeFirst(4)
                discarding = UInt64(length)
                oversized()
                continue
            }
            guard buffer.count >= length + 4 else { return }
            let complete = Data(buffer.prefix(length + 4))
            buffer.removeFirst(length + 4)
            frame(complete)
        }
    }

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var result = Data(bytes: &length, count: 4)
        result.append(payload)
        return result
    }
}

final class BrowserHostRelay {
    let input: Int32
    let output: Int32
    let socketPath: String?
    let launch: () -> Void
    private var connection: Int32 = -1
    // A replaced socket usually reuses the descriptor number, so poll results are matched by generation.
    private var generation = 0
    private var toBrowser = Data()
    private var toApp = Data()
    private var appFrames = BrowserHostFrames(limit: 1_048_576)
    private var retryUntil: TimeInterval?

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, socketPath: String?, launch: @escaping () -> Void) {
        self.input = input
        self.output = output
        self.socketPath = socketPath
        self.launch = launch
    }

    func run() {
        let inputFlags = fcntl(input, F_GETFL)
        let outputFlags = fcntl(output, F_GETFL)
        _ = fcntl(input, F_SETFL, inputFlags | O_NONBLOCK)
        _ = fcntl(output, F_SETFL, outputFlags | O_NONBLOCK)
        defer {
            disconnect()
            _ = fcntl(input, F_SETFL, inputFlags)
            _ = fcntl(output, F_SETFL, outputFlags)
        }
        attemptConnect(reportFailure: true)
        var browserFrames = BrowserHostFrames(limit: 65_536)
        while true {
            if let deadline = retryUntil {
                attemptConnect(reportFailure: false)
                if connection >= 0 { retryUntil = nil }
                else if ProcessInfo.processInfo.systemUptime >= deadline {
                    retryUntil = nil
                    event("unavailable", reason: "not-running")
                }
            }
            // Backpressure bounds queues while stdin remains observable for EOF.
            var descriptors = [
                pollfd(fd: input, events: Int16(toApp.count < 131_072 && toBrowser.count < 2_097_152 ? POLLIN : 0), revents: 0),
                pollfd(fd: output, events: Int16(toBrowser.isEmpty ? 0 : POLLOUT), revents: 0),
                pollfd(fd: connection, events: Int16((toBrowser.count < 2_097_152 ? POLLIN : 0) | (toApp.isEmpty ? 0 : POLLOUT)), revents: 0)
            ]
            let polledGeneration = generation
            let polled = poll(&descriptors, nfds_t(descriptors.count), retryUntil == nil ? -1 : 100)
            if polled < 0 { if errno == EINTR { continue }; return }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                guard let bytes = readAvailable(input) else { return }
                browserFrames.append(bytes, frame: { self.receiveBrowser($0) }, oversized: {
                    self.disconnect()
                    self.event("unavailable", reason: "closed")
                })
            }
            if descriptors[1].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            if descriptors[1].revents & Int16(POLLOUT) != 0, !flush(output, data: &toBrowser) { return }
            guard connection >= 0, generation == polledGeneration else { continue }
            if descriptors[2].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                if let bytes = readAvailable(connection) {
                    var frames = appFrames
                    frames.append(bytes, frame: { if self.connection >= 0 { self.toBrowser.append($0) } }, oversized: {
                        self.disconnect()
                        self.event("unavailable", reason: "closed")
                    })
                    if connection >= 0 { appFrames = frames }
                } else {
                    disconnect()
                    event("unavailable", reason: "closed")
                }
            }
            if connection >= 0, descriptors[2].revents & Int16(POLLOUT) != 0, !flush(connection, data: &toApp) {
                disconnect()
                event("unavailable", reason: "closed")
            }
        }
    }

    private func receiveBrowser(_ frame: Data) {
        let payload = Data(frame.dropFirst(4))
        if BrowserHostControl.isHost(payload) {
            let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            switch object?["cmd"] as? String {
            case "connect":
                retryUntil = nil
                disconnect()
                attemptConnect(reportFailure: true)
            case "launch":
                disconnect()
                launch()
                retryUntil = ProcessInfo.processInfo.systemUptime + 10
            default: break
            }
        } else if connection >= 0 {
            toApp.append(frame)
        }
    }

    private func event(_ name: String, reason: String? = nil) {
        var json: [String: Any] = ["v": 1, "t": "host", "event": name]
        if let reason { json["reason"] = reason }
        if let payload = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            toBrowser.append(BrowserHostFrames.encode(payload))
        }
    }

    private func disconnect() {
        if connection >= 0 { close(connection); generation += 1 }
        connection = -1
        toApp.removeAll()
        appFrames = BrowserHostFrames(limit: 1_048_576)
    }

    private func attemptConnect(reportFailure: Bool) {
        guard connection < 0 else { return }
        if let socketPath { connection = Self.connectSocket(socketPath) }
        if connection >= 0 { generation += 1 }
        if connection >= 0 { event("connected") }
        else if reportFailure { event("unavailable", reason: "not-running") }
    }

    static func connectSocket(_ path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    private func readAvailable(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = read(fd, &bytes, bytes.count)
        if count > 0 { return Data(bytes.prefix(count)) }
        if count < 0, errno == EINTR || errno == EAGAIN { return Data() }
        return nil
    }

    private func flush(_ fd: Int32, data: inout Data) -> Bool {
        guard !data.isEmpty else { return true }
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if count > 0 { data.removeFirst(count); return true }
        return count < 0 && (errno == EINTR || errno == EAGAIN)
    }
}
#endif
