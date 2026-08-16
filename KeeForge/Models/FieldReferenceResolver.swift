import CryptoKit
import Foundation

/// Resolves KeePass field references — `{REF:<Wanted>@<SearchIn>:<Text>}` —
/// against a snapshot of the entry tree, for display, copy, and AutoFill only.
///
/// Wanted and SearchIn codes: `T` title, `U` username, `P` password, `A` URL,
/// `N` notes, `I` UUID; SearchIn additionally accepts `O` (any custom field).
/// `@I` matches the 32-hex UUID exactly; the other SearchIn codes match a
/// case-insensitive substring, first hit in tree order. References that do not
/// resolve — unknown codes, no match, undecryptable password — stay literal,
/// as KeePass does. Never run this on an edit or save path: a resolved value
/// written back would replace the reference with the value it pointed at.
struct FieldReferenceResolver: Sendable {
    static let maxDepth = 10

    private static let marker = "{REF:"

    private let entries: [KPEntry]
    private let entriesByID: [UUID: KPEntry]
    private let sessionKey: SymmetricKey?

    init(entries: [KPEntry], sessionKey: SymmetricKey?) {
        self.entries = entries
        self.entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.sessionKey = sessionKey
    }

    static func resolve(_ value: String, in rootGroup: KPGroup?, sessionKey: SymmetricKey?) -> String {
        guard Self.containsReference(value) else { return value }
        return FieldReferenceResolver(entries: rootGroup?.allEntries ?? [], sessionKey: sessionKey).resolve(value)
    }

    static func containsReference(_ value: String) -> Bool {
        value.range(of: marker, options: .caseInsensitive) != nil
    }

    func resolve(_ value: String) -> String {
        var current = value
        for _ in 0..<Self.maxDepth {
            guard Self.containsReference(current) else { return current }
            let (next, substituted) = substituteReferences(in: current)
            guard substituted else { return current }
            current = next
        }
        return current
    }

    // MARK: - Substitution

    private func substituteReferences(in value: String) -> (String, Bool) {
        var output = ""
        var substituted = false
        var cursor = value.startIndex

        while let markerRange = value.range(of: Self.marker, options: .caseInsensitive, range: cursor..<value.endIndex) {
            output += value[cursor..<markerRange.lowerBound]
            guard let closing = value[markerRange.upperBound...].firstIndex(of: "}") else {
                output += value[markerRange.lowerBound...]
                return (output, substituted)
            }
            let spec = value[markerRange.upperBound..<closing]
            if let resolved = resolveReference(spec) {
                output += resolved
                substituted = true
            } else {
                output += value[markerRange.lowerBound...closing]
            }
            cursor = value.index(after: closing)
        }
        output += value[cursor...]
        return (output, substituted)
    }

    /// `spec` is the text between `{REF:` and `}`: `W@S:Text`.
    private func resolveReference(_ spec: Substring) -> String? {
        var header = spec.makeIterator()
        guard let wantedCode = header.next(), let wanted = FieldCode(wantedCode), wanted != .customFields,
              header.next() == "@",
              let searchCode = header.next(), let searchIn = FieldCode(searchCode),
              header.next() == ":"
        else { return nil }
        let text = String(spec.dropFirst(4))
        guard text.isEmpty == false, let entry = findEntry(searchIn: searchIn, text: text) else { return nil }
        return value(of: wanted, in: entry)
    }

    private func findEntry(searchIn: FieldCode, text: String) -> KPEntry? {
        if searchIn == .uuid {
            guard let id = UUID(kdbxHexString: text) else { return nil }
            return entriesByID[id]
        }
        return entries.first { entry in
            candidateValues(of: searchIn, in: entry).contains { $0.range(of: text, options: .caseInsensitive) != nil }
        }
    }

    private func candidateValues(of code: FieldCode, in entry: KPEntry) -> [String] {
        switch code {
        case .title: return [entry.title]
        case .username: return [entry.username]
        case .url: return [entry.url]
        case .notes: return [entry.notes]
        case .customFields: return Array(entry.customFields.values)
        case .password: return decryptedPassword(of: entry).map { [$0] } ?? []
        case .uuid: return []
        }
    }

    private func value(of code: FieldCode, in entry: KPEntry) -> String? {
        switch code {
        case .title: return entry.title
        case .username: return entry.username
        case .url: return entry.url
        case .notes: return entry.notes
        case .uuid: return entry.id.kdbxHexString
        case .password: return decryptedPassword(of: entry)
        case .customFields: return nil
        }
    }

    private func decryptedPassword(of entry: KPEntry) -> String? {
        guard entry.hasPassword else { return "" }
        guard let sessionKey else { return nil }
        return try? entry.password.decrypt(using: sessionKey)
    }

    private enum FieldCode {
        case title, username, password, url, notes, uuid, customFields

        init?(_ character: Character) {
            switch character.uppercased() {
            case "T": self = .title
            case "U": self = .username
            case "P": self = .password
            case "A": self = .url
            case "N": self = .notes
            case "I": self = .uuid
            case "O": self = .customFields
            default: return nil
            }
        }
    }
}
