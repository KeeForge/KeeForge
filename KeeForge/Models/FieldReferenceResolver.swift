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
///
/// A reference that reads or matches a protected value (a password, or a
/// string field the entry marks protected) resolves only with
/// `.protectedValues` clearance, which callers claim after the device-owner
/// gate or inside AutoFill's own authentication. Without it nothing protected
/// is decrypted or read and the whole value comes back `.needsProtectedValue`.
struct FieldReferenceResolver: Sendable {
    enum Clearance: Sendable {
        case unprotectedValues
        case protectedValues
    }

    enum Resolution: Equatable, Sendable {
        case resolved(String)
        case needsProtectedValue

        var value: String? {
            if case .resolved(let value) = self { return value }
            return nil
        }
    }

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

    static func resolve(
        _ value: String,
        in rootGroup: KPGroup?,
        sessionKey: SymmetricKey?,
        clearance: Clearance = .unprotectedValues
    ) -> Resolution {
        guard Self.containsReference(value) else { return .resolved(value) }
        return FieldReferenceResolver(entries: rootGroup?.allEntries ?? [], sessionKey: sessionKey)
            .resolve(value, clearance: clearance)
    }

    static func containsReference(_ value: String) -> Bool {
        value.range(of: marker, options: .caseInsensitive) != nil
    }

    func resolve(_ value: String, clearance: Clearance = .unprotectedValues) -> Resolution {
        var current = value
        for _ in 0..<Self.maxDepth {
            guard Self.containsReference(current) else { return .resolved(current) }
            guard let (next, substituted) = substituteReferences(in: current, clearance: clearance) else {
                return .needsProtectedValue
            }
            guard substituted else { return .resolved(current) }
            current = next
        }
        return .resolved(current)
    }

    // MARK: - Substitution

    private enum Lookup {
        case value(String)
        case unresolved
        case protected
    }

    /// Nil when a reference needs a protected value `clearance` does not cover.
    private func substituteReferences(in value: String, clearance: Clearance) -> (String, Bool)? {
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
            switch resolveReference(spec, clearance: clearance) {
            case .value(let resolved):
                output += resolved
                substituted = true
            case .unresolved:
                output += value[markerRange.lowerBound...closing]
            case .protected:
                return nil
            }
            cursor = value.index(after: closing)
        }
        output += value[cursor...]
        return (output, substituted)
    }

    /// `spec` is the text between `{REF:` and `}`: `W@S:Text`.
    private func resolveReference(_ spec: Substring, clearance: Clearance) -> Lookup {
        var header = spec.makeIterator()
        guard let wantedCode = header.next(), let wanted = FieldCode(wantedCode), wanted != .customFields,
              header.next() == "@",
              let searchCode = header.next(), let searchIn = FieldCode(searchCode),
              header.next() == ":"
        else { return .unresolved }
        let text = String(spec.dropFirst(4))
        guard text.isEmpty == false else { return .unresolved }
        let cleared = clearance == .protectedValues
        // Matching passwords means decrypting them.
        if searchIn == .password, cleared == false { return .protected }
        guard let (entry, matchedProtected) = findEntry(searchIn: searchIn, text: text) else { return .unresolved }
        if matchedProtected, cleared == false { return .protected }
        if isProtected(wanted, in: entry), cleared == false { return .protected }
        return value(of: wanted, in: entry).map(Lookup.value) ?? .unresolved
    }

    /// The first entry that matches, and whether only protected values matched in it.
    private func findEntry(searchIn: FieldCode, text: String) -> (KPEntry, Bool)? {
        if searchIn == .uuid {
            guard let id = UUID(kdbxHexString: text) else { return nil }
            return entriesByID[id].map { ($0, false) }
        }
        for entry in entries {
            let matches = candidateValues(of: searchIn, in: entry).filter {
                $0.value.range(of: text, options: .caseInsensitive) != nil
            }
            if matches.isEmpty == false {
                return (entry, matches.allSatisfy(\.isProtected))
            }
        }
        return nil
    }

    private func candidateValues(of code: FieldCode, in entry: KPEntry) -> [(value: String, isProtected: Bool)] {
        let protected = isProtected(code, in: entry)
        switch code {
        case .title: return [(entry.title, protected)]
        case .username: return [(entry.username, protected)]
        case .url: return [(entry.url, protected)]
        case .notes: return [(entry.notes, protected)]
        case .customFields:
            return entry.customFields.map { ($0.value, entry.protectedStringKeys.contains($0.key)) }
        case .password: return decryptedPassword(of: entry).map { [($0, true)] } ?? []
        case .uuid: return []
        }
    }

    private func isProtected(_ code: FieldCode, in entry: KPEntry) -> Bool {
        switch code {
        case .password: return entry.hasPassword
        case .title, .username, .url, .notes: return code.standardKey.map(entry.protectedStringKeys.contains) ?? false
        case .uuid, .customFields: return false
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

        /// The KDBX `<String>` key, for the standard fields.
        var standardKey: String? {
            switch self {
            case .title: "Title"
            case .username: "UserName"
            case .url: "URL"
            case .notes: "Notes"
            case .password, .uuid, .customFields: nil
            }
        }
    }
}
