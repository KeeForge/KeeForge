#if os(macOS)
import Foundation
import Observation

/// Which entry a Mac detail shows: the live entry, or one of its stored versions.
enum EntrySource: Hashable {
    case live(UUID)
    /// `index` is the version's position in the entry's stored `<History>`, as in `EntryHistoryVersion.index`.
    case history(entryID: UUID, index: Int)

    var entryID: UUID {
        switch self {
        case .live(let entryID), .history(let entryID, _): entryID
        }
    }

    /// The source's version of `live`, the entry as the session holds it now.
    func version(of live: KPEntry) -> KPEntry? {
        switch self {
        case .live: live
        case .history(_, let index): live.history.indices.contains(index) ? live.history[index] : nil
        }
    }
}

/// One row of the Mac entry detail. It carries plaintext only while its field is revealed and on screen.
struct MacEntryField: Identifiable, Equatable {
    enum Kind: Hashable {
        case username
        case password
        /// 0 is the entry's URL; 1 and later its extra URL rows, in `KPEntry.additionalURLs` order.
        case website(Int)
        case verificationCode
        case passkeyRelyingParty
        case passkeyUsername
        case custom(String)
        case notes
    }

    enum Display: Equatable {
        case plain(String)
        case concealed
        case revealed(String)
        /// The view draws the live code from `MacEntryDetailModel.verificationCodeConfig`.
        case verificationCode
    }

    let kind: Kind
    let label: String
    let display: Display
    /// Stored protected, or a field reference reaching a protected value: shown and copied only behind the gate.
    let isProtected: Bool

    var id: Kind { kind }
    var canReveal: Bool { isProtected }
    var canCopy: Bool { kind != .notes }
    var canShowInLargeType: Bool { kind == .password }
    /// A concealed website opens only once revealed.
    var openableURL: URL? {
        guard case .website = kind else { return nil }
        switch display {
        case .plain(let value), .revealed(let value): return URL(string: value)
        case .concealed, .verificationCode: return nil
        }
    }
}

/// What the Mac entry detail shows for one `EntrySource`, and its reveal, copy and Large Type
/// actions, every one through `DatabaseCommands.discloseEntrySecret`. It never stores plaintext:
/// a revealed field is decrypted when read, only while the model is on screen. Lock, a content
/// change, a selection change, `invalidate()` and leaving the screen mid-prompt conceal.
@MainActor @Observable
final class MacEntryDetailModel {
    struct Attachment: Identifiable, Equatable {
        let index: Int
        let name: String
        /// Nil for a file the database no longer holds.
        let byteCount: Int?
        var isDangling: Bool { byteCount == nil }
        var id: Int { index }
    }

    struct Tags: Equatable {
        let own: [String]
        let inherited: [DatabaseViewModel.InheritedTagSource]
    }

    private struct RevealStamp: Equatable {
        let lockCycleID: Int
        let contentRevision: Int
        let selectedEntryID: UUID?
    }

    let source: EntrySource
    let session: DatabaseViewModel
    private let copyFeedback: MacCopyFeedback
    let currentSession: @MainActor () -> DatabaseViewModel?
    private let copyToClipboard: @MainActor (String) -> Void
    private let secretAction = EntrySecretAction()
    private var revealedKinds: Set<MacEntryField.Kind> = []
    private var revealStamp: RevealStamp?
    private(set) var isVisible = false

    /// `currentSession` answers, after authentication, which session the window still shows.
    init(
        source: EntrySource,
        session: DatabaseViewModel,
        copyFeedback: MacCopyFeedback,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) {
        self.source = source
        self.session = session
        self.copyFeedback = copyFeedback
        self.currentSession = currentSession
        copyToClipboard = copy
    }

    var isAuthenticating: Bool { secretAction.isAuthenticating }

    var entry: KPEntry? {
        guard session.state == .unlocked, session.sessionKey != nil,
              let live = session.entry(withID: source.entryID) else { return nil }
        return source.version(of: live)
    }

    // MARK: - Lifecycle

    func appeared() {
        isVisible = true
    }

    /// Keeps a completed reveal while the entry stays selected (the inline editor took its place);
    /// cancels a pending prompt.
    func disappeared() {
        isVisible = false
        if case .live(let entryID) = source, session.workspace.selectedEntryID != entryID {
            invalidate()
        } else {
            secretAction.invalidate()
        }
    }

    func invalidate() {
        revealedKinds = []
        revealStamp = nil
        secretAction.invalidate()
    }

    // MARK: - Fields

    var fields: [MacEntryField] {
        guard let entry else { return [] }
        var fields: [MacEntryField] = []
        if entry.username.isEmpty == false {
            fields.append(stringField(.username, label: String(localized: "Username"), raw: entry.username))
        }
        if entry.hasPassword {
            fields.append(MacEntryField(
                kind: .password, label: String(localized: "Password"),
                display: protectedDisplay(.password) { self.session.resolvedPassword(for: entry) },
                isProtected: true
            ))
        }
        for (index, url) in websites(of: entry) {
            let label = index == 0 ? String(localized: "Website") : String(localized: "Website \(index + 1)")
            fields.append(stringField(.website(index), label: label, raw: url))
        }
        if entry.totpConfig != nil {
            fields.append(MacEntryField(kind: .verificationCode, label: String(localized: "Verification Code"),
                                        display: .verificationCode, isProtected: false))
        }
        if let passkey = entry.passkeyCredential {
            fields.append(stringField(.passkeyRelyingParty, label: String(localized: "Relying Party"),
                                      raw: passkey.relyingParty))
            fields.append(stringField(.passkeyUsername, label: String(localized: "Username"), raw: passkey.username))
        }
        for (key, value) in EntryEditViewModel.orderedCustomFieldsOutsideURLRows(of: entry) {
            fields.append(stringField(.custom(key), label: key, raw: value,
                                      isStoredProtected: entry.protectedStringKeys.contains(key)))
        }
        if entry.notes.isEmpty == false {
            fields.append(stringField(.notes, label: String(localized: "Notes"), raw: entry.notes))
        }
        return fields
    }

    func isRevealed(_ kind: MacEntryField.Kind) -> Bool {
        isVisible && revealedKinds.contains(kind) && revealStamp == currentStamp
            && session.state == .unlocked && session.sessionKey != nil
    }

    /// Computed from the plaintext, so only while the password is revealed.
    var passwordStrength: PasswordStrengthEstimate? {
        guard isRevealed(.password), let entry else { return nil }
        return PasswordStrengthEstimator.estimate(session.resolvedPassword(for: entry))
    }

    var verificationCodeConfig: TOTPConfig? { entry?.totpConfig }

    // MARK: - Header and footer

    var title: String { entry?.title ?? "" }
    var pathComponents: [String] { session.folderPathComponents(forEntryID: source.entryID) ?? [] }
    var modified: Date? { entry?.lastModificationTime }
    var created: Date? { entry?.creationTime }
    var expiry: Date? { entry?.enabledExpiryTime }
    var isExpired: Bool { entry?.isExpired() == true }
    var passkeyRelyingParty: String? { entry?.passkeyCredential?.relyingParty }

    /// Earlier versions of the live entry; a version has none of its own.
    var historyCount: Int {
        guard case .live = source else { return 0 }
        return entry?.history.count ?? 0
    }

    var attachments: [Attachment] {
        guard let entry else { return [] }
        return entry.attachments.enumerated().map { index, attachment in
            Attachment(index: index, name: attachment.name, byteCount: session.attachmentByteCount(for: attachment))
        }
    }

    var tags: Tags {
        guard let entry else { return Tags(own: [], inherited: []) }
        switch source {
        case .live(let entryID):
            return Tags(own: session.detailTags(forEntryID: entryID).own,
                        inherited: session.inheritedTagSources(forEntryID: entryID))
        case .history:
            return Tags(own: TagNormalizer.tags(from: entry.tags), inherited: [])
        }
    }

    // MARK: - Actions

    /// Hiding is immediate; showing takes the device-owner gate and the disclosure rechecks.
    @discardableResult
    func toggleReveal(_ kind: MacEntryField.Kind) -> Task<Void, Never>? {
        if isRevealed(kind) {
            revealedKinds.remove(kind)
            return nil
        }
        guard isVisible, fields.first(where: { $0.kind == kind })?.isProtected == true else { return nil }
        let reason = kind == .password ? String(localized: "View password") : String(localized: "View protected field")
        return disclose(kind, reason: reason) { [weak self] _ in
            guard let self else { return }
            let stamp = currentStamp
            if revealStamp != stamp {
                revealedKinds = []
                revealStamp = stamp
            }
            revealedKinds.insert(kind)
        }
    }

    /// A plain value copies at once; a protected one after the gate. The tick shows only after the clipboard write.
    @discardableResult
    func copy(_ kind: MacEntryField.Kind) -> Task<Void, Never>? {
        guard let feedbackField = Self.feedbackField(for: kind), let entry else { return nil }
        let record = copyFeedback.recording(feedbackField, for: source.entryID, copy: copyToClipboard)
        switch kind {
        case .password:
            guard entry.hasPassword else { return nil }
            return disclose(.password, reason: String(localized: "Copy password"), checksVisibility: false,
                            then: record)
        case .verificationCode:
            // Not gated, like `DatabaseCommands.copyVerificationCode`: the code expires on its own.
            guard let config = entry.totpConfig, let sessionKey = session.sessionKey else { return nil }
            record(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
            return nil
        default:
            let source = source
            return DatabaseCommands.copyEntryValue(
                entryID: source.entryID, in: session, action: secretAction,
                isProtected: Self.isStoredProtected(kind, in: entry),
                raw: { live in source.version(of: live).flatMap { Self.rawValue(of: kind, in: $0) } },
                currentSession: currentSession, copy: record
            )
        }
    }

    @discardableResult
    func showPasswordInLargeType(present: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
        guard isVisible, entry?.hasPassword == true else { return nil }
        return disclose(.password, reason: String(localized: "View password"), then: present)
    }

    func isShowingCopied(_ kind: MacEntryField.Kind) -> Bool {
        guard let field = Self.feedbackField(for: kind) else { return false }
        return copyFeedback.field(copiedFor: source.entryID) == field
    }

    // MARK: - Private

    private var currentStamp: RevealStamp {
        RevealStamp(lockCycleID: session.lockCycleID, contentRevision: session.contentRevision,
                    selectedEntryID: session.workspace.selectedEntryID)
    }

    private func disclose(
        _ kind: MacEntryField.Kind,
        reason: String,
        checksVisibility: Bool = true,
        then disclose: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never>? {
        let source = source
        let session = session
        return DatabaseCommands.discloseEntrySecret(
            entryID: source.entryID, in: session, action: secretAction, reason: reason,
            currentSession: currentSession,
            isCurrent: { [weak self] in checksVisibility == false || self?.isVisible == true },
            value: { live in source.version(of: live).flatMap { Self.secret(of: kind, in: $0, session: session) } },
            disclose: disclose
        )
    }

    private func websites(of entry: KPEntry) -> [(Int, String)] {
        let first = entry.url.isEmpty ? [] : [(0, entry.url)]
        return first + entry.additionalURLs.enumerated().map { ($0.offset + 1, $0.element) }
    }

    private func stringField(
        _ kind: MacEntryField.Kind, label: String, raw: String, isStoredProtected: Bool = false
    ) -> MacEntryField {
        let resolve = { self.session.resolvingFieldReferencesIncludingProtectedValues(raw) }
        if isStoredProtected {
            return MacEntryField(kind: kind, label: label, display: protectedDisplay(kind, resolve), isProtected: true)
        }
        switch session.fieldReferenceResolution(of: raw) {
        case .resolved(let value):
            return MacEntryField(kind: kind, label: label, display: .plain(value), isProtected: false)
        case .needsProtectedValue:
            return MacEntryField(kind: kind, label: label, display: protectedDisplay(kind, resolve), isProtected: true)
        }
    }

    private func protectedDisplay(_ kind: MacEntryField.Kind, _ plaintext: () -> String) -> MacEntryField.Display {
        isRevealed(kind) ? .revealed(plaintext()) : .concealed
    }

    private static func isStoredProtected(_ kind: MacEntryField.Kind, in entry: KPEntry) -> Bool {
        switch kind {
        case .password: true
        case .custom(let key): entry.protectedStringKeys.contains(key)
        default: false
        }
    }

    /// The stored string behind a text field, references unresolved.
    private static func rawValue(of kind: MacEntryField.Kind, in entry: KPEntry) -> String? {
        switch kind {
        case .username: entry.username
        case .website(0): entry.url
        case .website(let index):
            entry.additionalURLs.indices.contains(index - 1) ? entry.additionalURLs[index - 1] : nil
        case .passkeyRelyingParty: entry.passkeyCredential?.relyingParty
        case .passkeyUsername: entry.passkeyCredential?.username
        case .custom(let key): entry.customFields[key]
        case .notes: entry.notes
        case .password, .verificationCode: nil
        }
    }

    /// The value a disclosure hands over, through protected references. Only behind the gate.
    private static func secret(of kind: MacEntryField.Kind, in entry: KPEntry, session: DatabaseViewModel) -> String? {
        if kind == .password {
            return entry.hasPassword ? session.resolvedPassword(for: entry) : nil
        }
        return rawValue(of: kind, in: entry).map(session.resolvingFieldReferencesIncludingProtectedValues)
    }

    private static func feedbackField(for kind: MacEntryField.Kind) -> MacCopyFeedback.Field? {
        switch kind {
        case .username: .username
        case .password: .password
        case .website(0): .url
        case .website(let index): .additionalURL(index)
        case .verificationCode: .verificationCode
        case .passkeyRelyingParty: .passkeyRelyingParty
        case .passkeyUsername: .passkeyUsername
        case .custom(let key): .customField(key)
        case .notes: nil
        }
    }
}

/// Display text for the Mac entry detail that is not a field value.
enum MacEntryFormatting {
    /// "github.com/org/repo" for "https://github.com/org/repo/": no scheme or trailing slash. Text that
    /// is not a URL with a host stays as stored.
    static func website(_ url: String) -> String {
        guard let components = URLComponents(string: url), components.scheme != nil,
              let host = components.host, host.isEmpty == false else { return url }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = components.port.map { ":\($0)" } ?? ""
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return host + port + (path.removingPercentEncoding ?? path) + query
    }

    /// The group path from longest to shortest: whole, then the first group with
    /// fewer and fewer of the last ones ("Work › … › Frankfurt"), then "… › last".
    static func pathCandidates(_ components: [String]) -> [String] {
        guard let first = components.first, let last = components.last else { return [] }
        var candidates = [components.joined(separator: " › ")]
        if components.count >= 3 {
            for kept in stride(from: components.count - 2, through: 1, by: -1) {
                candidates.append(([first, "…"] + components.suffix(kept)).joined(separator: " › "))
            }
        }
        if components.count >= 2 {
            candidates.append("… › \(last)")
        }
        return candidates
    }

    static func modified(_ date: Date, now: Date = .now) -> String {
        String(localized: "Modified \(relative(date, now: now))")
    }

    static func created(_ date: Date) -> String {
        String(localized: "Created \(date.formatted(date: .long, time: .omitted))")
    }

    static func expiry(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return String(localized: "Never expires") }
        let distance = relative(date, now: now)
        return date <= now ? String(localized: "Expired \(distance)") : String(localized: "Expires \(distance)")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "In 4 months" beside the editor's expiry date: the relative distance as a caption of its own.
    static func expiryCaption(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
#endif
