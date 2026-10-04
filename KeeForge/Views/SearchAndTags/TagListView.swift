import SwiftUI

/// Per-tag accessibility identifier suffixes. Tag names are arbitrary user text,
/// so they are normalized the same way `EntryEditViewModel` normalizes custom
/// field keys — lowercased, spaces and slashes hyphenated — with an index
/// fallback for tags that normalize to nothing (emoji-only names, for example)
/// so every row still has an identifier.
///
/// Note that case-variant tags (`Work` and `work` are two distinct tags) share
/// one suffix, exactly as two custom fields differing only in case do. A test
/// that needs to tell them apart has to enumerate matches rather than take
/// `firstMatch`.
enum TagAccessibility {
    static func identifierSuffix(for tag: String, fallbackIndex: Int) -> String {
        let normalized = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return normalized.isEmpty ? "\(fallbackIndex)" : normalized
    }
}

/// The rows of the root list's Tags view: every distinct tag in the open
/// database with the number of live entries carrying it.
///
/// Rows are plain `NavigationLink`s: both shells that show this view are
/// `NavigationStack`s (the compact push and the iPad sidebar). macOS browses
/// tags from its own sidebar section in `RegularDatabaseWorkspaceView` instead,
/// so it never renders them.
struct TagListRows: View {
    @Bindable var viewModel: DatabaseViewModel

    private var tags: [String] {
        viewModel.tagsInDisplayOrder
    }

    var body: some View {
        if tags.isEmpty {
            ContentUnavailableView(
                "No Tags",
                systemImage: "tag",
                description: Text("Open an entry, tap Edit, and fill in its Tags field to gather related entries from any group.")
            )
        } else {
            ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                tagRow(for: tag, fallbackIndex: index)
            }
        }
    }

    @ViewBuilder
    private func tagRow(for tag: String, fallbackIndex: Int) -> some View {
        NavigationLink(value: DatabaseRoute.tag(tag)) {
            TagRow(tag: tag, entryCount: viewModel.entryCount(forTag: tag))
        }
        .accessibilityIdentifier(
            "tag-list.row.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
        .macHoverHighlight()
    }
}

/// One tag row: the tag name over its entry count. Tag names are arbitrary user
/// text, so the name truncates instead of wrapping the row's chrome.
struct TagRow: View {
    let tag: String
    let entryCount: Int

    var body: some View {
        HStack {
            Image(systemName: "tag")
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading) {
                Text(tag)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(entryCount) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
