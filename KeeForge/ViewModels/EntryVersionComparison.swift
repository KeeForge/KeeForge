import CryptoKit
import Foundation

/// Which fields of a stored entry version differ from the current entry. Protected values are
/// compared in memory and only the fact that they differ leaves: a difference carries the current
/// value only for a field that is not protected and whose field references stay at the default
/// clearance, never plaintext of a protected value.
struct EntryVersionComparison: Equatable {
    enum Field: Hashable {
        case title
        case username
        case password
        /// 0 is the entry's URL; 1 and later its extra URL rows, in `KPEntry.additionalURLs` order.
        case website(Int)
        case verificationCode
        case custom(String)
        case notes
        case tags
        case expiry
    }

    /// The current entry's value of a differing field, for the "Now:" line.
    enum CurrentValue: Equatable {
        case text(String)
        case tags([String])
        case date(Date)
        /// The current entry has no value here.
        case empty
        /// Protected, or reached through a protected field reference: only "differs" may be shown.
        case concealed
    }

    struct Difference: Equatable {
        let field: Field
        let current: CurrentValue
    }

    /// In the order the history sheet lists fields.
    let differences: [Difference]

    var differingFieldCount: Int { differences.count }

    func differs(_ field: Field) -> Bool {
        differences.contains { $0.field == field }
    }

    func current(_ field: Field) -> CurrentValue? {
        differences.first { $0.field == field }?.current
    }

    /// `displayValue` resolves field references at the default clearance and answers nil when one
    /// needs a protected value (`DatabaseViewModel.fieldReferenceResolution(of:).value`).
    @MainActor
    init(version: KPEntry, current: KPEntry, sessionKey: SymmetricKey, displayValue: (String) -> String?) {
        var differences: [Difference] = []
        func compareText(_ field: Field, key: String, _ old: String?, _ new: String?) {
            let old = old ?? "", new = new ?? ""
            guard old != new else { return }
            let isProtected = version.protectedStringKeys.contains(key) || current.protectedStringKeys.contains(key)
            let value: CurrentValue = if isProtected {
                .concealed
            } else if new.isEmpty {
                .empty
            } else {
                displayValue(new).map(CurrentValue.text) ?? .concealed
            }
            differences.append(Difference(field: field, current: value))
        }

        compareText(.title, key: "Title", version.title, current.title)
        compareText(.username, key: "UserName", version.username, current.username)

        if Self.plaintext(of: version.password, sessionKey) != Self.plaintext(of: current.password, sessionKey) {
            differences.append(Difference(field: .password, current: current.hasPassword ? .concealed : .empty))
        }

        let oldWebsites = Self.websites(of: version), newWebsites = Self.websites(of: current)
        for index in 0..<max(oldWebsites.count, newWebsites.count) {
            let old = oldWebsites.indices.contains(index) ? oldWebsites[index] : nil
            let new = newWebsites.indices.contains(index) ? newWebsites[index] : nil
            compareText(.website(index), key: new?.key ?? old?.key ?? "", old?.value, new?.value)
        }

        if Self.verificationCode(of: version, sessionKey) != Self.verificationCode(of: current, sessionKey) {
            differences.append(Difference(field: .verificationCode, current: current.totpConfig == nil ? .empty : .concealed))
        }

        let oldCustom = EntryEditViewModel.orderedCustomFieldsOutsideURLRows(of: version)
        let newCustom = EntryEditViewModel.orderedCustomFieldsOutsideURLRows(of: current)
        let newKeys = newCustom.map(\.key)
        for key in newKeys + oldCustom.map(\.key).filter({ newKeys.contains($0) == false }) {
            compareText(.custom(key), key: key, oldCustom.first { $0.key == key }?.value,
                        newCustom.first { $0.key == key }?.value)
        }

        compareText(.notes, key: "Notes", version.notes, current.notes)

        let oldTags = TagNormalizer.tags(from: version.tags), newTags = TagNormalizer.tags(from: current.tags)
        if Set(oldTags) != Set(newTags) {
            differences.append(Difference(field: .tags, current: newTags.isEmpty ? .empty : .tags(newTags)))
        }

        if version.enabledExpiryTime != current.enabledExpiryTime {
            differences.append(Difference(field: .expiry, current: current.enabledExpiryTime.map(CurrentValue.date) ?? .empty))
        }

        self.differences = differences
    }

    private struct VerificationCode: Equatable {
        let secret: Data?
        let decodedSecret: Data?
        let period: Int
        let digits: Int
        let algorithm: TOTPAlgorithm
    }

    private static func plaintext(of value: EncryptedValue, _ key: SymmetricKey) -> Data? {
        value.hasValue ? try? value.decryptData(using: key) : Data()
    }

    private static func verificationCode(of entry: KPEntry, _ key: SymmetricKey) -> VerificationCode? {
        entry.totpConfig.map {
            VerificationCode(secret: plaintext(of: $0.secret, key),
                             decodedSecret: $0.decodedSecret.flatMap { plaintext(of: $0, key) },
                             period: $0.period, digits: $0.digits, algorithm: $0.algorithm)
        }
    }

    /// The entry's URL, then its extra URL rows as `KPEntry.additionalURLs` orders them, with their storage keys.
    private static func websites(of entry: KPEntry) -> [(key: String, value: String)] {
        let extra = entry.customFields
            .filter { $0.key.hasPrefix(EntryEditViewModel.additionalURLKeyPrefix) && $0.value.isEmpty == false }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
        return [(key: "URL", value: entry.url)] + extra
    }
}
