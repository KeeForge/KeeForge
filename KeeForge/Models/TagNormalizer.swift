import Foundation

/// The single implementation of KeeForge's tag identity policy: a tag is a
/// trimmed, non-empty string that contains no separator character; identity is
/// exact-string, so `Work` and `work` stay two tags; per-item lists drop
/// duplicates keeping the first occurrence.
///
/// This normalizes edit-side input and derived lists only. Parsed data is never
/// rewritten — `KPEntry.tags` keeps the order and spelling of the source file
/// until the user edits the entry.
enum TagNormalizer {
    /// Canonical tags parsed out of free-form text, such as the entry editor's
    /// tag field or a stored `<Tags>` value.
    static func tags(fromText text: String) -> [String] {
        tags(from: [text])
    }

    /// Canonical tags for an already-split list, re-splitting each element so a
    /// programmatically-built list containing a separator cannot smuggle one
    /// into a stored tag. Callers that combine several lists (an entry's own
    /// tags plus its ancestors') get first-occurrence dedupe across all of them.
    static func tags(from values: [String]) -> [String] {
        var seen = Set<String>()
        var canonical: [String] = []
        canonical.reserveCapacity(values.count)

        for value in values {
            for component in value.split(whereSeparator: { isSeparator($0) }) {
                let tag = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
                guard tag.isEmpty == false, seen.insert(tag).inserted else { continue }
                canonical.append(tag)
            }
        }

        return canonical
    }

    /// KeePass reads `,` and `;`; newlines separate too, because KeeForge's tag
    /// field is multi-line. `isNewline` rather than a `"\n"`/`"\r"` comparison
    /// because Swift stores a pasted CRLF as one `Character`.
    private static func isSeparator(_ character: Character) -> Bool {
        character == "," || character == ";" || character.isNewline
    }
}
