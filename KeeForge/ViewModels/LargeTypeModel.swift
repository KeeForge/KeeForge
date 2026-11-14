#if os(macOS)
import Foundation

/// What the Mac Large Type panel shows: one numbered tile per character, classed like the
/// password colouring. Build it only inside a disclosure's `disclose` closure; the panel holds it
/// only while open.
struct LargeTypeModel: Equatable {
    enum Kind: Equatable {
        case letter
        case digit
        case symbol
        case space
    }

    struct Tile: Identifiable, Equatable {
        /// 1-based position, as the tile's caption shows it.
        let position: Int
        /// One user-perceived character: an emoji or a letter with combining marks is one tile.
        let character: String
        let kind: Kind
        var id: Int { position }
    }

    let title: String
    let fieldName: String
    let tiles: [Tile]

    var characterCount: Int { tiles.count }

    init(title: String, fieldName: String, value: String) {
        self.title = title
        self.fieldName = fieldName
        tiles = value.enumerated().map { offset, character in
            Tile(position: offset + 1, character: String(character), kind: Self.kind(of: character))
        }
    }

    /// Letters, digits and everything else as `PasswordDisplayText` colours them; whitespace gets its own class.
    static func kind(of character: Character) -> Kind {
        if character.isLetter { return .letter }
        if character.isNumber { return .digit }
        if character.isWhitespace { return .space }
        return .symbol
    }
}
#endif
