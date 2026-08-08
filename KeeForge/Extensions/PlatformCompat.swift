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
    /// `searchFocused(_:)` is macOS 15+. On macOS 14 this is a no-op: the
    /// menu-bar Find command cannot programmatically focus the search field
    /// there, but search itself still works.
    @ViewBuilder
    func macSearchFocusedCompat(_ isFocused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(isFocused)
        } else {
            self
        }
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
