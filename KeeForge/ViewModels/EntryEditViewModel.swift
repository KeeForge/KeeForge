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

    init(
        mode: Mode,
        title: String = "",
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        tags: [String] = [],
        editableCustomFields: [CustomField] = [],
        preservedCustomFields: [String: String] = [:],
        totpSecret: String = "",
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
        self.customFields = editableCustomFields
        self.preservedCustomFields = preservedCustomFields
        self.totpSecret = totpSecret
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
        createIn parentGroupID: UUID
    ) {
        self.init(mode: .create(parentGroupID: parentGroupID))
    }

    convenience init(
        editing entry: KPEntry,
        sessionKey: SymmetricKey
    ) {
        let editableCustomFields = entry.displayCustomFields
            .sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending })
            .map { CustomField(key: $0.key, value: $0.value) }
        let preservedCustomFields = entry.customFields.filter { PasskeyCredential.allFieldKeys.contains($0.key) }
        let password = (try? entry.password.decrypt(using: sessionKey)) ?? ""
        let totpSecret = (try? entry.totpConfig?.secret.decrypt(using: sessionKey)) ?? ""

        self.init(
            mode: .edit(entryID: entry.id),
            title: entry.title,
            username: entry.username,
            password: password,
            url: entry.url,
            notes: entry.notes,
            tags: entry.tags,
            editableCustomFields: editableCustomFields,
            preservedCustomFields: preservedCustomFields,
            totpSecret: totpSecret,
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
        tagsText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func normalizedTOTPConfiguration() -> EntryDraftPayload.TOTPConfiguration? {
        let secret = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.isEmpty == false else { return nil }

        return EntryDraftPayload.TOTPConfiguration(
            secret: secret,
            period: totpPeriod,
            digits: totpDigits,
            algorithm: totpAlgorithm
        )
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
