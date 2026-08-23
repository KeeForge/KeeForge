import SwiftUI

/// A tag-browser screen reachable by pushing onto a database navigation stack.
///
/// Tags need their own destination type: `UUID` already means "group" and
/// `KPEntry` already means "entry" in both stack shells, and a bare `String`
/// would collide with any future string-valued destination. Both shells
/// register this one type, so a tag pushed from the root Tags row, from the tag
/// list, or from an entry-detail chip all land on the same screens.
enum TagDestination: Hashable {
    /// Every distinct tag in the database, with entry counts.
    case allTags
    /// The entries carrying `tag`, matched exact-string.
    case entries(tag: String)
}

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

/// Every distinct tag in the open database with the number of live entries
/// carrying it, pushed from the root group list's Tags row.
///
/// Rows are plain `NavigationLink`s: both shells that reach this screen are
/// `NavigationStack`s (the compact push and the iPad sidebar). macOS browses
/// tags from its own sidebar section in `RegularDatabaseWorkspaceView` instead,
/// so it never renders this view.
struct TagListView: View {
    @Bindable var viewModel: DatabaseViewModel

    private var tags: [String] {
        viewModel.tagsInDisplayOrder
    }

    var body: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView(
                    "No Tags",
                    systemImage: "tag",
                    description: Text("Open an entry, tap Edit, and fill in its Tags field to gather related entries from any group.")
                )
            } else {
                List {
                    ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                        tagRow(for: tag, fallbackIndex: index)
                    }
                }
                .accessibilityIdentifier("tag-list")
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func tagRow(for tag: String, fallbackIndex: Int) -> some View {
        NavigationLink(value: TagDestination.entries(tag: tag)) {
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
