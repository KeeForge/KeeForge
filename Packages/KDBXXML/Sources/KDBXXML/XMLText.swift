import Foundation

enum XMLText {
    /// Escapes text content. A literal CR would read back as LF, so it becomes
    /// a character reference.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#xD;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Reverses `escape` and `escapeAttribute`, the only forms canonical
    /// fragments contain.
    static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#xD;", with: "\r")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// XML 1.0 `Char`.
    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    static func firstInvalidScalar(in text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first { !isAllowed($0) }
    }

    /// `xml` with the content of every protected value replaced, in order.
    /// Canonical fragments escape `<` and `>` in text and attributes, so the
    /// next `>` ends a tag and the next `</Value>` ends its value.
    static func replacingProtectedValues(in xml: String, _ transform: (Substring) -> String) -> String {
        var output = ""
        var rest = Substring(xml)
        while let open = rest.range(of: "<Value"),
              let close = rest[open.upperBound...].firstIndex(of: ">"),
              let end = rest[close...].range(of: "</Value>") {
            let tag = rest[open.lowerBound...close]
            let content = rest.index(after: close)..<end.lowerBound
            guard isProtectedValueTag(tag) else {
                output += rest[..<content.lowerBound]
                rest = rest[content.lowerBound...]
                continue
            }
            output += rest[..<content.lowerBound] + transform(rest[content])
            rest = rest[content.upperBound...]
        }
        return output + rest
    }

    /// `<Value …>` (not `<ValueX>` or self-closing) whose `Protected` attribute
    /// is `true` in any case.
    private static func isProtectedValueTag(_ tag: Substring) -> Bool {
        let afterName = tag.dropFirst("<Value".count)
        guard let next = afterName.first, next == " " || next == ">", !tag.hasSuffix("/>"),
              let attribute = afterName.range(of: " Protected=\"") else { return false }
        return afterName[attribute.upperBound...].prefix { $0 != "\"" }.lowercased() == "true"
    }

    /// `<name attributes>content</name>`, attributes sorted by name.
    static func element(_ name: String, attributes: [String: String] = [:], content: String) -> String {
        let rendered = attributes
            .sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(escapeAttribute($0.value))\"" }
            .joined()
        return "<\(name)\(rendered)>\(content)</\(name)>"
    }

    /// KeePass splits stored tags on `,` and `;`, trims each, and drops
    /// empties. No dedupe, no reordering.
    static func splitTags(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet([",", ";"]))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
