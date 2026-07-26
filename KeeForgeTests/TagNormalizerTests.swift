import XCTest
@testable import KeeForge

final class TagNormalizerTests: XCTestCase {
    func testTagsFromTextSplitsOnEverySeparatorAndTrims() {
        XCTAssertEqual(TagNormalizer.tags(fromText: "a;b"), ["a", "b"])
        XCTAssertEqual(TagNormalizer.tags(fromText: "a, b;c\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(TagNormalizer.tags(fromText: "a\r\nb"), ["a", "b"])
        XCTAssertEqual(TagNormalizer.tags(fromText: "  New York , Work  "), ["New York", "Work"])
    }

    func testTagsFromTextDropsEmptiesForAnyInput() {
        XCTAssertEqual(TagNormalizer.tags(fromText: ""), [])
        XCTAssertEqual(TagNormalizer.tags(fromText: " ; ,, "), [])
        XCTAssertEqual(TagNormalizer.tags(fromText: ",,,"), [])
        XCTAssertEqual(TagNormalizer.tags(fromText: "\n \t "), [])
        XCTAssertEqual(TagNormalizer.tags(fromText: ",lead,trail,"), ["lead", "trail"])
    }

    func testTagIdentityIsExactStringWithFirstOccurrenceDedupe() {
        XCTAssertEqual(TagNormalizer.tags(fromText: "a,a"), ["a"])
        XCTAssertEqual(TagNormalizer.tags(fromText: "Work,work"), ["Work", "work"])
        XCTAssertEqual(
            TagNormalizer.tags(fromText: "b, a, b, c, a"),
            ["b", "a", "c"],
            "Duplicates collapse onto their first occurrence, leaving the order untouched"
        )
    }

    func testTagsFromListDedupesAcrossElementsAndSplitsEmbeddedSeparators() {
        XCTAssertEqual(TagNormalizer.tags(from: ["a", "b", "a"]), ["a", "b"])
        XCTAssertEqual(
            TagNormalizer.tags(from: ["own", "inherited"]),
            ["own", "inherited"],
            "Combining several lists keeps the caller's order"
        )
        XCTAssertEqual(
            TagNormalizer.tags(from: ["a;b", " c "]),
            ["a", "b", "c"],
            "A separator inside a list element can never survive into a stored tag"
        )
        XCTAssertEqual(TagNormalizer.tags(from: []), [])
    }

    func testNormalizationNeverAltersTagCharacters() {
        XCTAssertEqual(
            TagNormalizer.tags(fromText: "Réunion, 東京, 🎉 party, e-mail/web"),
            ["Réunion", "東京", "🎉 party", "e-mail/web"]
        )
    }
}
