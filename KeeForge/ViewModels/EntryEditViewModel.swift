import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class EntryEditViewModel {
    let id = UUID()

    struct CustomField: Identifiable, Equatable, Sendable {
        let id: UUID
        var key: String
        var value: String

        init(id: UUID = UUID(), key: String = "", value: String = "") {
            self.id = id
            self.key = key
            self.value = value
        }
    }

    enum Mode: Sendable, Equatable {
        case create(parentGroupID: UUID)
        case edit(entryID: UUID)
    }

    struct Snapshot: Equatable, Sendable {
        var title: String
        var username: String
        var password: String
        var url: String
        var notes: String
        var tagsText: String
        var customFields: [CustomField]
        var totpSecret: String
        var totpPeriod: Int
        var totpDigits: Int
        var totpAlgorithm: TOTPAlgorithm
    }

    let mode: Mode
    let passkeyCredential: PasskeyCredential?
    let unknownXMLNodeCount: Int

    var title: String
    var username: String
    var password: String
    var url: String
    var notes: String
    var tagsText: String
    var customFields: [CustomField]
    var totpSecret: String
    var totpPeriod: Int
    var totpDigits: Int
    var totpAlgorithm: TOTPAlgorithm

    private let preservedCustomFields: [String: String]
    private let originalSnapshot: Snapshot
    private let decodedTOTPSecret: Data?
    private let keeOTPSource: KeeOTPSource?
    /// The database's distinct tags as of the moment the editor opened, already
    /// in display order. A snapshot on purpose: the editor is modal over a
    /// stable tree, so the strip does not chase concurrent external changes —
    /// only the user's own typing moves it.
    private let knownTags: [String]
    /// The tags this entry's location already grants it, from its group and
    /// that group's ancestors. Suggesting one would offer a no-op, so they are
    /// excluded for as long as the editor is open (the entry cannot move while
    /// it is being edited).
    private let inheritedTags: Set<String>

    init(
        mode: Mode,
        title: String = "",
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        tags: [String] = [],
        knownTags: [String] = [],
        inheritedTags: [String] = [],
        editableCustomFields: [CustomField] = [],
        preservedCustomFields: [String: String] = [:],
        totpSecret: String = "",
        totpDecodedSecret: Data? = nil,
        keeOTPSource: KeeOTPSource? = nil,
        totpPeriod: Int = 30,
        totpDigits: Int = 6,
        totpAlgorithm: TOTPAlgorithm = .sha1,
        passkeyCredential: PasskeyCredential? = nil,
        unknownXMLNodeCount: Int = 0
    ) {
        self.mode = mode
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.tagsText = Self.tagsText(from: tags)
        self.knownTags = knownTags
        self.inheritedTags = Set(inheritedTags)
        self.customFields = editableCustomFields
        self.preservedCustomFields = preservedCustomFields
        self.totpSecret = totpSecret
        self.decodedTOTPSecret = totpDecodedSecret
        self.keeOTPSource = keeOTPSource
        self.totpPeriod = totpPeriod
        self.totpDigits = totpDigits
        self.totpAlgorithm = totpAlgorithm
        self.passkeyCredential = passkeyCredential
        self.unknownXMLNodeCount = unknownXMLNodeCount
        originalSnapshot = Snapshot(
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            tagsText: Self.tagsText(from: tags),
            customFields: editableCustomFields,
            totpSecret: totpSecret,
            totpPeriod: totpPeriod,
            totpDigits: totpDigits,
            totpAlgorithm: totpAlgorithm
        )
    }

    convenience init(
        createIn parentGroupID: UUID,
        knownTags: [String] = [],
        inheritedTags: [String] = []
    ) {
        self.init(
            mode: .create(parentGroupID: parentGroupID),
            knownTags: knownTags,
            inheritedTags: inheritedTags
        )
    }

    convenience init(
        editing entry: KPEntry,
        sessionKey: SymmetricKey,
        knownTags: [String] = [],
        inheritedTags: [String] = []
    ) {
        let editableCustomFields = entry.displayCustomFields
            .sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending })
            .map { CustomField(key: $0.key, value: $0.value) }
        let preservedCustomFields = entry.customFields.filter {
            PasskeyCredential.allFieldKeys.contains($0.key) || $0.key == entry.totpConfig?.keeOTPSource?.fieldName
        }
        let password = (try? entry.password.decrypt(using: sessionKey)) ?? ""
        let totpSecret = (try? entry.totpConfig?.secret.decrypt(using: sessionKey)) ?? ""
        let decodedTOTPSecret: Data?
        if let encryptedDecodedSecret = entry.totpConfig?.decodedSecret {
            decodedTOTPSecret = try? encryptedDecodedSecret.decryptData(using: sessionKey)
        } else {
            decodedTOTPSecret = nil
        }

        self.init(
            mode: .edit(entryID: entry.id),
            title: entry.title,
            username: entry.username,
            password: password,
            url: entry.url,
            notes: entry.notes,
            tags: entry.tags,
            knownTags: knownTags,
            inheritedTags: inheritedTags,
            editableCustomFields: editableCustomFields,
            preservedCustomFields: preservedCustomFields,
            totpSecret: totpSecret,
            totpDecodedSecret: decodedTOTPSecret,
            keeOTPSource: entry.totpConfig?.keeOTPSource,
            totpPeriod: entry.totpConfig?.period ?? 30,
            totpDigits: entry.totpConfig?.digits ?? 6,
            totpAlgorithm: entry.totpConfig?.algorithm ?? .sha1,
            passkeyCredential: entry.passkeyCredential,
            unknownXMLNodeCount: entry.unknownXML.nodes.count
        )
    }

    var isDirty: Bool {
        currentSnapshot != originalSnapshot
    }

    var canSave: Bool {
        switch mode {
        case .create:
            return isDirty
        case .edit:
            return isDirty
        }
    }

    var entryDraftPayload: EntryDraftPayload {
        EntryDraftPayload(
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            customFields: mergedCustomFields(),
            tags: normalizedTags(),
            totpConfig: normalizedTOTPConfiguration()
        )
    }

    /// The known tags worth offering for this entry: `knownTags` minus the tags
    /// currently typed into the field and minus the ones inherited from the
    /// entry's groups. The typed side is re-read on every access rather than
    /// cached, so a chip leaves the strip the moment its tag lands in the text
    /// and comes back when the text is deleted again.
    ///
    /// Exclusion is exact-string like the rest of the tag surface: typing
    /// `work` leaves `Work` on offer, because they are two tags.
    var tagSuggestions: [String] {
        let appliedTags = Set(normalizedTags())
        return knownTags.filter { tag in
            appliedTags.contains(tag) == false && inheritedTags.contains(tag) == false
        }
    }

    /// Adds `tag` to the tag field exactly as typing it would, joining with the
    /// same `", "` the field is seeded with so both routes normalize to an
    /// identical payload. A dangling separator in the existing text just yields
    /// an empty component, which normalization drops.
    ///
    /// A tag the field already carries is left untouched: `tagSuggestions`
    /// stops offering it, but a stale render must not be able to double it up.
    func appendTagSuggestion(_ tag: String) {
        guard normalizedTags().contains(tag) == false else { return }

        let trimmedText = tagsText.trimmingCharacters(in: .whitespacesAndNewlines)
        tagsText = trimmedText.isEmpty ? tag : trimmedText + ", " + tag
    }

    func addCustomField() {
        customFields.append(CustomField())
    }

    func removeCustomField(id: UUID) {
        customFields.removeAll(where: { $0.id == id })
    }

    func customFieldAccessibilityIdentifier(for field: CustomField, fallbackIndex: Int) -> String {
        let trimmedKey = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            return "entry-edit.custom-field.row.\(fallbackIndex)"
        }

        let normalizedKey = trimmedKey.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "entry-edit.custom-field.row.\(normalizedKey)"
    }

    private var currentSnapshot: Snapshot {
        Snapshot(
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            tagsText: tagsText,
            customFields: customFields,
            totpSecret: totpSecret,
            totpPeriod: totpPeriod,
            totpDigits: totpDigits,
            totpAlgorithm: totpAlgorithm
        )
    }

    private func mergedCustomFields() -> [String: String] {
        var merged = preservedCustomFields
        for field in customFields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else { continue }
            merged[key] = field.value
        }
        return merged
    }

    private func normalizedTags() -> [String] {
        TagNormalizer.tags(fromText: tagsText)
    }

    private func normalizedTOTPConfiguration() -> EntryDraftPayload.TOTPConfiguration? {
        let trimmedSecret = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSecret.isEmpty == false else { return nil }

        let secretChanged = trimmedSecret != originalSnapshot.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if secretChanged, keeOTPSource != nil,
           Self.canonicalBase32Secret(trimmedSecret) == nil {
            return EntryDraftPayload.TOTPConfiguration(
                secret: originalSnapshot.totpSecret,
                decodedSecret: decodedTOTPSecret,
                keeOTPSource: keeOTPSource,
                period: originalSnapshot.totpPeriod,
                digits: originalSnapshot.totpDigits,
                algorithm: originalSnapshot.totpAlgorithm
            )
        }

        let settingsChanged = totpPeriod != originalSnapshot.totpPeriod
            || totpDigits != originalSnapshot.totpDigits
            || totpAlgorithm != originalSnapshot.totpAlgorithm
        let rewrittenSource = secretChanged || settingsChanged
            ? keeOTPSource?.rewriting(
                secret: secretChanged ? Self.canonicalBase32Secret(trimmedSecret) : nil,
                period: totpPeriod,
                digits: totpDigits,
                algorithm: totpAlgorithm
            )
            : keeOTPSource

        return EntryDraftPayload.TOTPConfiguration(
            secret: secretChanged ? trimmedSecret : originalSnapshot.totpSecret,
            decodedSecret: secretChanged ? nil : decodedTOTPSecret,
            keeOTPSource: rewrittenSource,
            period: totpPeriod,
            digits: totpDigits,
            algorithm: totpAlgorithm
        )
    }

    private static func canonicalBase32Secret(_ value: String) -> String? {
        let normalized = value.uppercased()
        guard !normalized.isEmpty,
              normalized.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
              let decoded = TOTPGenerator.base32Decode(normalized), !decoded.isEmpty,
              base32Encode(decoded) == normalized else { return nil }
        return normalized
    }

    private static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var result: [UInt8] = []
        var accumulator = 0
        var bitCount = 0
        for byte in data {
            accumulator = (accumulator << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(alphabet[(accumulator >> bitCount) & 31])
                accumulator &= (1 << bitCount) - 1
            }
        }
        if bitCount > 0 {
            result.append(alphabet[(accumulator << (5 - bitCount)) & 31])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func tagsText(from tags: [String]) -> String {
        tags.joined(separator: ", ")
    }
}

extension EntryEditViewModel: Hashable {
    nonisolated static func == (lhs: EntryEditViewModel, rhs: EntryEditViewModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// `id` is a stable `UUID`, so identity-based `Identifiable` is sound; used by
/// `sheet(item:)` for the macOS New Entry command.
extension EntryEditViewModel: Identifiable {
}
