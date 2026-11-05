import SwiftUI

/// An entry's icon in the iPhone and iPad lists, the detail header and the
/// AutoFill picker: the custom icon or a favicon, else the chosen standard
/// icon in a rounded well. The default key icon gives way to a monogram of
/// the title. Loads nothing itself, so AutoFill can use it; the app passes a
/// downloaded favicon through `FaviconEntryIconView`.
struct EntryIconView: View {
    let entry: KPEntry
    var customIconData: Data? = nil
    var favicon: PlatformImage? = nil
    var size: CGFloat = Theme.Size.entryIcon

    /// KeePass's key, the icon an entry gets when nobody picked one.
    private static let keePassDefaultIconID = 0

    private var customIcon: PlatformImage? {
        customIconData.flatMap { PlatformImage(data: $0) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * Theme.EntryIcon.cornerRatio, style: .continuous)
    }

    var body: some View {
        Group {
            if let customIcon {
                image(customIcon)
            } else if let favicon {
                image(favicon)
                    .transition(.opacity)
            } else if entry.iconID == Self.keePassDefaultIconID {
                monogram
            } else {
                StandardIconView(iconID: entry.iconID)
                    .font(.system(size: size * Theme.EntryIcon.glyphRatio))
                    .frame(width: size, height: size)
                    .background(Theme.card2, in: shape)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func image(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(size * Theme.EntryIcon.imageInsetRatio)
            .frame(width: size, height: size)
            .background(Theme.card2, in: shape)
    }

    private var monogram: some View {
        let tint = Theme.monogramTint(for: entry.title)
        return Text(Self.monogram(for: entry.title))
            .font(.system(size: size * Theme.EntryIcon.monogramRatio, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.tileGlyph)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint, tint.mix(with: .black, by: Theme.EntryIcon.monogramShade)], startPoint: .top, endPoint: .bottom),
                in: shape
            )
    }

    /// Up to two letters: the initials of the first two words, or for one
    /// word its first letter and the next capital ("GitHub" gives "GH").
    static func monogram(for title: String) -> String {
        let words = title
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        guard let first = words.first?.first else { return "?" }
        let second: Character?
        if words.count >= 2 {
            second = words[1].first
        } else {
            second = words[0].dropFirst().first(where: \.isUppercase)
        }
        return (String(first) + (second.map(String.init) ?? "")).uppercased()
    }
}
