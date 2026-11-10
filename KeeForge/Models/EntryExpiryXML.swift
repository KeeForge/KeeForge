import Foundation
import KDBXXML

/// Writes an entry's expiration into its preserved `<Times>` XML.
///
/// `<ExpiryTime>` and `<Expires>` are not structured elements: the parser reads
/// them into `KPEntry.expiryTime`/`expires` for display but keeps the source
/// elements in `unknownXML`, and the serializer writes only those. Changing an
/// expiration is therefore a splice of the preserved fragments, and the display
/// copy changes in the same step so the two cannot disagree.
enum EntryExpiryXML {
    /// `entry` expiring as `expiry` says, or `entry` untouched when it already
    /// does, so saving an unchanged form never rewrites the elements.
    ///
    /// Turning expiration off rewrites only `<Expires>`; the stored date stays,
    /// as it does in KeePass and KeePassXC. An existing element keeps its slot;
    /// a new one goes where KeePass writes it.
    static func entry(_ entry: KPEntry, expiring expiry: EntryExpiry) -> KPEntry {
        var updated = entry
        var element = KDBXWriter.element(of: entry)
        switch expiry {
        case .never:
            guard entry.enabledExpiryTime != nil else { return entry }
            updated.expires = false
        case .at(let date):
            let storedDate = date.kdbxStoredDate
            guard entry.enabledExpiryTime != storedDate else { return entry }
            updated.expires = true
            updated.expiryTime = storedDate
            element.replaceOpaqueTimesChildren(
                named: "ExpiryTime",
                with: ["<ExpiryTime>\(storedDate.kdbxBase64String)</ExpiryTime>"]
            )
        }
        element.replaceOpaqueTimesChildren(named: "Expires", with: ["<Expires>\(updated.expires ? "True" : "False")</Expires>"])
        updated.unknownXML = element.unknownXML
        return updated
    }
}
