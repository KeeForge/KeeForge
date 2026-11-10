import XCTest
@testable import SiteMatching

/// The Public Suffix List project's own `checkPublicSuffix` vectors
/// (`Fixtures/test_psl.txt`): the registrable domain of each input host.
final class PublicSuffixListVectorTests: XCTestCase {
    /// Inputs where this package's answer differs from the list's, with why.
    private static let knownDivergences: [String: String] = [
        ".example.com": "A leading empty label is ignored rather than rejected.",
        ".example.example": "A leading empty label is ignored rather than rejected.",
    ]

    func testRegistrableDomainsMatchTheListsVectors() throws {
        let vectors = try Self.vectors()
        XCTAssertEqual(vectors.count, 77, "test_psl.txt changed; review the divergence list")

        for vector in vectors {
            // Hosts reach the list lowercased and punycoded, as `SiteHost`
            // parses them. The file repeats its IDN cases punycoded, so the
            // conversion is checked against the list's own spelling too.
            let host = SiteHost.parse(vector.input)
            let expected = vector.expected.map { SiteHost.parse($0) ?? $0 }
            let guarded = host.flatMap(SiteHost.registrableDomain(of:))
            let unguarded = host.flatMap(SiteHost.suffixListDomain(of:))

            if Self.knownDivergences[vector.input] != nil {
                XCTAssertNotEqual(guarded, expected, "\(vector.input) now agrees; drop it from knownDivergences")
                continue
            }
            XCTAssertEqual(guarded, expected, vector.input)
            XCTAssertEqual(unguarded, expected, vector.input)
        }
    }

    // MARK: - Fixture

    private struct Vector {
        let input: String
        let expected: String?
    }

    /// Reads `checkPublicSuffix('input', 'expected' | null);` lines, skipping
    /// comments and the null-input case, which has no Swift equivalent.
    private static func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test_psl", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = /^checkPublicSuffix\((?:'([^']*)'|null), (?:'([^']*)'|null)\);$/
        return text.split(separator: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: pattern), let input = match.1 else { return nil }
            return Vector(input: String(input), expected: match.2.map(String.init))
        }
    }
}
