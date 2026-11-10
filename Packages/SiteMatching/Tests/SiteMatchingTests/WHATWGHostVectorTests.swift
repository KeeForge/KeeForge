import XCTest
@testable import SiteMatching

/// Host parsing against the WHATWG URL Standard's test data
/// (`Fixtures/whatwg-url-hosts.json`, selected from web-platform-tests).
///
/// `SiteHost` parses with Foundation's `URL`, which follows RFC 3986, not the
/// WHATWG standard browsers use. The divergences below are that gap, listed
/// so a change in either shows up here.
final class WHATWGHostVectorTests: XCTestCase {
    private static let hostDivergences: [String: String] = [
        // WHATWG strips ASCII tab and newline anywhere; Foundation rejects
        // the URL and the `https://` retry yields the scheme as host.
        "http://example\t.\norg": "tab or newline",
        "http://f:\n/c": "tab or newline",
        "http://ho\tst/": "tab or newline",
        "http://ho\nst/": "tab or newline",
        "http://ho\rst/": "tab or newline",
        // WHATWG reads `\` as `/` in special URLs.
        "http://a:b@c\\": "backslash",
        "http://example.com\\\\foo\\\\bar": "backslash",
        // WHATWG accepts characters RFC 3986 forbids in a host.
        "http://!\"$&'()*+,-.;=_`{}~/": "host code points",
        // WHATWG reads hex, octal, and shortened IPv4 forms as addresses and
        // serializes them dotted-decimal.
        "http://192.0x00A80001": "IPv4 number forms",
        "http://%30%78%63%30%2e%30%32%35%30.01": "IPv4 number forms",
        "http://%30%78%63%30%2e%30%32%35%30.01%2e": "IPv4 number forms",
        "http://\u{FF10}\u{FF38}\u{FF43}\u{FF10}\u{FF0E}\u{FF10}\u{FF12}\u{FF15}\u{FF10}\u{FF0E}\u{FF10}\u{FF11}": "IPv4 number forms",
        "http://192.168.257": "IPv4 number forms",
        "http://192.168.257.": "IPv4 number forms",
        "http://256": "IPv4 number forms",
        "http://999999999": "IPv4 number forms",
        "http://999999999.": "IPv4 number forms",
        "http://4294967295": "IPv4 number forms",
        "http://0xffffffff": "IPv4 number forms",
        "https://0x.0x.0": "IPv4 number forms",
        "https://0x.0x.0x.0x": "IPv4 number forms",
        "https://00.00.00.00": "IPv4 number forms",
        "https://0000000000000000000000000000000000000000177.0.0.1": "IPv4 number forms",
        // WHATWG serializes IPv6 in its compressed form.
        "http://[::127.0.0.1]": "IPv6 serialization",
        "http://[0:0:0:0:0:0:13.1.68.3]": "IPv6 serialization",
        "http://[1:0::]": "IPv6 serialization",
        // WHATWG percent-decodes the host and applies IDNA mapping to it.
        "https://%e2%98%83": "percent-decoded IDNA",
        "https://a%C2%ADb/": "percent-decoded IDNA",
    ]

    /// URLs WHATWG rejects whose host is still publishable here, so an entry
    /// storing one publishes a host no browser requests.
    private static let publishableFailures: [String: String] = [
        "http://%ef%b7%90zyx.com": "noncharacter after percent-decoding",
        "http://\u{FF05}\u{FF14}\u{FF11}.com": "fullwidth percent sign",
        "http://%ef%bc%85%ef%bc%94%ef%bc%91.com": "fullwidth percent sign",
        "http://\u{FF05}\u{FF10}\u{FF10}.com": "fullwidth percent sign",
        "http://%ef%bc%85%ef%bc%90%ef%bc%90.com": "fullwidth percent sign",
        "http://[www.google.com]/": "brackets around a domain",
        "http://[google.com]": "brackets around a domain",
        "http://0..0x300/": "ends in a number",
        "http://0..0x300./": "ends in a number",
        "http://0x100.2.3.4": "ends in a number",
        "http://0x100.2.3.4.": "ends in a number",
        "http://0x1.2.3.4.5": "ends in a number",
        "http://0x1.2.3.4.5.": "ends in a number",
        "http://foo.1.2.3.4": "ends in a number",
        "http://foo.1.2.3.4.": "ends in a number",
        "http://foo.2.3.4": "ends in a number",
        "http://foo.2.3.4.": "ends in a number",
        "http://foo.09": "ends in a number",
        "http://foo.09.": "ends in a number",
        "http://foo.0x4": "ends in a number",
        "http://foo.0x4.": "ends in a number",
        "http://foo.0x": "ends in a number",
        "http://foo.0XFfFfFfFfFfFfFfFfFfAcE123": "ends in a number",
        "http://\u{1F4A9}.123/": "ends in a number",
    ]

    func testHostsMatchWHATWGParsing() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.hosts.count, 167, "Fixture changed; review the divergence list")

        for vector in fixture.hosts where Self.hostDivergences[vector.input] == nil {
            XCTAssertEqual(SiteHost.parse(vector.input), Self.siteForm(of: vector.hostname), vector.input.debugDescription)
        }
        let inputs = Set(fixture.hosts.map(\.input))
        XCTAssertEqual(Set(Self.hostDivergences.keys).subtracting(inputs), [], "Divergence listed for a missing vector")
    }

    func testURLsWHATWGRejectsAreNotPublishable() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.failures.count, 190, "Fixture changed; review the divergence list")

        for input in fixture.failures {
            let publishable = SiteHost(input)?.isPublishable ?? false
            if Self.publishableFailures[input] != nil {
                XCTAssertTrue(publishable, "\(input.debugDescription) is no longer publishable; drop it from the list")
                continue
            }
            XCTAssertFalse(publishable, input.debugDescription)
            XCTAssertNil(SiteHost(publishableWebURL: input), input.debugDescription)
        }
    }

    // MARK: - Fixture

    /// WHATWG's hostname in `SiteHost`'s form: no brackets around IPv6, no
    /// trailing dot, and the `www` rule applied.
    private static func siteForm(of hostname: String) -> String {
        var host = hostname
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return SiteHost.normalize(host)
    }

    private struct Fixture: Decodable {
        struct Host: Decodable {
            let input: String
            let hostname: String
        }
        let hosts: [Host]
        let failures: [String]
    }

    private static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "whatwg-url-hosts", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
