import SwiftUI

/// The KeeForge iOS design tokens. Colors live in `Theme.xcassets` with light
/// and dark values; views name a token here instead of a literal.
enum Theme {
    // MARK: Color

    /// The default accent. The app's root applies the user's own accent pick
    /// over it as the tint, so views tint with `.tint`, not this.
    static let accent = Color("AccentColor")
    static let labelSecondary = Color("LabelSecondary")
    static let card = Color("Card")
    static let card2 = Color("Card2")
    static let fill = Color("Fill")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
    static let dangerSoft = Color("DangerSoft")
    static let tileCodes = Color("TileCodes")
    static let tileTags = Color("TileTags")
    static let tileTrash = Color("TileTrash")
    static let digit = Color("Digit")
    static let symbol = Color("Symbol")

    static let accentSoft = AccentSoftStyle()

    // MARK: Spacing

    enum Spacing {
        static let side: CGFloat = 16
        static let tileGap: CGFloat = 10
        static let cardGap: CGFloat = 12
        static let section: CGFloat = 20
        static let iconText: CGFloat = 12
    }

    // MARK: Radius

    enum Radius {
        static let card: CGFloat = 20
        static let field: CGFloat = 12
        static let entryIcon: CGFloat = 10
    }

    // MARK: Size

    enum Size {
        static let rowValue: CGFloat = 52
        static let rowSummary: CGFloat = 58
        static let tile: CGFloat = 92
        static let tileCircle: CGFloat = 32
        static let entryIcon: CGFloat = 40
        static let badge: CGFloat = 22
        static let meterSegment = CGSize(width: 16, height: 4)
    }

    // MARK: Type

    /// The design's type styles mapped onto Dynamic Type text styles.
    enum Font {
        static let entryTitle = SwiftUI.Font.title.bold()
        static let rowTitle = SwiftUI.Font.headline
        static let subhead = SwiftUI.Font.subheadline
        static let footnote = SwiftUI.Font.footnote
        static let caption = SwiftUI.Font.caption
        static let badge = SwiftUI.Font.caption2.weight(.bold)
        static let tileCount = SwiftUI.Font.title3.monospacedDigit()
        static let codeLarge = SwiftUI.Font.title.monospaced().weight(.semibold)
        static let codeRow = SwiftUI.Font.title3.monospaced().weight(.semibold)
        static let password = SwiftUI.Font.title2.monospaced().weight(.medium)
    }
}

/// `accent-soft`, drawn from the current tint so chips follow a user-picked
/// accent. With the default accent these opacities give the token's values.
struct AccentSoftStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        TintShapeStyle().opacity(environment.colorScheme == .dark ? 0.27 : 0.12)
    }
}
