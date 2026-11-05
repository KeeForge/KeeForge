import XCTest
@testable import KeeForge

final class EntryIconViewTests: XCTestCase {
    func testMonogramTakesTheInitialsOfTheFirstTwoWords() {
        XCTAssertEqual(EntryIconView.monogram(for: "Alpha Login"), "AL")
        XCTAssertEqual(EntryIconView.monogram(for: "bank of example"), "BO")
        XCTAssertEqual(EntryIconView.monogram(for: "Mail - Work"), "MW")
    }

    func testMonogramOfOneWordAddsItsNextCapital() {
        XCTAssertEqual(EntryIconView.monogram(for: "GitHub"), "GH")
        XCTAssertEqual(EntryIconView.monogram(for: "Router"), "R")
        XCTAssertEqual(EntryIconView.monogram(for: "router"), "R")
    }

    func testMonogramSkipsLeadingSymbolsAndHandlesAnEmptyTitle() {
        XCTAssertEqual(EntryIconView.monogram(for: "(untitled)"), "U")
        XCTAssertEqual(EntryIconView.monogram(for: "  #2 Backup"), "2B")
        XCTAssertEqual(EntryIconView.monogram(for: ""), "?")
        XCTAssertEqual(EntryIconView.monogram(for: "🔑"), "?")
    }
}
