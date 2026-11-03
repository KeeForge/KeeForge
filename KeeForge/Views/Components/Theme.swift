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
    /// Glyphs on the tile circles, which keep their colors in dark mode.
    static let tileGlyph = Color.white

    /// Monogram grounds, picked per title so a list does not read as one block.
    /// Tile hues only: `success`, `warning` and `danger` stay for state.
    static func monogramTint(for title: String) -> Color {
        let tints = [accent, tileTags, tileTrash]
        let index = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[index % tints.count]
    }

    static let accentSoft = AccentSoftStyle()

    /// State colors for views macOS shares: the tokens on iPhone and iPad, the
    /// system colors the Mac app has always used.
    enum State {
        static var success: Color { PlatformDesign.followsIOSDesign ? Theme.success : .green }
        static var warning: Color { PlatformDesign.followsIOSDesign ? Theme.warning : .orange }
        static var danger: Color { PlatformDesign.followsIOSDesign ? Theme.danger : .red }
        static var dangerSoft: Color { PlatformDesign.followsIOSDesign ? Theme.dangerSoft : .red.opacity(0.12) }
        /// The cloud sync warning glyph, yellow on macOS.
        static var cloudWarning: Color { PlatformDesign.followsIOSDesign ? Theme.warning : .yellow }
    }

    // MARK: Spacing

    enum Spacing {
        static let side: CGFloat = 16
        static let tileGap: CGFloat = 10
        static let cardGap: CGFloat = 12
        static let iconText: CGFloat = 12
        static let badge = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        /// Between the stacked lines of one row: title, username, path.
        static let textLine: CGFloat = 2
        static let badgeGap: CGFloat = 6
        static let meterSegment: CGFloat = 3
        static let tile = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    }

    // MARK: Radius

    enum Radius {
        static let card: CGFloat = 20
        static let entryIcon: CGFloat = 10
    }

    /// Proportions of an entry icon, relative to its side.
    enum EntryIcon {
        static let cornerRatio: CGFloat = 0.25
        static let glyphRatio: CGFloat = 0.55
        static let monogramRatio: CGFloat = 0.38
        static let imageInsetRatio: CGFloat = 0.15
        static let monogramShade = 0.25
    }

    // MARK: Size

    enum Size {
        static let tile: CGFloat = 92
        static let tileCircle: CGFloat = 32
        static let entryIcon: CGFloat = 40
        static let entryHeaderIcon: CGFloat = 64
        static let badge: CGFloat = 22
        static let statusDot: CGFloat = 8
        static let navButton: CGFloat = 44
        static let failureBadge: CGFloat = 56
        static let meterSegment = CGSize(width: 16, height: 4)
    }

    // MARK: Type

    /// The design's type styles mapped onto Dynamic Type text styles.
    enum Font {
        static let entryTitle = SwiftUI.Font.title.bold()
        static let rowTitle = SwiftUI.Font.headline
        static let subhead = SwiftUI.Font.subheadline
        static let footnote = SwiftUI.Font.footnote
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
