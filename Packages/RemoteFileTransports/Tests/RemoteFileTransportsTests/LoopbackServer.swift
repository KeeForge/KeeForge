import Foundation
import Network
import os

/// A TCP listener on 127.0.0.1 for exercising the live transports without
/// leaving the machine. Each accepted connection is handed to `onConnection`.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private static let queue = DispatchQueue(label: "loopback-server")
    let port: UInt16

    init(onConnection: @escaping @Sendable (NWConnection) -> Void) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: Self.queue)
            onConnection(connection)
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                default: result = nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: Self.queue)
        }
        self.listener = listener
        self.port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    deinit {
        listener.cancel()
    }
}

extension NWConnection {
    func sendAll(_ data: Data, thenClose: Bool) {
        send(content: data, completion: .contentProcessed { [self] _ in
            if thenClose { cancel() }
        })
    }

    /// Accumulates bytes until `isDone` says the message is complete.
    func receiveUntil(
        _ buffer: Data = Data(),
        isDone: @escaping @Sendable (Data) -> Bool,
        then: @escaping @Sendable (Data) -> Void
    ) {
        receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if isDone(accumulated) || isComplete || error != nil {
                then(accumulated)
            } else {
                receiveUntil(accumulated, isDone: isDone, then: then)
            }
        }
    }
}

/// A one-request-per-connection HTTP/1.1 server. `respond` gets the request
/// head (request line and headers) and returns the raw response bytes.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let heads = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let server: LoopbackServer

    var port: UInt16 { server.port }

    var requestHeads: [String] {
        heads.withLock { $0 }
    }

    init(respond: @escaping @Sendable (_ head: String, _ port: UInt16) -> Data) async throws {
        let heads = heads
        let portBox = OSAllocatedUnfairLock<UInt16>(initialState: 0)
        server = try await LoopbackServer { connection in
            connection.receiveUntil(isDone: { $0.range(of: Data("\r\n\r\n".utf8)) != nil }) { data in
                let head = String(decoding: data, as: UTF8.self)
                heads.withLock { $0.append(head) }
                connection.sendAll(respond(head, portBox.withLock { $0 }), thenClose: true)
            }
        }
        portBox.withLock { $0 = server.port }
    }

    func stop() {
        server.stop()
    }

    static func response(
        status: String,
        headers: [(String, String)] = [],
        body: Data = Data(),
        contentLength: Int? = nil
    ) -> Data {
        var text = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(contentLength ?? body.count)\r\n"
        return Data((text + "\r\n").utf8) + body
    }

    /// A body with no Content-Length, ended only by closing the connection.
    static func unframedResponse(status: String, body: Data) -> Data {
        Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8) + body
    }
}

extension String {
    /// The value of `name` in an HTTP request head, case-insensitively.
    func httpHeader(_ name: String) -> String? {
        for line in components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    var requestLine: String {
        components(separatedBy: "\r\n").first ?? ""
    }
}
