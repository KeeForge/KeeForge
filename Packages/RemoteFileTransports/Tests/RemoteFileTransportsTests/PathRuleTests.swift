import Foundation
import XCTest
@testable import RemoteFileTransports

/// Path and address edge cases the protocol tests do not reach.
final class PathRuleTests: XCTestCase {
    func testFTPPathComponents() {
        XCTAssertEqual(FTPPath.lastComponent(of: "vaults/sub/a.kdbx"), "a.kdbx")
        XCTAssertEqual(FTPPath.lastComponent(of: "/a.kdbx/"), "a.kdbx")
        XCTAssertEqual(FTPPath.lastComponent(of: "/"), "/")
        XCTAssertEqual(FTPPath.parentPath(of: "a.kdbx"), "")
        XCTAssertEqual(FTPPath.parentPath(of: "/a.kdbx"), "/")
        XCTAssertEqual(FTPPath.parentPath(of: "vaults/sub/a.kdbx"), "vaults/sub")
        XCTAssertEqual(FTPPath.parentPath(of: "vaults/sub//"), "vaults")
    }

    func testFTPAddressRejections() {
        for (address, expected) in [
            ("ftp:///vaults", FTPURLError.missingHost),
            ("ftp://nas.local:70000/", .malformed),
            ("ftp://nas.local:0/", .malformed),
            ("ftp://[::1/", .malformed),
        ] {
            XCTAssertThrowsError(try FTPURL.normalizedBaseURL(from: address, allowsUnencryptedFTP: true), address) { error in
                XCTAssertEqual(error as? FTPURLError, expected, address)
            }
        }
    }

    func testFTPLocationNeedsAHost() throws {
        XCTAssertNil(FTPURL.location(fromNormalizedBaseURL: try XCTUnwrap(URL(string: "ftp:///vaults/"))))
    }

    func testUnixListLineNeedsATimeOrYearAfterTheDate() {
        XCTAssertNil(FTPListingParser.parseListLine("-rw-r--r-- 1 alex staff 3072 Sep 18 noon a.kdbx"))
        XCTAssertNil(FTPListingParser.parseListLine("-rw-r--r-- 1 alex staff 3072 Sep 18 12:00 .."))
    }

    func testWebDAVLastComponent() {
        XCTAssertEqual(WebDAVPropfindParser.lastComponent(of: "/Vaults/a.kdbx"), "a.kdbx")
        XCTAssertEqual(WebDAVPropfindParser.lastComponent(of: "/Vaults/"), "Vaults")
        XCTAssertEqual(WebDAVPropfindParser.lastComponent(of: "a.kdbx"), "a.kdbx")
    }

    func testMalformedMultistatusThrows() throws {
        let url = try XCTUnwrap(URL(string: "https://cloud.example.com/dav/"))
        XCTAssertThrowsError(try WebDAVPropfindParser.parse(data: Data("<D:multistatus xmlns:D=\"DAV:\">".utf8), requestURL: url))
    }

    func testHrefsOutsideTheBaseKeepTheirFullPath() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/other/a.kdbx</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href></D:href>
            <D:propstat><D:prop/><D:status>bogus</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let resources = try WebDAVPropfindParser.parse(
            data: Data(xml.utf8),
            requestURL: try XCTUnwrap(URL(string: "https://cloud.example.com/dav/sub/"))
        )
        XCTAssertEqual(resources.map(\.path), ["/other/a.kdbx", "/dav"])
    }

    func testRootBaseKeepsTheWholePath() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/Vaults/a.kdbx?x=1</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let resources = try WebDAVPropfindParser.parse(
            data: Data(xml.utf8),
            requestURL: try XCTUnwrap(URL(string: "https://cloud.example.com"))
        )
        XCTAssertEqual(resources.map(\.path), ["/Vaults/a.kdbx"])
    }
}
