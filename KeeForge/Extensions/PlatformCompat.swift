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

// MARK: - Search focus (macOS 15 availability shim)

#if os(macOS)
extension View {
    /// `searchFocused(_:)` is macOS 15+, and this app's floor is macOS 14, so
    /// below 15 the focus request is serviced through AppKit instead — SwiftUI
    /// offers no other route to the `.searchable` field there.
    @MainActor
    @ViewBuilder
    func macSearchFocusedCompat(_ isFocused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(isFocused)
        } else {
            onChange(of: isFocused.wrappedValue) { _, isRequested in
                guard isRequested else { return }
                // Nothing binds this `FocusState` on the AppKit path, so clear
                // it back down: the next request has to read as a fresh change.
                isFocused.wrappedValue = false
                MacSearchFieldFocus.focusSearchField()
            }
        }
    }
}

/// Makes the `.searchable` field first responder on macOS 14. Quietly does
/// nothing when the window has no search field.
@MainActor
private enum MacSearchFieldFocus {
    static func focusSearchField() {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }

        // SwiftUI hosts `.searchable` in an `NSSearchToolbarItem`, whose
        // `beginSearchInteraction()` also expands a collapsed field.
        if let searchItem = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            searchItem.beginSearchInteraction()
            return
        }

        guard let contentView = window.contentView,
              let searchField = firstSearchField(in: contentView) else { return }
        window.makeFirstResponder(searchField)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        for subview in view.subviews {
            if let match = firstSearchField(in: subview) { return match }
        }
        return nil
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

// MARK: - Sheet sizing (macOS)

extension View {
    /// Gives a sheet a usable size on macOS.
    ///
    /// `.presentationDetents` compiles on macOS but does nothing there, so a
    /// sheet that relies on detents alone sizes itself to its content — a grid
    /// or a short form then opens comically small. Apply this alongside the
    /// detents; it is inert on iOS, where the detents are what matter.
    ///
    /// The defaults match the 540x560 convention already used for the editor
    /// and settings sheets. Pass a wider `minWidth` for grid content.
    @ViewBuilder
    func macSheetFrame(minWidth: CGFloat = 540, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
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
