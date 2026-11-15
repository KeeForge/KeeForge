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
    @Environment(\.displayScale) private var displayScale

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
        let fullSide = size * (1 - 2 * Theme.EntryIcon.imageInsetRatio)
        let side = IconBitmapLayout.side(pixelEdge: image.pixelEdge, fullSide: fullSide, scale: displayScale)
        return Image(platformImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
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

/// How large to draw an icon bitmap in a slot. A favicon is often 16 or 32 px; stretched over a
/// detail header's 60-70 pt at 2x or 3x it turns to blur. Up to 3x enlargement it fills the slot as
/// before; past that it is drawn at twice its pixel size, and never under half the slot, centred on
/// the slot's neutral tile.
enum IconBitmapLayout {
    static let fillingUpscale: CGFloat = 3
    static let tiledUpscale: CGFloat = 2
    static let minimumFraction: CGFloat = 0.5

    static func side(pixelEdge: CGFloat, fullSide: CGFloat, scale: CGFloat) -> CGFloat {
        guard pixelEdge > 0, scale > 0, fullSide * scale > pixelEdge * fillingUpscale else { return fullSide }
        return min(fullSide, max(fullSide * minimumFraction, pixelEdge * tiledUpscale / scale))
    }

    /// Whether the bitmap is drawn smaller than the slot and so needs a tile behind it.
    static func isTiled(pixelEdge: CGFloat, fullSide: CGFloat, scale: CGFloat) -> Bool {
        side(pixelEdge: pixelEdge, fullSide: fullSide, scale: scale) < fullSide
    }
}
