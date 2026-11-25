import XCTest
@testable import KeeForge

final class AutoFillSearchPerformanceTests: XCTestCase {
    private static let corpus: [KPEntry] = (0..<2_000).map { index in
        KPEntry(
            title: "Service \(index)",
            username: "user\(index)@example.com",
            url: "https://login.service\(index).example.com/signin",
            notes: "Recovery codes are stored in the safe. Account opened in \(2_000 + index % 25).",
            tags: ["work", "team\(index % 10)"],
            customFields: [
                "KP2A_URL_1": "https://app.service\(index).example.net",
                "Security question": "First pet",
            ]
        )
    }

    /// Every prefix of a query typed into the picker, one search per keystroke.
    private static let keystrokes = (1...12).map { String("service 1999".prefix($0)) }

    func testTypingIntoAutoFillSearchOver2000Entries() {
        let index = EntrySearchIndex(entries: Self.corpus)
        measure(metrics: [XCTClockMetric()]) {
            for query in Self.keystrokes {
                _ = AutoFillSearchResults(entries: [], searchIndex: index, possibleEntries: [], query: query, hasExpandedSearch: true)
            }
        }
        let results = AutoFillSearchResults(entries: [], searchIndex: index, possibleEntries: [], query: "Service 1999", hasExpandedSearch: true)
        XCTAssertEqual(results.entries.map(\.title), ["Service 1999"])
    }

    /// Paid once when the picker appears.
    func testIndexing2000Entries() {
        measure(metrics: [XCTClockMetric()]) {
            XCTAssertEqual(EntrySearchIndex(entries: Self.corpus).entries.count, 2_000)
        }
    }

    func testPickerSearchMatchesTheAppSearchFields() {
        let entry = KPEntry(
            title: "Café",
            username: "ana",
            url: "https://primary.example",
            notes: "door code in the Notes",
            tags: ["Finance"],
            customFields: ["KP2A_URL_1": "https://second.example", "Hidden": "secret-word"],
            protectedStringKeys: ["Hidden"]
        )
        let index = EntrySearchIndex(entries: [entry])
        for query in ["cafe", "ANA", "primary.example", "second.example", "door code", "finance", "  café  "] {
            let results = AutoFillSearchResults(entries: [], searchIndex: index, possibleEntries: [], query: query, hasExpandedSearch: true)
            XCTAssertEqual(results.entries.map(\.id), [entry.id], query)
        }
        let hidden = AutoFillSearchResults(entries: [], searchIndex: index, possibleEntries: [], query: "secret-word", hasExpandedSearch: true)
        XCTAssertTrue(hidden.entries.isEmpty, "Other custom fields are not searched")
        let blank = AutoFillSearchResults(entries: [], searchIndex: index, possibleEntries: [], query: "   ", hasExpandedSearch: true)
        XCTAssertEqual(blank.entries.map(\.id), [entry.id], "A blank query lists the whole corpus")
    }
}
