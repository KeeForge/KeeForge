import SwiftUI

/// The capsule label shared by the iOS entry detail's chips, the history
/// viewer and the editors' tag strips, so a tag looks the same wherever it is
/// tappable. `systemImage` is nil on the detail, where a chip navigates to the
/// tag, and `plus` in the editor, where it adds the tag to the field.
struct TagCapsule: View {
    let tag: String
    var systemImage: String? = nil
    /// Drawn after the name instead of before it. The editor's removable pills
    /// use it so the affordance reads as "tag, then remove" rather than
    /// "action, then tag" the way the leading `plus` suggestions do.
    var trailingSystemImage: String? = nil
    /// Outlines the capsule instead of filling it, for a chip that is not the
    /// entry's own to change: the iOS detail's inherited group tags.
    var isOutlined: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }

            Text(tag)
                .lineLimit(1)
                .truncationMode(.tail)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if isOutlined {
                Capsule().strokeBorder(.tertiary)
            } else if PlatformDesign.followsIOSDesign {
                Capsule().fill(Theme.accentSoft)
            } else {
                Capsule().fill(.fill)
            }
        }
    }

    private var foreground: AnyShapeStyle {
        if isOutlined {
            return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
        return PlatformDesign.followsIOSDesign ? AnyShapeStyle(.tint) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            // The measured size, not `.unspecified`: a subview clamped to the
            // row width has to be handed that width to render its truncation.
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    /// A subview wider than the row is clamped to the row rather than allowed
    /// to overhang: wrapping cannot save it (it is alone on its line), so
    /// without the clamp it reports a width past the proposal and drags the
    /// whole container — in a `Form`, the enclosing row and its label — wider
    /// than the layout it sits in. A long tag is the realistic case.
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            // `currentX` carries the trailing spacing for the next subview;
            // the row's own right edge is that spacing back.
            maxX = max(maxX, currentX - spacing)
        }

        return (offsets, sizes, CGSize(width: maxX, height: currentY + rowHeight))
    }
}
