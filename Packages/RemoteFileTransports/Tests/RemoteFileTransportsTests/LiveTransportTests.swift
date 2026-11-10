import Foundation
import Network
import XCTest
@testable import RemoteFileTransports

/// The live `URLSession` transport and `NWConnection` stream against loopback
/// servers: redirects, size caps, and connection lifecycle.
final class WebDAVLiveTransportTests: XCTestCase {
    private let credential = WebDAVClient.Credential(username: "alice", password: "s3cr3t")
    private let authorization = "Basic " + Data("alice:s3cr3t".utf8).base64EncodedString()

    private func url(_ port: UInt16, _ path: String, host: String = "127.0.0.1") throws -> URL {
        try XCTUnwrap(URL(string: "http://\(host):\(port)\(path)"))
    }

    func testGetReturnsBodyAndHeadersAndSendsBasicAuthorization() async throws {
        let server = try await LoopbackHTTPServer { _, _ in
            LoopbackHTTPServer.response(
                status: "200 OK",
                headers: [("ETag", "\"v1\""), ("Last-Modified", "Mon, 12 Jan 1998 09:25:56 GMT")],
                body: Data("hello".utf8)
            )
        }
        let client = WebDAVClient(transport: WebDAVClient.liveTransport())

        let response = try await client.get(url: url(server.port, "/vault.kdbx"), credential: credential)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data("hello".utf8))
        XCTAssertEqual(response.eTag, "\"v1\"")
        XCTAssertEqual(response.contentLength, 5)
        XCTAssertEqual(server.requestHeads.first?.httpHeader("Authorization"), authorization)
    }

    func testSameOriginRedirectIsFollowedWithTheOriginalAuthorization() async throws {
        let server = try await LoopbackHTTPServer { head, port in
            if head.requestLine.hasPrefix("GET /old ") {
                return LoopbackHTTPServer.response(
                    status: "302 Found",
                    headers: [("Location", "http://127.0.0.1:\(port)/new")]
                )
            }
            return LoopbackHTTPServer.response(status: "200 OK", body: Data("moved".utf8))
        }
        let client = WebDAVClient(transport: WebDAVClient.liveTransport())

        let response = try await client.get(url: url(server.port, "/old"), credential: credential)

        XCTAssertEqual(response.data, Data("moved".utf8))
        XCTAssertEqual(server.requestHeads.map(\.requestLine), ["GET /old HTTP/1.1", "GET /new HTTP/1.1"])
        XCTAssertEqual(server.requestHeads.last?.httpHeader("Authorization"), authorization)
    }

    func testCrossOriginRedirectIsNotFollowed() async throws {
        let server = try await LoopbackHTTPServer { _, port in
            LoopbackHTTPServer.response(
                status: "302 Found",
                headers: [("Location", "http://localhost:\(port)/elsewhere")]
            )
        }
        let client = WebDAVClient(transport: WebDAVClient.liveTransport())

        let response = try await client.get(url: url(server.port, "/old"), credential: credential)

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(server.requestHeads.count, 1)
    }

    func testSameOriginComparesSchemeHostAndEffectivePort() throws {
        func origin(_ lhs: String, _ rhs: String) throws -> Bool {
            try WebDAVSessionDelegate.sameOrigin(XCTUnwrap(URL(string: lhs)), XCTUnwrap(URL(string: rhs)))
        }
        XCTAssertTrue(try origin("https://Cloud.example.com/a", "https://cloud.example.com:443/b"))
        XCTAssertTrue(try origin("http://cloud.example.com/a", "HTTP://cloud.example.com:80/b"))
        XCTAssertFalse(try origin("https://cloud.example.com/a", "http://cloud.example.com/a"))
        XCTAssertFalse(try origin("https://cloud.example.com/a", "https://evil.example.com/a"))
        XCTAssertFalse(try origin("https://cloud.example.com/a", "https://cloud.example.com:8443/a"))
    }

    func testAdvertisedOversizedBodyIsRefusedBeforeDownload() async throws {
        let server = try await LoopbackHTTPServer { _, _ in
            LoopbackHTTPServer.response(status: "200 OK", body: Data(count: 100))
        }
        let transport = WebDAVClient.liveTransport(maxPropfindResponseBytes: 1_000, maxBodyResponseBytes: 10)
        let client = WebDAVClient(transport: transport)

        do {
            _ = try await client.get(url: url(server.port, "/vault.kdbx"), credential: credential)
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .responseTooLarge)
        }

        // PROPFIND has its own, larger cap.
        let listing = try await client.propfindList(url: url(server.port, "/"), credential: credential)
        XCTAssertEqual(listing.data.count, 100)
    }

    func testUnframedBodyIsCutOffAtTheCap() async throws {
        let server = try await LoopbackHTTPServer { _, _ in
            LoopbackHTTPServer.unframedResponse(status: "200 OK", body: Data(count: 100))
        }
        let transport = WebDAVClient.liveTransport(maxPropfindResponseBytes: 10, maxBodyResponseBytes: 1_000)
        let client = WebDAVClient(transport: transport)

        do {
            _ = try await client.probe(url: url(server.port, "/"), credential: credential)
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .responseTooLarge)
        }
        let file = try await client.get(url: url(server.port, "/a"), credential: credential)
        XCTAssertEqual(file.data.count, 100)
    }

    func testResponseCapsDefaultToTheProductionValues() throws {
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/"))
        var propfind = URLRequest(url: url)
        propfind.httpMethod = "PROPFIND"
        var get = URLRequest(url: url)
        get.httpMethod = "GET"

        XCTAssertEqual(WebDAVClient.maxPropfindResponseBytes, 64 * 1024 * 1024)
        XCTAssertEqual(WebDAVClient.maxBodyResponseBytes, 512 * 1024 * 1024)
        XCTAssertEqual(WebDAVClient.responseByteLimit(for: propfind), WebDAVClient.maxPropfindResponseBytes)
        XCTAssertEqual(WebDAVClient.responseByteLimit(for: get), WebDAVClient.maxBodyResponseBytes)
    }

    func testRefusedConnectionIsOffline() async throws {
        let server = try await LoopbackHTTPServer { _, _ in Data() }
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let client = WebDAVClient(transport: WebDAVClient.liveTransport())

        do {
            _ = try await client.head(url: url(port, "/"), credential: credential)
            XCTFail("expected a throw")
        } catch {
            // A listener still closing drops the connection instead of refusing it.
            let offline: [WebDAVError] = [.offline(.cannotConnectToHost), .offline(.networkConnectionLost)]
            XCTAssertTrue((error as? WebDAVError).map(offline.contains) ?? false, "\(error)")
        }
    }

    func testNonHTTPResponseIsInvalid() async throws {
        let transport = WebDAVClient.liveTransport()
        do {
            _ = try await transport(URLRequest(url: XCTUnwrap(URL(string: "data:,hello"))))
            XCTFail("expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .invalidResponse)
        }
    }
}

final class FTPNetworkStreamTests: XCTestCase {
    /// Echoes what it receives and closes once the client half-closes.
    private func echoServer() async throws -> LoopbackServer {
        try await LoopbackServer { connection in
            @Sendable func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        connection.send(content: data, completion: .idempotent)
                    }
                    if isComplete || error != nil {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    } else {
                        pump()
                    }
                }
            }
            pump()
        }
    }

    func testSendReceiveHalfCloseAndEnd() async throws {
        let server = try await echoServer()
        let stream = try await FTPNetworkStream.connect(host: "127.0.0.1", port: server.port)
        defer { stream.close() }

        try await stream.send(Data("ping".utf8))
        var echoed = Data()
        while echoed.count < 4, let chunk = try await stream.receive() {
            echoed.append(chunk)
        }
        XCTAssertEqual(echoed, Data("ping".utf8))

        try await stream.finishSending()
        while try await stream.receive() != nil {}
        let afterEnd = try await stream.receive()
        XCTAssertNil(afterEnd)
    }

    func testRefusedConnectionThrows() async throws {
        let server = try await echoServer()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))

        do {
            _ = try await FTPNetworkStream.connect(host: "127.0.0.1", port: port)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is NWError, "\(error)")
        }
    }

    func testCancellingAReceiveCancelsTheConnection() async throws {
        let server = try await LoopbackServer { _ in }
        let stream = try await FTPNetworkStream.connect(host: "127.0.0.1", port: server.port)
        let receive = Task { try await stream.receive() }
        try await Task.sleep(for: .milliseconds(100))
        receive.cancel()

        // The pending receive ends instead of waiting for a silent server,
        // and the connection is gone afterwards.
        _ = try? await receive.value
        do {
            try await stream.send(Data("x".utf8))
            XCTFail("a cancelled connection should not send")
        } catch {
            XCTAssertTrue(error is NWError, "\(error)")
        }
    }

    func testDefaultClientUsesLiveConnections() async throws {
        let server = try await LoopbackServer { connection in
            connection.sendAll(Data("530 Not today\r\n".utf8), thenClose: false)
        }
        let client = FTPClient(timeout: .seconds(5))

        do {
            try await client.withSession(host: "127.0.0.1", port: server.port, username: "u", password: "p") { _ in () }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? FTPClientError, .unexpectedReply(FTPReply(code: 530, lines: ["Not today"])))
        }
    }
}
