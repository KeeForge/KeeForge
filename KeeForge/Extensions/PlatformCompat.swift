import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Cross-platform compatibility shim for the macOS port (slice 01).
//
// Prefer adding view-layer compatibility here over scattering raw `#if os()`
// conditionals through Views; raw conditionals remain fine in Services where
// behavior genuinely diverges. Target membership: KeeForge, KeeForgeAutoFill,
// KeeForgeMac.

// MARK: - Platform image

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
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
