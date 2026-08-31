import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Prefer adding view-layer compatibility here over scattering raw `#if os()`
// conditionals through Views; raw conditionals remain fine in Services where
// behavior genuinely diverges.

// MARK: - Platform image

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

// MARK: - Text content type

// SwiftUI's `textContentType(_:)` takes the platform's own type; naming it lets
// call sites store one in a property.

#if canImport(UIKit)
typealias PlatformTextContentType = UITextContentType
#elseif canImport(AppKit)
typealias PlatformTextContentType = NSTextContentType
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

#if os(macOS)

// MARK: - Semantic colors
// Lets iOS call sites like `Color(.systemBackground)` compile unchanged by
// giving NSColor the UIKit semantic names, mapped to their closest AppKit
// equivalents.

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .underPageBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var separator: NSColor { .separatorColor }
    static var placeholderText: NSColor { .placeholderTextColor }
}

// MARK: - Navigation bar title display mode (no-op on macOS)

enum PlatformTitleDisplayModeCompat {
    case automatic
    case inline
    case large
}

extension View {
    /// macOS has no navigation-bar title display mode; iOS call sites compile
    /// unchanged and the modifier is a no-op here.
    func navigationBarTitleDisplayMode(_ mode: PlatformTitleDisplayModeCompat) -> some View {
        self
    }
}

// MARK: - Toolbar placement

extension ToolbarItemPlacement {
    /// `.topBarLeading` does not exist on macOS; `.navigation` is the closest
    /// leading-edge placement.
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    /// `.topBarTrailing` does not exist on macOS; `.primaryAction` is the
    /// closest trailing-edge placement.
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}

// MARK: - List style

extension ListStyle where Self == InsetListStyle {
    /// `.insetGrouped` does not exist on macOS; `.inset` is the closest match.
    static var insetGrouped: InsetListStyle { .inset }
}

// MARK: - Search field placement

enum PlatformSearchBarDisplayModeCompat {
    case automatic
    case always
}

extension SearchFieldPlacement {
    /// `.navigationBarDrawer` does not exist on macOS; `.automatic` places the
    /// search field in the toolbar.
    static func navigationBarDrawer(displayMode: PlatformSearchBarDisplayModeCompat) -> SearchFieldPlacement {
        .automatic
    }
}

// MARK: - Text input (no-ops on macOS)

enum PlatformKeyboardTypeCompat {
    case URL
    case emailAddress
    case numberPad
}

enum PlatformAutocapitalizationCompat {
    case never
    case words
    case sentences
    case characters
}

extension View {
    /// Software keyboard type is an iOS concept; no-op on macOS.
    func keyboardType(_ type: PlatformKeyboardTypeCompat) -> some View {
        self
    }

    /// Autocapitalization control is an iOS concept; no-op on macOS.
    func textInputAutocapitalization(_ autocapitalization: PlatformAutocapitalizationCompat?) -> some View {
        self
    }
}

#endif

// MARK: - Hover highlight (macOS pointer affordance)

#if os(macOS)
private struct MacHoverHighlightModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct MacSelectableRowHoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
#endif

extension View {
    /// Subtle hover highlight for clickable list rows on macOS; no-op on iOS.
    @ViewBuilder
    func macHoverHighlight() -> some View {
        #if os(macOS)
        modifier(MacHoverHighlightModifier())
        #else
        self
        #endif
    }

    /// Hover highlight for a row inside a `List(selection:)` on macOS; no-op on
    /// iOS.
    ///
    /// Separate from `macHoverHighlight()` because that one tints through
    /// `listRowBackground`, which is also what such a list paints its selection
    /// with — a selected row would lose its highlight. This draws behind the
    /// row's own content instead, where the two can coexist.
    @ViewBuilder
    func macSelectableRowHover() -> some View {
        #if os(macOS)
        modifier(MacSelectableRowHoverModifier())
        #else
        self
        #endif
    }

    /// Gives a `Form` the grouped, inset look on macOS; no-op on iOS.
    ///
    /// macOS defaults a `Form` to the `.columns` style: labels in a
    /// right-aligned column and rows running edge to edge, with none of the
    /// insets or grouped backgrounds a sheet needs. The Settings tabs already
    /// opt into `.grouped`; sheeted editors need the same so they match.
    @ViewBuilder
    func macGroupedForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// Gives text fields a visible bezel on macOS; no-op on iOS.
    ///
    /// Inside a grouped `Form` macOS draws `TextField`s borderless, so a row
    /// reads as a caption over empty space with nothing showing where to type.
    /// iOS list rows are borderless by convention and must stay that way.
    @ViewBuilder
    func macFormFieldStyle() -> some View {
        #if os(macOS)
        textFieldStyle(.roundedBorder)
        #else
        self
        #endif
    }

    /// Hides a control's built-in label on macOS; no-op on iOS.
    ///
    /// A `Form` row that captions its own field is the common cross-platform
    /// shape: iOS treats a `TextField`'s title as placeholder text and drops it
    /// once there is a value, while macOS renders it as a second, right-aligned
    /// label beside the caption — and reserves a label column that pushes the
    /// field off the row. Applying `.labelsHidden()` unconditionally would cost
    /// iOS its placeholder, so it stays platform-scoped.
    @ViewBuilder
    func macLabelsHidden() -> some View {
        #if os(macOS)
        labelsHidden()
        #else
        self
        #endif
    }
}

// MARK: - Tooltips (macOS)

extension View {
    /// Hover tooltip for an icon-only control on macOS; no-op on iOS.
    ///
    /// Deliberately not plain `.help()`: on iOS that becomes the VoiceOver
    /// hint, so applying it alongside the existing `accessibilityLabel`s would
    /// change what iOS reads out. Pass the same text the label already uses.
    @ViewBuilder
    func macHelp(_ text: String) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }
}

// MARK: - Row buttons (macOS)

extension View {
    /// Renders a whole-row `Button` as plain content on macOS; no-op on iOS.
    ///
    /// A `Button` whose label fills a row draws as a bordered control inside a
    /// grouped `Form` on macOS — a gray slab sitting inside the section's own
    /// gray card. Plain keeps the row reading as a row, the way it does on iOS.
    @ViewBuilder
    func macPlainRowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}

// MARK: - Sheet sizing (macOS)

#if os(macOS)
enum MacSheetMetrics {
    /// The tallest a sheet may become.
    ///
    /// Without a ceiling a sheet grows to its content's full height, and a
    /// scrolling form is taller than any window. AppKit then clamps the sheet
    /// to the parent window's *frame* height while still anchoring it below the
    /// *toolbar*, so the sheet hangs past the bottom of the window by the
    /// difference between the two — a visible overhang, not a clipped sheet.
    /// Capping the height here keeps the form scrolling inside a sheet that
    /// fits, which is also what a fixed-size AppKit sheet does.
    ///
    /// Sized to fit the window's minimum height (`KeeForgeApp`) with the
    /// toolbar above it; raising one means raising the other.
    static let maxHeight: CGFloat = 560
}
#endif

extension View {
    /// Gives a sheet a usable size on macOS.
    ///
    /// `.presentationDetents` compiles on macOS but does nothing there, so a
    /// sheet that relies on detents alone sizes itself to its content — a grid
    /// or a short form then opens comically small, and a long form opens taller
    /// than the window (`MacSheetMetrics.maxHeight`). Apply this alongside the
    /// detents; it is inert on iOS, where the detents are what matter.
    ///
    /// The default `minWidth` matches the 540pt convention already used for the
    /// editor and settings sheets; pass a wider one for grid content.
    /// `minHeight` must stay at or below `MacSheetMetrics.maxHeight`.
    @ViewBuilder
    func macSheetFrame(minWidth: CGFloat = 540, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight, maxHeight: MacSheetMetrics.maxHeight)
        #else
        self
        #endif
    }
}

// MARK: - File protection

extension Data.WritingOptions {
    /// Atomic write with the strongest available at-rest protection.
    ///
    /// On iOS this applies `.completeFileProtection` (Data Protection class A).
    /// On macOS there is no per-file Data Protection: setting a protection
    /// class fails with EPERM (verified on macOS 26), so the option is omitted
    /// and at-rest encryption is provided by FileVault instead.
    static var atomicProtected: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}
