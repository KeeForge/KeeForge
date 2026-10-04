import Foundation

/// Writes an entry's expiration into its preserved `<Times>` XML.
///
/// `<ExpiryTime>` and `<Expires>` are not structured elements: the parser reads
/// them into `KPEntry.expiryTime`/`expires` for display but keeps the source
/// elements in `unknownXML`, and the serializer writes only those. Changing an
/// expiration is therefore a splice of the preserved fragments, and the display
/// copy changes in the same step so the two cannot disagree.
enum EntryExpiryXML {
    private static let timesPath = ["Times"]

    /// KeePass's `<Times>` child order, which a newly added element follows.
    private static let timesOrder = [
        "CreationTime", "LastModificationTime", "LastAccessTime",
        "ExpiryTime", "Expires", "UsageCount", "LocationChanged",
    ]

    /// `entry` expiring as `expiry` says, or `entry` untouched when it already
    /// does, so saving an unchanged form never rewrites the elements.
    ///
    /// Turning expiration off rewrites only `<Expires>`; the stored date stays,
    /// as it does in KeePass and KeePassXC.
    static func entry(_ entry: KPEntry, expiring expiry: EntryExpiry) -> KPEntry {
        var updated = entry
        switch expiry {
        case .never:
            guard entry.enabledExpiryTime != nil else { return entry }
            updated.expires = false
        case .at(let date):
            let storedDate = date.kdbxStoredDate
            guard entry.enabledExpiryTime != storedDate else { return entry }
            updated.expires = true
            updated.expiryTime = storedDate
            updated.unknownXML = setting(
                "ExpiryTime",
                to: "<ExpiryTime>\(storedDate.kdbxBase64String)</ExpiryTime>",
                in: updated
            )
        }
        updated.unknownXML = setting("Expires", to: "<Expires>\(updated.expires ? "True" : "False")</Expires>", in: updated)
        return updated
    }

    /// `entry`'s preserved XML with every `<name>` under `<Times>` replaced by
    /// `xml`, or removed when `xml` is nil. A replacement takes the first
    /// existing element's slot; a new element goes where KeePass writes it.
    private static func setting(_ name: String, to xml: String?, in entry: KPEntry) -> OpaqueXMLNodes {
        var nodes = entry.unknownXML.nodes
        let existing = nodes.indices.filter { nodes[$0].path == timesPath && nodes[$0].elementName == name }

        if let first = existing.first {
            let insertionIndex = nodes[first].insertionIndex
            for index in existing.reversed() {
                nodes.remove(at: index)
            }
            if let xml {
                nodes.insert(.init(path: timesPath, insertionIndex: insertionIndex, xml: xml), at: first)
            }
            return OpaqueXMLNodes(nodes: nodes)
        }

        guard let xml else { return entry.unknownXML }
        // `<CreationTime>` and `<LastModificationTime>` are the structured
        // children written ahead of it; `<LocationChanged>` comes after.
        let insertionIndex = (entry.creationTime == nil ? 0 : 1) + (entry.lastModificationTime == nil ? 0 : 1)
        let rank = timesOrder.firstIndex(of: name) ?? timesOrder.count
        let position = nodes.firstIndex { node in
            guard node.path == timesPath, node.insertionIndex == insertionIndex,
                  let nodeRank = node.elementName.flatMap({ timesOrder.firstIndex(of: $0) }) else { return false }
            return nodeRank > rank
        } ?? nodes.endIndex
        nodes.insert(.init(path: timesPath, insertionIndex: insertionIndex, xml: xml), at: position)
        return OpaqueXMLNodes(nodes: nodes)
    }
}
