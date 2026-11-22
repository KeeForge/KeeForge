import Foundation

/// The entry search shared by the app and the AutoFill pickers: each entry's
/// title, user name, URLs, notes, and tags are folded into one string up
/// front, so a keystroke is a single substring scan per entry.
struct EntrySearchIndex: Sendable {
    private(set) var entries: [KPEntry] = []
    private var haystacks: [String] = []

    init() {}

    /// Indexes each entry with its own tags.
    init(entries: [KPEntry]) {
        self.entries.reserveCapacity(entries.count)
        haystacks.reserveCapacity(entries.count)
        for entry in entries {
            append(entry, tags: entry.tags)
        }
    }

    /// `tags` are the entry's effective tags, including any its groups give it.
    mutating func append(_ entry: KPEntry, tags: [String]) {
        entries.append(entry)
        haystacks.append(Self.fold(([entry.title, entry.username, entry.url, entry.notes] + entry.additionalURLs + tags).joined(separator: "\n")))
    }

    /// Entries whose text contains the trimmed query, ignoring case and
    /// diacritics, in index order. Empty for a blank query.
    func entries(matching rawQuery: String) -> [KPEntry] {
        guard let query = Self.normalizedQuery(rawQuery) else { return [] }
        return zip(entries, haystacks).compactMap { entry, haystack in
            haystack.contains(query) ? entry : nil
        }
    }

    /// The folded query, or nil when it is blank.
    private static func normalizedQuery(_ rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : fold(trimmed)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
}
