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
        var tags: [String]
        var customFields: [CustomField]
        var totpSecret: String
        var totpPeriod: Int
        var totpDigits: Int
        var totpAlgorithm: TOTPAlgorithm
        var enrolledOTPAuthURI: String?
    }

    let mode: Mode
    let passkeyCredential: PasskeyCredential?
    let unknownXMLNodeCount: Int

    var title: String
    var username: String
    var password: String
    var url: String
    var notes: String
    /// Tags the user has committed, rendered as removable pills. Order is the
    /// order they arrived in — the file's own order when seeded — and identity
    /// is exact-string, so `Work` and `work` are two pills.
    private(set) var tags: [String]
    /// The tag being typed, not yet committed to a pill. It still counts
    /// toward the payload and toward suggestion exclusion, so saving straight
    /// from a half-typed field never loses the tag.
    var pendingTagText: String = ""
    var customFields: [CustomField]
    var totpSecret: String
    var totpPeriod: Int
    var totpDigits: Int
    var totpAlgorithm: TOTPAlgorithm
    /// The verbatim `otpauth://` URI this editing session enrolled from, nil
    /// otherwise. Whether it reaches the payload is decided at payload time,
    /// so later field edits need no invalidation bookkeeping.
    private var enrolledOTPAuthURI: String?

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
        self.tags = TagNormalizer.tags(from: tags)
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
            tags: TagNormalizer.tags(from: tags),
            customFields: editableCustomFields,
            totpSecret: totpSecret,
            totpPeriod: totpPeriod,
            totpDigits: totpDigits,
            totpAlgorithm: totpAlgorithm,
            enrolledOTPAuthURI: nil
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

    var isPasswordInitiallyVisible: Bool {
        if case .create = mode { return true }
        return false
    }

    var requiresAuthenticationToRevealPassword: Bool {
        if case .edit = mode { return true }
        return false
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
    /// the entry already carries — committed pills and the pending token alike
    /// — and minus the ones inherited from the entry's groups. The applied side
    /// is re-read on every access rather than cached, so a chip leaves the strip
    /// the moment its tag lands and comes back when the pill is removed again.
    ///
    /// Exclusion is exact-string like the rest of the tag surface: typing
    /// `work` leaves `Work` on offer, because they are two tags.
    var tagSuggestions: [String] {
        let appliedTags = Set(normalizedTags())
        return knownTags.filter { tag in
            appliedTags.contains(tag) == false && inheritedTags.contains(tag) == false
        }
    }

    /// Commits what is in the field, splitting it on every separator, so a
    /// typed `a, b` and a pasted `a;b` both land as two pills.
    ///
    /// Committing is deliberately never triggered from the field's setter.
    /// Rewriting a `TextField`'s bound text while the user is typing races the
    /// keystrokes still in flight and silently loses them (reproduced: typing
    /// `alpha,beta,gam` kept only `alpha` and dropped four characters). Return,
    /// or tapping a suggestion, is a pause in typing, so rewriting is safe
    /// there. Anything left uncommitted still reaches the payload.
    func commitPendingTag() {
        appendTags(TagNormalizer.tags(fromText: pendingTagText))
        pendingTagText = ""
    }

    /// Adds `tag` as a committed pill, exactly as typing it and pressing Return
    /// would. A half-typed token is committed first, so pills end up in the
    /// order the user acted rather than jumping the tapped tag ahead of it.
    ///
    /// A tag the entry already carries is left alone: `tagSuggestions` stops
    /// offering it, but a stale render must not be able to double it up.
    func appendTagSuggestion(_ tag: String) {
        commitPendingTag()
        appendTags([tag])
    }

    /// Drops a committed pill. Unknown tags are ignored, so a stale render
    /// cannot remove something the user already removed.
    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    /// Dedupes against the committed pills only, never `normalizedTags()`:
    /// every caller is in the act of turning the pending token into a pill, and
    /// counting that token as already-applied would make committing it look
    /// like a duplicate and drop it on the floor.
    private func appendTags(_ newTags: [String]) {
        guard newTags.isEmpty == false else { return }

        var applied = Set(tags)
        for tag in newTags where applied.insert(tag).inserted {
            tags.append(tag)
        }
    }


    /// Fills the TOTP form from a parsed enrollment URI. KeeOTP-sourced
    /// entries keep their query-rewrite path, so the URI itself is only
    /// retained for verbatim storage when no legacy source owns the config.
    func applyOTPAuthURI(_ uri: OTPAuthURI) {
        totpSecret = uri.secret
        totpPeriod = uri.period
        totpDigits = uri.digits
        totpAlgorithm = uri.algorithm
        enrolledOTPAuthURI = keeOTPSource == nil ? uri.rawURI : nil
    }

    /// Parses `text` as an `otpauth://` setup link and fills the form on
    /// success; returns the parse error — leaving the form untouched —
    /// otherwise.
    @discardableResult
    func applySetupLink(_ text: String) -> OTPAuthURIError? {
        let uri: OTPAuthURI
        do {
            uri = try OTPAuthURI(string: text)
        } catch let error as OTPAuthURIError {
            return error
        } catch {
            return .notAnOTPAuthURI
        }
        applyOTPAuthURI(uri)
        return nil
    }

    func removeTOTP() {
        totpSecret = ""
        enrolledOTPAuthURI = nil
        totpPeriod = 30
        totpDigits = 6
        totpAlgorithm = .sha1
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
            // The pending token counts: typing a tag and saving without
            // committing it must read as a change, and must save the tag.
            tags: normalizedTags(),
            customFields: customFields,
            totpSecret: totpSecret,
            totpPeriod: totpPeriod,
            totpDigits: totpDigits,
            totpAlgorithm: totpAlgorithm,
            enrolledOTPAuthURI: enrolledOTPAuthURI
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

    /// The committed pills plus whatever is still being typed, so an
    /// uncommitted token is never silently dropped by saving.
    private func normalizedTags() -> [String] {
        TagNormalizer.tags(from: tags + [pendingTagText])
    }

    private func normalizedTOTPConfiguration() -> EntryDraftPayload.TOTPConfiguration? {
        let trimmedSecret = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSecret.isEmpty == false else { return nil }

        let secretChanged = trimmedSecret != originalSnapshot.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // A KeeOTP query the parser would reject on reload (non-canonical
        // secret, or a size outside its {6, 8} whitelist) must never be
        // written: revert to the original snapshot instead.
        if keeOTPSource != nil,
           (secretChanged && TOTPGenerator.canonicalBase32Secret(trimmedSecret) == nil)
               || [6, 8].contains(totpDigits) == false {
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
                secret: secretChanged ? TOTPGenerator.canonicalBase32Secret(trimmedSecret) : nil,
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
            algorithm: totpAlgorithm,
            otpauthURI: payloadOTPAuthURI(currentSecret: trimmedSecret)
        )
    }

    /// The enrolled URI is emitted only while its parsed values still match
    /// the form; a post-enrollment edit silently drops it (the existing
    /// verbatim-or-drop philosophy for stored otpauth URIs).
    private func payloadOTPAuthURI(currentSecret: String) -> String? {
        guard keeOTPSource == nil,
              let enrolledOTPAuthURI,
              let uri = try? OTPAuthURI(string: enrolledOTPAuthURI),
              let decoded = TOTPGenerator.base32Decode(currentSecret), !decoded.isEmpty,
              TOTPGenerator.base32Encode(decoded) == uri.secret,
              uri.period == totpPeriod,
              uri.digits == totpDigits,
              uri.algorithm == totpAlgorithm else { return nil }
        return enrolledOTPAuthURI
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
