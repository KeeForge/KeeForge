import Foundation
import RemoteFileTransportsTestSupport
import XCTest
@testable import RemoteFileTransports

/// `FTPClient` and `FTPSession` against the in-memory server, plus scripted
/// control connections for reply framing the server never produces.
final class FTPSessionTests: XCTestCase {
    private var server: FakeFTPServer!

    override func setUp() {
        super.setUp()
        server = FakeFTPServer()
    }

    private func session<T: Sendable>(
        timeout: Duration = .seconds(5),
        _ body: (FTPSession) async throws -> T
    ) async throws -> T {
        try await server.makeClient(timeout: timeout).withSession(
            host: "nas.local",
            port: FakeFTPServer.controlPort,
            username: "alex",
            password: "secret",
            body
        )
    }

    private func assertThrows<T>(
        _ expected: FTPClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FTPClientError, expected, file: file, line: line)
        }
    }

    // MARK: - Login

    func testLoginSendsUserPassUTF8AndBinaryTypeThenQuits() async throws {
        let result = try await session { _ in 42 }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(server.commandLog, ["USER alex", "PASS ***", "OPTS UTF8 ON", "TYPE I", "QUIT"])
    }

    func testRejectedPasswordThrowsTheReply() async {
        server.password = "other"
        await assertThrows(.unexpectedReply(FTPReply(code: 530, lines: ["Login incorrect"]))) {
            try await session { _ in () }
        }
    }

    func testRefusedTypeThrowsTheReply() async {
        server.overrideNextReply(to: "TYPE", with: "504 Type not supported")
        await assertThrows(.unexpectedReply(FTPReply(code: 504, lines: ["Type not supported"]))) {
            try await session { _ in () }
        }
    }

    func testConnectorErrorPassesThrough() async {
        server.refusesConnections = true
        do {
            try await session { _ in () }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? POSIXError, POSIXError(.ECONNREFUSED))
        }
    }

    func testDroppedControlConnectionIsConnectionClosed() async {
        server.dropConnection(onNext: "CWD")
        await assertThrows(.connectionClosed) {
            try await session { try await $0.changeDirectory("vaults") }
        }
    }

    func testUnansweredCommandTimesOut() async {
        server.addDirectory("vaults")
        server.silentVerbs = ["CWD"]
        await assertThrows(.timedOut) {
            try await session(timeout: .milliseconds(200)) { try await $0.changeDirectory("vaults") }
        }
    }

    // MARK: - Arguments

    func testArgumentsWithLineBreaksOrNULAreRejectedBeforeSending() async {
        for argument in ["a\r\nDELE b", "a\nb", "a\rb", "a\0b"] {
            await assertThrows(.illegalArgument) {
                try await session { try await $0.delete(argument) }
            }
        }
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("DELE") })
    }

    // MARK: - Directories

    func testChangeDirectory() async throws {
        server.addDirectory("vaults")
        try await session { session in
            try await session.changeDirectory("")
            try await session.changeDirectory("vaults")
        }
        XCTAssertEqual(server.commandLog.filter { $0.hasPrefix("CWD") }, ["CWD vaults"])

        await assertThrows(.unexpectedReply(FTPReply(code: 550, lines: ["Failed to change directory"]))) {
            try await session { try await $0.changeDirectory("missing") }
        }
    }

    func testListPrefersMachineListing() async throws {
        server.addDirectory("vaults/archive")
        server.setFile("vaults/a.kdbx", data: Data(count: 3), modified: "20260918120001")

        let entries = try await session { session in
            try await session.changeDirectory("vaults")
            return try await session.listCurrentDirectory()
        }

        XCTAssertEqual(entries, [
            FTPListEntry(name: "a.kdbx", isFolder: false, size: 3, modifiedStamp: "20260918120001"),
            FTPListEntry(name: "archive", isFolder: true, size: nil, modifiedStamp: "20260101000000"),
        ])
        XCTAssertFalse(server.commandLog.contains("LIST"))
    }

    func testListFallsBackToLISTWhenMLSDIsNotImplemented() async throws {
        server.supportsMachineListing = false
        server.addDirectory("archive")
        server.setFile("a.kdbx", data: Data(count: 5))

        let entries = try await session { try await $0.listDirectory("") }

        XCTAssertEqual(entries, [
            FTPListEntry(name: "a.kdbx", isFolder: false, size: 5, modifiedStamp: nil),
            FTPListEntry(name: "archive", isFolder: true, size: nil, modifiedStamp: nil),
        ])
        XCTAssertEqual(server.commandLog.filter { $0 == "MLSD" || $0 == "LIST" }, ["MLSD", "LIST"])
    }

    func testEmptyDirectoryRefusalIsEmptyOnlyWhenNotStrict() async throws {
        server.supportsMachineListing = false
        server.overrideNextReply(to: "LIST", with: "450 No files found")
        let lenient = try await session { try await $0.listCurrentDirectory() }
        XCTAssertEqual(lenient, [])

        server.overrideNextReply(to: "LIST", with: "550 No files found")
        await assertThrows(.unexpectedReply(FTPReply(code: 550, lines: ["No files found"]))) {
            try await session { try await $0.listDirectory("vaults") }
        }
    }

    func testListingThatCannotStartThrowsTheReply() async {
        server.overrideNextReply(to: "MLSD", with: "425 Can't open data connection")
        await assertThrows(.unexpectedReply(FTPReply(code: 425, lines: ["Can't open data connection"]))) {
            try await session { try await $0.listCurrentDirectory() }
        }
    }

    // MARK: - Passive mode

    func testExtendedPassiveConnectsToTheControlHost() async throws {
        _ = try await session { try await $0.listCurrentDirectory() }
        XCTAssertEqual(server.connectionLog, ["nas.local:21", "nas.local:40000"])
    }

    func testPassiveFallbackIgnoresTheAdvertisedAddress() async throws {
        server.supportsExtendedPassive = false
        _ = try await session { try await $0.listCurrentDirectory() }
        XCTAssertEqual(server.connectionLog, ["nas.local:21", "nas.local:40000"])
        XCTAssertTrue(server.commandLog.contains("PASV"))
    }

    func testExtendedPassiveSyntaxErrorFallsBackToPassive() async throws {
        server.overrideNextReply(to: "EPSV", with: "501 Syntax error")
        _ = try await session { try await $0.listCurrentDirectory() }
        XCTAssertTrue(server.commandLog.contains("PASV"))
    }

    func testPassiveReplyFailures() async {
        server.overrideNextReply(to: "EPSV", with: "229 Entering Extended Passive Mode (|||x|)")
        await assertThrows(.malformedReply("Entering Extended Passive Mode (|||x|)")) {
            try await session { try await $0.listCurrentDirectory() }
        }

        server.overrideNextReply(to: "EPSV", with: "421 Too many connections")
        await assertThrows(.unexpectedReply(FTPReply(code: 421, lines: ["Too many connections"]))) {
            try await session { try await $0.listCurrentDirectory() }
        }

        server.supportsExtendedPassive = false
        server.overrideNextReply(to: "PASV", with: "421 Too many connections")
        await assertThrows(.unexpectedReply(FTPReply(code: 421, lines: ["Too many connections"]))) {
            try await session { try await $0.listCurrentDirectory() }
        }

        server.overrideNextReply(to: "PASV", with: "227 Entering Passive Mode")
        await assertThrows(.malformedReply("Entering Passive Mode")) {
            try await session { try await $0.listCurrentDirectory() }
        }
    }

    // MARK: - Stat

    func testStatUsesMLST() async throws {
        server.setFile("vaults/a.kdbx", data: Data(count: 4), modified: "20260918120001")
        let entry = try await session { try await $0.stat("vaults/a.kdbx") }

        XCTAssertEqual(entry, FTPListEntry(name: "a.kdbx", isFolder: false, size: 4, modifiedStamp: "20260918120001"))
        XCTAssertFalse(server.commandLog.contains { $0.hasPrefix("SIZE") })
    }

    func testStatFallsBackToSizeAndModificationTime() async throws {
        server.supportsMachineListing = false
        server.setFile("a.kdbx", data: Data(count: 4), modified: "20260918120001")
        let entry = try await session { try await $0.stat("a.kdbx") }
        XCTAssertEqual(entry, FTPListEntry(name: "a.kdbx", isFolder: false, size: 4, modifiedStamp: "20260918120001"))

        server.supportsModificationTime = false
        let unstamped = try await session { try await $0.stat("a.kdbx") }
        XCTAssertEqual(unstamped?.modifiedStamp, nil)

        server.supportsModificationTime = true
        server.overrideNextReply(to: "MDTM", with: "213 yesterday")
        let garbled = try await session { try await $0.stat("a.kdbx") }
        XCTAssertEqual(garbled?.modifiedStamp, nil)
    }

    func testStatOfAMissingFileIsNilOnceAListingShowsIt() async throws {
        server.setFile("vaults/other.kdbx", data: Data())
        let missing = try await session { try await $0.stat("vaults/a.kdbx") }
        XCTAssertNil(missing)
        XCTAssertTrue(server.commandLog.contains("MLSD vaults"))
    }

    func testStatMatchesACaseOnlyDifferenceInTheParentListing() async throws {
        server.supportsMachineListing = false
        server.setFile("A.KDBX", data: Data(count: 2))
        server.overrideNextReply(to: "SIZE", with: "550 Permission denied")
        let entry = try await session { try await $0.stat("a.kdbx") }
        XCTAssertEqual(entry?.name, "A.KDBX")
    }

    func testStatCannotProveAHiddenNameAbsentFromLIST() async {
        server.supportsMachineListing = false
        await assertThrows(.accessDenied(FTPReply(code: 550, lines: ["Could not get file size"]))) {
            try await session { try await $0.stat(".keeforge-upload") }
        }
    }

    func testStatIsAccessDeniedWhenTheParentCannotBeListed() async {
        server.supportsMachineListing = false
        await assertThrows(.accessDenied(FTPReply(code: 550, lines: ["Could not get file size"]))) {
            try await session { try await $0.stat("missing/a.kdbx") }
        }
    }

    func testStatRejectsUnexpectedReplies() async {
        server.overrideNextReply(to: "MLST", with: "250-Listing\r\n250 End")
        await assertThrows(.malformedReply("Listing\nEnd")) {
            try await session { try await $0.stat("a.kdbx") }
        }

        server.overrideNextReply(to: "MLST", with: "421 Closing")
        await assertThrows(.unexpectedReply(FTPReply(code: 421, lines: ["Closing"]))) {
            try await session { try await $0.stat("a.kdbx") }
        }

        server.supportsMachineListing = false
        server.overrideNextReply(to: "SIZE", with: "213 many")
        await assertThrows(.unexpectedReply(FTPReply(code: 213, lines: ["many"]))) {
            try await session { try await $0.stat("a.kdbx") }
        }

        server.overrideNextReply(to: "SIZE", with: "421 Closing")
        await assertThrows(.unexpectedReply(FTPReply(code: 421, lines: ["Closing"]))) {
            try await session { try await $0.stat("a.kdbx") }
        }

        server.setFile("a.kdbx", data: Data())
        server.overrideNextReply(to: "MDTM", with: "421 Closing")
        await assertThrows(.unexpectedReply(FTPReply(code: 421, lines: ["Closing"]))) {
            try await session { try await $0.stat("a.kdbx") }
        }
    }

    // MARK: - Transfers

    func testStoreThenRetrieveRoundTripsMoreThanOneChunk() async throws {
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try await session { try await $0.store("a.kdbx", data: payload) }
        XCTAssertEqual(server.file("a.kdbx")?.data, payload)

        let fetched = try await session { try await $0.retrieve("a.kdbx") }
        XCTAssertEqual(fetched, payload)
    }

    func testTransfersThatCannotStartThrowTheReply() async {
        await assertThrows(.unexpectedReply(FTPReply(code: 550, lines: ["Failed to open file"]))) {
            try await session { try await $0.retrieve("missing.kdbx") }
        }

        server.overrideNextReply(to: "STOR", with: "553 Could not create file")
        await assertThrows(.unexpectedReply(FTPReply(code: 553, lines: ["Could not create file"]))) {
            try await session { try await $0.store("a.kdbx", data: Data([1])) }
        }
    }

    func testRenameAndDelete() async throws {
        server.setFile("a.tmp", data: Data([1]))
        try await session { try await $0.rename("a.tmp", to: "a.kdbx") }
        XCTAssertEqual(server.filePaths, ["a.kdbx"])

        try await session { try await $0.delete("a.kdbx") }
        XCTAssertEqual(server.filePaths, [])

        await assertThrows(.unexpectedReply(FTPReply(code: 550, lines: ["Delete operation failed"]))) {
            try await session { try await $0.delete("a.kdbx") }
        }
        await assertThrows(.unexpectedReply(FTPReply(code: 550, lines: ["RNFR command failed"]))) {
            try await session { try await $0.rename("a.tmp", to: "a.kdbx") }
        }
    }

    func testRenameOntoAnExistingFileCanBeRefused() async {
        server.renameReplacesExisting = false
        server.setFile("a.tmp", data: Data([1]))
        server.setFile("a.kdbx", data: Data([2]))
        await assertThrows(.renameRefused(FTPReply(code: 550, lines: ["Cannot rename: file exists"]))) {
            try await session { try await $0.rename("a.tmp", to: "a.kdbx") }
        }
    }

    // MARK: - Reply framing (scripted control connection)

    private func scripted(_ serverBytes: [UInt8]) -> (FTPClient, ScriptedStream) {
        let stream = ScriptedStream(serverBytes)
        let client = FTPClient(connector: { _, _ in stream }, timeout: .seconds(5))
        return (client, stream)
    }

    private func scripted(_ serverText: String) -> (FTPClient, ScriptedStream) {
        scripted(Array(serverText.utf8))
    }

    private static let loginReplies = "331 Password\r\n230 Logged in\r\n200 UTF8\r\n200 Binary\r\n221 Bye\r\n"

    func testPreliminaryGreetingIsSkippedAndUSERAloneCanLogIn() async throws {
        // 120 "Service ready in nnn minutes" precedes 220 (RFC 959, 4.2.2);
        // 230 straight after USER needs no PASS.
        let (client, stream) = scripted("120 Ready in 1 minute\r\n220 Ready\r\n230 Logged in\r\n200 UTF8\r\n200 Binary\r\n221 Bye\r\n")
        try await client.withSession(host: "h", port: 21, username: "anonymous", password: "x") { _ in () }
        XCTAssertEqual(stream.sentLines, ["USER anonymous", "OPTS UTF8 ON", "TYPE I", "QUIT"])
    }

    func testMalformedRepliesAreRejected() async {
        for (text, fragment) in [("hello\r\n", "hello"), ("999 Too big\r\n", "999 Too big"), ("22\r\n", "22")] {
            let (client, _) = scripted(text)
            await assertThrows(.malformedReply(fragment)) {
                try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
            }
        }
    }

    func testAnOverlongLineIsRejected() async {
        let (client, _) = scripted(Array(repeating: UInt8(ascii: "2"), count: 70_000))
        await assertThrows(.malformedReply(String(repeating: "2", count: 80))) {
            try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
        }
    }

    func testAConnectionClosedMidReplyIsConnectionClosed() async {
        let (client, _) = scripted("220-Welcome\r\n")
        await assertThrows(.connectionClosed) {
            try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
        }
    }

    func testNonUTF8ReplyTextIsReadAsLatin1() async {
        let (client, _) = scripted(Array("530 caf".utf8) + [0xE9] + Array("\r\n".utf8))
        await assertThrows(.unexpectedReply(FTPReply(code: 530, lines: ["caf\u{E9}"]))) {
            try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
        }
    }

    func testFullLoginScriptAgainstTheScriptedStream() async throws {
        let (client, stream) = scripted("220 Ready\r\n" + Self.loginReplies)
        try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
        XCTAssertEqual(stream.sentLines, ["USER u", "PASS p", "OPTS UTF8 ON", "TYPE I", "QUIT"])
        XCTAssertTrue(stream.isClosed)
    }
}

/// A control connection that plays back fixed server bytes, whatever the
/// client sends, and records the client's lines.
final class ScriptedStream: FTPByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8]
    private var sent = Data()
    private var closed = false

    init(_ serverBytes: [UInt8]) {
        pending = serverBytes
    }

    var sentLines: [String] {
        lock.withLock {
            String(decoding: sent, as: UTF8.self)
                .components(separatedBy: "\r\n")
                .filter { !$0.isEmpty }
        }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func send(_ data: Data) async throws {
        lock.withLock { sent.append(data) }
    }

    /// Small chunks, so replies split across reads are exercised too.
    func receive() async throws -> Data? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            let chunk = pending.prefix(7)
            pending.removeFirst(chunk.count)
            return Data(chunk)
        }
    }

    func finishSending() async throws {}

    func close() {
        lock.withLock { closed = true }
    }
}
