import Foundation
import RemoteFileTransportsTestSupport
import XCTest
@testable import RemoteFileTransports

/// Known answers from the protocol specifications and from LIST lines real
/// servers print. Sources are in `Fixtures/README.md`.
final class WebDAVKnownAnswerTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// RFC 4918 9.1.3: one resource, a 200 propstat and a 403 propstat. Only the
    /// 200 block contributes, and it carries no DAV: properties.
    func testRFC4918NamedPropertiesWithMixedPropstatStatuses() throws {
        let data = try fixture("rfc4918-9.1.3-named-properties")
        let requestURL = try XCTUnwrap(URL(string: "http://www.example.com/file"))

        let resources = try WebDAVPropfindParser.parse(data: data, requestURL: requestURL, includeSelf: true)

        XCTAssertEqual(resources, [
            WebDAVResource(path: "/", name: "file", isFolder: false, eTag: nil, lastModified: nil, contentLength: nil),
        ])
        XCTAssertEqual(try WebDAVPropfindParser.parse(data: data, requestURL: requestURL), [])
    }

    /// RFC 4918 9.1.5: `PROPFIND /container/`, Depth 1, relative hrefs. The
    /// collection's own entry is dropped; lockentry children are not types.
    func testRFC4918AllpropListing() throws {
        let data = try fixture("rfc4918-9.1.5-allprop")
        let requestURL = try XCTUnwrap(URL(string: "http://www.example.com/container/"))

        let resources = try WebDAVPropfindParser.parse(data: data, requestURL: requestURL)

        XCTAssertEqual(resources, [
            WebDAVResource(
                path: "/front.html",
                name: "front.html",
                isFolder: false,
                eTag: "\"zzyzx\"",
                lastModified: Date(timeIntervalSince1970: 884_597_156),
                contentLength: 4525
            ),
        ])

        let withSelf = try WebDAVPropfindParser.parse(data: data, requestURL: requestURL, includeSelf: true)
        XCTAssertEqual(withSelf.first?.name, "container")
        XCTAssertEqual(withSelf.first?.isFolder, true)
    }

    /// RFC 4918 8.3.1: `PROPFIND /sample/`, Depth 1, absolute hrefs, and a
    /// member whose name has an encoded space. Decoded exactly once.
    func testRFC4918PercentEncodedAbsoluteHref() throws {
        let data = try fixture("rfc4918-8.3.1-url-handling")
        let requestURL = try XCTUnwrap(URL(string: "http://example.com/sample/"))

        let resources = try WebDAVPropfindParser.parse(data: data, requestURL: requestURL)

        XCTAssertEqual(resources, [
            WebDAVResource(path: "/a test", name: "a test", isFolder: false, eTag: nil, lastModified: nil, contentLength: nil),
        ])
    }

    /// RFC 7231 7.1.1.1 IMF-fixdate, as RFC 4918 uses for getlastmodified.
    func testRFC1123DateFromTheRFC4918Example() {
        XCTAssertEqual(
            WebDAVPropfindParser.parseRFC1123("Mon, 12 Jan 1998 09:25:56 GMT"),
            Date(timeIntervalSince1970: 884_597_156)
        )
        XCTAssertNil(WebDAVPropfindParser.parseRFC1123("1998-01-12T09:25:56Z"))
        XCTAssertNil(WebDAVPropfindParser.parseRFC1123(""))
        XCTAssertNil(WebDAVPropfindParser.parseRFC1123(nil))
    }
}

final class FTPKnownAnswerTests: XCTestCase {
    // MARK: - RFC 3659 time values (2.3) and MDTM (3.4)

    func testRFC3659TimeValues() {
        let cases: [(String, TimeInterval)] = [
            ("19980615100045.014", 897_904_845.014),
            ("19980705132316", 899_644_996),
            ("19990929003355", 938_565_235),
            ("19991005213102", 939_159_062),
        ]
        for (value, seconds) in cases {
            XCTAssertTrue(FTPListingParser.isTimeVal(value), value)
            let date = FTPListEntry.date(fromTimeVal: value)
            XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, seconds, accuracy: 0.0005, value)
        }
    }

    func testRFC3659TimeValueGrammarRejects() {
        // "." MUST NOT appear unless a digit follows; exactly 14 digits first.
        for value in ["19980615100045.", "1998061510004", "199806151000450", "19981315100045", "1998O615100045", ""] {
            XCTAssertNil(FTPListEntry.date(fromTimeVal: value), value)
        }
    }

    // MARK: - RFC 3659 MLSx entries (7.7)

    func testRFC3659MLSTAndMLSDEntries() {
        // 7.7.1, an MLST fact line: one leading space, a full pathname.
        XCTAssertEqual(
            FTPListingParser.parseMachineEntry(" Type=file;Size=1024990;Perm=r; /tmp/cap60.pl198.tar.gz"),
            FTPListEntry(name: "cap60.pl198.tar.gz", isFolder: false, size: 1_024_990, modifiedStamp: nil)
        )
        // 7.7.2, MLST of a directory.
        XCTAssertEqual(
            FTPListingParser.parseMachineEntry(" Type=dir;Modify=19981107085215;Perm=el; /tmp"),
            FTPListEntry(name: "tmp", isFolder: true, size: nil, modifiedStamp: "19981107085215")
        )
        // 7.7.3, an MLSD data line for the parent directory.
        XCTAssertNil(FTPListingParser.parseMachineEntry("Type=pdir;Modify=19990112030508;Perm=el; .."))
        // 7.7.5, a fractional modify fact.
        let accurate = FTPListingParser.parseMachineEntry(" Type=file;Modify=19990929003355.237; file1")
        XCTAssertEqual(accurate?.modifiedStamp, "19990929003355.237")
        XCTAssertEqual(accurate?.modifiedDate?.timeIntervalSince1970 ?? 0, 938_565_235.237, accuracy: 0.0005)
    }

    func testRFC3659MLSTReplyThroughASession() async throws {
        // 7.2: "250-" first line, fact lines indented by one space, "250" last.
        let server = FakeFTPServer()
        server.overrideNextReply(
            to: "MLST",
            with: "250- Listing cap60.pl198.tar.gz\r\n Type=file;Size=1024990;Perm=r; /tmp/cap60.pl198.tar.gz\r\n250 End"
        )
        let entry = try await server.makeClient().withSession(
            host: "h", port: FakeFTPServer.controlPort, username: "alex", password: "secret"
        ) { try await $0.stat("cap60.pl198.tar.gz") }

        XCTAssertEqual(entry, FTPListEntry(name: "cap60.pl198.tar.gz", isFolder: false, size: 1_024_990, modifiedStamp: nil))
    }

    func testRFC3659MDTMRepliesThroughASession() async throws {
        let server = FakeFTPServer()
        server.supportsMachineListing = false
        server.setFile("D", data: Data(count: 3))
        let client = server.makeClient()
        func stat() async throws -> FTPListEntry? {
            try await client.withSession(host: "h", port: FakeFTPServer.controlPort, username: "alex", password: "secret") {
                try await $0.stat("D")
            }
        }

        server.overrideNextReply(to: "MDTM", with: "213 19980615100045.014")
        let stamped = try await stat()
        XCTAssertEqual(stamped?.modifiedStamp, "19980615100045.014")

        server.overrideNextReply(to: "MDTM", with: "550 D is not retrievable")
        let unstamped = try await stat()
        XCTAssertEqual(unstamped, FTPListEntry(name: "D", isFolder: false, size: 3, modifiedStamp: nil))
    }

    // MARK: - RFC 959 replies (4.2)

    func testRFC959MultiLineReply() async {
        // 4.2: the reply ends at the code followed by a space; a line that
        // merely starts with digits does not end it.
        let stream = ScriptedStream(Array("123-First line\r\nSecond line\r\n  234 A line beginning with numbers\r\n123 The last line\r\n".utf8))
        let client = FTPClient(connector: { _, _ in stream })
        do {
            try await client.withSession(host: "h", port: 21, username: "u", password: "p") { _ in () }
            XCTFail("a 123 greeting is not a 220")
        } catch {
            XCTAssertEqual(
                error as? FTPClientError,
                .unexpectedReply(FTPReply(
                    code: 123,
                    lines: ["First line", "Second line", "  234 A line beginning with numbers", "The last line"]
                ))
            )
        }
    }

    func testRFC959PassiveReply() {
        // 4.2.2 format "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)." and the
        // 5.2 figure's bare "A1,A2,A3,A4,a1,a2"; only the port is used.
        XCTAssertEqual(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,20,4,1)."), 1025)
        XCTAssertEqual(FTPListingParser.passivePort(from: "Entering Passive Mode. 10,0,0,1,195,149"), 50069)
        XCTAssertNil(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,20,256,1)."))
        XCTAssertNil(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,20,0,0)."))
        XCTAssertNil(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,4,1)."))
    }

    // MARK: - RFC 2428 EPSV (3)

    func testRFC2428ExtendedPassiveReply() {
        XCTAssertEqual(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (|||6446|)"), 6446)
        // Any ASCII 33-126 delimiter is allowed (section 2).
        XCTAssertEqual(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (!!!6446!)"), 6446)
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (|||0|)"))
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (|||70000|)"))
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (||6446|)"))
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode ()"))
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode"))
    }

    // MARK: - LIST lines from real servers (Apache Commons Net samples)

    func testUnixListLinesAsServersPrintThem() {
        let cases: [(String, FTPListEntry?)] = [
            ("-rw-r--r--   1 500      500            21 Aug  8 14:14 JB3-TES1.gz",
             FTPListEntry(name: "JB3-TES1.gz", isFolder: false, size: 21, modifiedStamp: nil)),
            ("drwxr-xr-x   2 root     root         4096 Aug 24  2001 zxjdbc",
             FTPListEntry(name: "zxjdbc", isFolder: true, size: nil, modifiedStamp: nil)),
            // One owner/group column.
            ("drwxr-xr-x 1 usernameftp 512 Jan 29 23:32 prog",
             FTPListEntry(name: "prog", isFolder: true, size: nil, modifiedStamp: nil)),
            ("lrw-r--r--   1 14       14          80284 Aug 22  2000 zxJDBC-1.2.3.tar.gz",
             FTPListEntry(name: "zxJDBC-1.2.3.tar.gz", isFolder: false, size: 80284, modifiedStamp: nil)),
            ("lrwxrwxrwx   1 neeme neeme             23 Mar  2 18:06 macros -> ./../../global/macros/.",
             FTPListEntry(name: "macros", isFolder: false, size: 23, modifiedStamp: nil)),
            // A group name with a space, as Windows servers in Unix mode print.
            ("drwx------ 4 maxm Domain Users 512 Oct 2 10:59 .metadata",
             FTPListEntry(name: ".metadata", isFolder: true, size: nil, modifiedStamp: nil)),
            // Device and other types are not files this client opens.
            ("frw-r--r--   1 14       staff      119926 Aug 22  2000 zxJDBC-1.2.3.zip", nil),
            ("crw-r--r--   1 ftp      nogroup     83853 Jan 22  2001 zxJDBC-1.2.4.tar.gz", nil),
            ("brw-r--r--   1 ftp      nogroup    126552 Jan 22  2001 zxJDBC-1.2.4.zip", nil),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(FTPListingParser.parseListLine(line), expected, line)
        }
    }

    func testDOSListLinesAsServersPrintThem() {
        let cases: [(String, FTPListEntry)] = [
            ("05-26-95  10:57AM               143712 $LDR$",
             FTPListEntry(name: "$LDR$", isFolder: false, size: 143_712, modifiedStamp: nil)),
            ("05-20-97  03:31PM                  681 .bash_history",
             FTPListEntry(name: ".bash_history", isFolder: false, size: 681, modifiedStamp: nil)),
            ("12-05-96  05:03PM       <DIR>          absoft2",
             FTPListEntry(name: "absoft2", isFolder: true, size: nil, modifiedStamp: nil)),
            ("12-05-96  17:03         <DIR>          absoft2",
             FTPListEntry(name: "absoft2", isFolder: true, size: nil, modifiedStamp: nil)),
            ("09-06-06  19:00                   69 desktop.ini",
             FTPListEntry(name: "desktop.ini", isFolder: false, size: 69, modifiedStamp: nil)),
            ("09-13-10  13:08       <DIR>          My Documents",
             FTPListEntry(name: "My Documents", isFolder: true, size: nil, modifiedStamp: nil)),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(FTPListingParser.parseListLine(line), expected, line)
        }
    }
}
