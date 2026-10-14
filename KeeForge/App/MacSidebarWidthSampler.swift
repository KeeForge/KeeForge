#if os(macOS)
import Foundation

/// Decides which measured sidebar widths are the user's preference. A divider
/// drag moves the sidebar inside a split view of unchanged width; a narrower
/// window compresses it, and that constrained width must not replace the
/// preference restored on the next unlock.
struct MacSidebarWidthSampler {
    static let minimumWidth = 200.0
    static let idealWidth = 240.0
    static let maximumWidth = 340.0

    private var splitWidthAtLastSample: Double?

    /// Returns the width to remember, or nil when this sample is a first
    /// layout, a collapsed column, or follows a change of the split view's width.
    mutating func preferredWidth(sidebarWidth: Double, splitWidth: Double?) -> Double? {
        defer { splitWidthAtLastSample = splitWidth }
        guard sidebarWidth.isFinite, sidebarWidth >= Self.minimumWidth,
              let splitWidth, splitWidth == splitWidthAtLastSample else { return nil }
        return min(sidebarWidth, Self.maximumWidth)
    }
}
#endif
