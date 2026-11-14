#if os(macOS)
import XCTest
@testable import KeeForge

final class LargeTypeModelTests: XCTestCase {
    func testTilesAreNumberedFromOneAndClassedLikeThePasswordColouring() {
        let model = LargeTypeModel(title: "GitHub", fieldName: "Password", value: "Vx7$ k")

        XCTAssertEqual(model.title, "GitHub")
        XCTAssertEqual(model.fieldName, "Password")
        XCTAssertEqual(model.characterCount, 6)
        XCTAssertEqual(model.tiles.map(\.position), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(model.tiles.map(\.character), ["V", "x", "7", "$", " ", "k"])
        XCTAssertEqual(model.tiles.map(\.kind), [.letter, .letter, .digit, .symbol, .space, .letter])
    }

    func testAnEmojiOrALetterWithCombiningMarksIsOneTile() {
        let model = LargeTypeModel(title: "", fieldName: "Password", value: "e\u{301}👩‍💻🇯🇵1")

        XCTAssertEqual(model.characterCount, 4)
        XCTAssertEqual(model.tiles.map(\.character), ["e\u{301}", "👩‍💻", "🇯🇵", "1"])
        XCTAssertEqual(model.tiles.map(\.kind), [.letter, .symbol, .symbol, .digit])
    }

    func testAnEmptyValueHasNoTiles() {
        XCTAssertEqual(LargeTypeModel(title: "T", fieldName: "Password", value: "").tiles, [])
    }
}
#endif
