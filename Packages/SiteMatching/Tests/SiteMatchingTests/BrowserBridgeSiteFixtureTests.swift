import XCTest
import SiteMatching

/// The browser bridge's conformance cases for site matching
/// (`TestFixtures/browser-bridge/site-matching.json`, format in its README),
/// run against the package alone. The bridge classifies each entry on its own
/// against a `.url(origin)` request and lists exact entries before possible
/// ones, each in entry order. The app runs the same file through its real
/// `matches` path in `BrowserBridgeFixtureTests`.
final class BrowserBridgeSiteFixtureTests: XCTestCase {
    func testBridgeSiteMatchingFixture() throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.version, 1, "Unrecognised fixture version")
        XCTAssertGreaterThan(fixture.cases.count, 30, "Fixture cases missing")

        for testCase in fixture.cases {
            XCTAssertEqual(Set(testCase.entries.map(\.id)).count, testCase.entries.count, "\(testCase.name): duplicate entry ids")
            var exact: [Row] = [], possible: [Row] = []
            for entry in testCase.entries {
                let candidate = SiteCandidate(id: UUID(), urls: entry.urls)
                let match = SiteMatcher.interactiveMatches([candidate], for: [.url(testCase.origin)])
                if !match.exact.isEmpty { exact.append(Row(entry: entry.id, exact: true)) }
                else if !match.possible.isEmpty { possible.append(Row(entry: entry.id, exact: false)) }
            }
            XCTAssertEqual(exact + possible, testCase.expected, testCase.name)
        }
    }

    struct Row: Decodable, Equatable, CustomStringConvertible {
        let entry: String
        let exact: Bool
        var description: String { "\(entry):\(exact ? "exact" : "possible")" }
    }

    private struct Fixture: Decodable {
        struct Entry: Decodable {
            let id: String
            let urls: [String]
        }
        struct Case: Decodable {
            let name: String
            let origin: String
            let entries: [Entry]
            let expected: [Row]
        }
        let version: Int
        let cases: [Case]
    }

    /// Read from the repository, outside the package: the file is shared with
    /// the app tests and the extension, so it cannot be a package resource.
    private static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../TestFixtures/browser-bridge/site-matching.json").standardizedFileURL
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
