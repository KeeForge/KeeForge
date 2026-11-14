import AppKit
import SwiftUI

/// Icon images for the sidebar and entry list cells: standard icons keep
/// `StandardIconView`'s palette, white on a selected row.
@MainActor
enum MacIconImages {
    static func standard(
        _ iconID: Int,
        fallbackSymbol: String,
        fallbackPalette: StandardIconView.Palette,
        pointSize: CGFloat,
        emphasized: Bool
    ) -> NSImage? {
        let palette = StandardIconView.palette(for: iconID, fallback: fallbackPalette).colors
        let colors: [NSColor] = emphasized
            ? [.white, NSColor.white.withAlphaComponent(0.82)]
            : [NSColor(palette.primary), NSColor(palette.secondary)]
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        return NSImage(systemSymbolName: KPEntry.systemIconName(for: iconID, fallback: fallbackSymbol),
                       accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    /// Nil when the data does not decode, so the caller falls back to the standard icon.
    static func custom(_ data: Data, size: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }
}
