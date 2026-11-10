import Foundation

// Splicing an element the document keeps opaque. A new fragment's position is
// counted against the typed children the writer emits, in the order it emits
// them, so it is written where KeePass writes that element.
//
// Each method replaces every `name` fragment with `fragments`, which must be
// canonical `<name>` elements (see `OpaqueXMLNodes`). They take the first
// existing fragment's position; with none, they go where KeePass writes
// `<name>`. An empty `fragments` removes the element. A position depends only
// on the typed children KeePass writes before `<name>`, so a value without its
// later children (an entry's strings and history, a group's entries and
// subgroups) answers the same.

extension KDBXDocument.Meta {
    /// Sets a direct `<Meta>` child, such as `<CustomIcons>`.
    public mutating func replaceOpaqueChildren(named name: String, with fragments: [String]) {
        unknownXML.replaceChildren(named: name, path: [], with: fragments, layout: layout)
    }
}

extension KDBXDocument.Group {
    /// Sets a direct `<Group>` child, such as `<PreviousParentGroup>`.
    public mutating func replaceOpaqueChildren(named name: String, with fragments: [String]) {
        unknownXML.replaceChildren(named: name, path: [], with: fragments, layout: layout)
    }

    /// Sets a `<Times>` child, such as `<ExpiryTime>`.
    public mutating func replaceOpaqueTimesChildren(named name: String, with fragments: [String]) {
        unknownXML.replaceChildren(named: name, path: ["Times"], with: fragments, layout: times.layout)
    }
}

extension KDBXDocument.Entry {
    /// Sets a direct `<Entry>` child, such as `<CustomIconUUID>`.
    public mutating func replaceOpaqueChildren(named name: String, with fragments: [String]) {
        unknownXML.replaceChildren(named: name, path: [], with: fragments, layout: layout)
    }

    /// Sets a `<Times>` child, such as `<ExpiryTime>`.
    public mutating func replaceOpaqueTimesChildren(named name: String, with fragments: [String]) {
        unknownXML.replaceChildren(named: name, path: ["Times"], with: fragments, layout: times.layout)
    }

    /// The `BinaryReference.insertionIndex` that writes a `<Binary>` right
    /// after the first `count` `<String>` children. The strings themselves
    /// need not be set.
    public func binaryInsertionIndex(afterStrings count: Int) -> Int {
        layout.typedCount(before: "String") + count
    }
}
