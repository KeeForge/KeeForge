#if os(macOS)
import Foundation

/// The menu bar quick search: what the panel shows for the focused database,
/// and the copy/open actions it offers.
///
/// It searches exactly one database, the one `focusedDatabaseID` names, and
/// never falls back to another: a locked or closed target shows its locked or
/// no-database state. It holds no entry data of its own. Everything is read
/// from the session on demand, so a lock anywhere in the app empties the panel
/// on its next render.
@MainActor
@Observable
final class MacQuickSearchViewModel {
    enum Content: Equatable {
        case noDatabase
        case locked(databaseName: String)
        case unlocked(databaseName: String)
    }

    enum CopyField: Equatable {
        case username
        case password
        case verificationCode
    }

    enum Command: Equatable {
        case moveUp
        case moveDown
        case primaryAction
        case openInKeeForge
        case copy(CopyField)
        case dismiss
    }

    /// An entry found in one database. Two open databases can hold the same
    /// entry UUID, so every action routes by `databaseID` as well.
    struct Result: Identifiable {
        struct ID: Hashable {
            let databaseID: UUID
            let entryID: UUID
        }

        let databaseID: UUID
        let entry: KPEntry

        var id: ID { ID(databaseID: databaseID, entryID: entry.id) }
    }

    typealias FocusedDatabaseProvider = @MainActor () -> UUID?
    typealias SessionResolver = @MainActor (UUID) -> DatabaseViewModel?
    typealias DeviceOwnerAuthenticator = @MainActor (_ gate: SecretAccessGate) async -> Bool
    typealias ClipboardWriter = @MainActor (String) -> Void

    /// Long lists belong in the main window; the panel is for picking one.
    static let resultLimit = 50

    var query = "" {
        didSet {
            if oldValue != query { selectedResultID = nil }
        }
    }
    /// `nil`, or an ID no current result has, means the first result.
    var selectedResultID: Result.ID?
    /// Bumped on every presentation so the view refocuses its search field.
    private(set) var presentationID = 0

    /// A value reached the clipboard; the panel should close.
    @ObservationIgnored var onCopied: (() -> Void)?
    /// The password prompt ended without a copy: it was declined, or the
    /// session locked, the target changed, or the entry changed while it was
    /// up. The prompt activated KeeForge, so the panel should close and hand
    /// focus back just as a copy does. A copy refused before the prompt
    /// changes nothing, and the panel stays open.
    @ObservationIgnored var onCopyAborted: (() -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Bring the window of this database forward; true when one showing it
    /// is now in front.
    @ObservationIgnored var onShowDatabase: ((UUID) -> Bool)?
    /// Bring KeeForge forward to choose a database, reopening its window if
    /// it was closed.
    @ObservationIgnored var onShowDatabaseList: (() -> Void)?

    /// Both read on every access, never cached, so the panel always shows the
    /// focused database as it is now.
    @ObservationIgnored var focusedDatabaseID: FocusedDatabaseProvider
    @ObservationIgnored var sessionForDatabase: SessionResolver
    @ObservationIgnored private let authenticateDeviceOwner: DeviceOwnerAuthenticator
    @ObservationIgnored private let copyToClipboard: ClipboardWriter

    init(
        focusedDatabaseID: @escaping FocusedDatabaseProvider = { nil },
        sessionForDatabase: @escaping SessionResolver = { _ in nil },
        authenticateDeviceOwner: @escaping DeviceOwnerAuthenticator = MacQuickSearchViewModel.deviceOwnerGate,
        copyToClipboard: @escaping ClipboardWriter = { ClipboardService.copy($0) }
    ) {
        self.focusedDatabaseID = focusedDatabaseID
        self.sessionForDatabase = sessionForDatabase
        self.authenticateDeviceOwner = authenticateDeviceOwner
        self.copyToClipboard = copyToClipboard
    }

    /// Same gate as the entry detail view, the row context menus and ⇧⌘C:
    /// Touch ID, the login password or Apple Watch, skipped only inside the
    /// session's authentication grace period or when the Mac has no way to
    /// authenticate its owner at all.
    static func deviceOwnerGate(_ gate: SecretAccessGate) async -> Bool {
        guard gate.requiresAuthentication else { return true }
        do {
            try await gate.authenticate(reason: String(localized: "Copy password"))
            return true
        } catch {
            return false
        }
    }

    var content: Content {
        guard let session = targetSession else { return .noDatabase }
        let name = session.databaseReference.displayName
        guard case .unlocked = session.state else { return .locked(databaseName: name) }
        return .unlocked(databaseName: name)
    }

    var results: [Result] {
        guard let session = unlockedTargetSession else { return [] }
        let databaseID = session.databaseReference.id
        return session.entries(matching: query).prefix(Self.resultLimit).map {
            Result(databaseID: databaseID, entry: $0)
        }
    }

    var selectedResult: Result? {
        let results = results
        return results.first { $0.id == selectedResultID } ?? results.first
    }

    /// Display values for a result row, read from the live target session.
    func username(for result: Result) -> String {
        sourceSession(for: result)?.resolvingFieldReferences(result.entry.username) ?? ""
    }

    func folderPath(for result: Result) -> String? {
        sourceSession(for: result)?.folderPath(forEntryID: result.entry.id)
    }

    func customIconData(for result: Result) -> Data? {
        sourceSession(for: result)?.customIconData(for: result.entry)
    }

    func canCopy(_ field: CopyField, from result: Result) -> Bool {
        guard let session = sourceSession(for: result) else { return false }
        return Self.canCopy(field, from: result.entry, in: session)
    }

    func prepareForPresentation() {
        query = ""
        selectedResultID = nil
        presentationID += 1
    }

    func perform(_ command: Command) {
        switch command {
        case .moveUp:
            moveSelection(by: -1)
        case .moveDown:
            moveSelection(by: 1)
        case .primaryAction:
            guard let result = selectedResult else {
                if unlockedTargetSession == nil { showDatabase() }
                return
            }
            let field: CopyField = canCopy(.password, from: result) ? .password : .username
            Task { await copy(field, from: result) }
        case .openInKeeForge:
            guard let result = selectedResult else { return }
            openInKeeForge(result)
        case .copy(let field):
            guard let result = selectedResult else { return }
            Task { await copy(field, from: result) }
        case .dismiss:
            onDismiss?()
        }
    }

    func moveSelection(by offset: Int) {
        let results = results
        guard results.isEmpty == false else { return }
        let current = results.firstIndex { $0.id == selectedResultID } ?? 0
        let next = min(max(current + offset, 0), results.count - 1)
        selectedResultID = results[next].id
    }

    /// Copies one field of `result` and reports whether anything reached the
    /// clipboard. Only the focused database's unlocked session may supply it.
    /// The password waits on the device-owner gate, and the target, session,
    /// and source revision are checked afterwards: they may change while the
    /// prompt is up.
    @discardableResult
    func copy(_ field: CopyField, from result: Result) async -> Bool {
        guard let source = sourceSession(for: result), Self.canCopy(field, from: result.entry, in: source) else {
            return false
        }

        let value: String?
        if Self.isGated(field, of: result.entry, in: source) {
            let lockCycleID = source.lockCycleID
            let contentRevision = source.contentRevision
            let presentationID = presentationID
            let authenticated = await authenticateDeviceOwner(source.secretAccess)
            // Authentication hides the panel and clears its query without ending the copy.
            guard self.presentationID == presentationID else { return false }
            let sourceIsCurrent = sourceSession(for: result) === source
                && source.lockCycleID == lockCycleID
                && source.contentRevision == contentRevision
            value = authenticated && sourceIsCurrent
                ? Self.currentValue(of: field, entryID: result.entry.id, in: source, isAuthorized: true) : nil
            if value == nil { onCopyAborted?() }
        } else {
            value = Self.currentValue(of: field, entryID: result.entry.id, in: source, isAuthorized: false)
        }
        guard let value else { return false }

        copyToClipboard(value)
        onCopied?()
        return true
    }

    /// Fronts the window of the result's database and selects the entry
    /// there, never in another database that holds the same entry UUID. An
    /// open editor keeps its place: moving the selection under it would hide
    /// what the user is editing.
    func openInKeeForge(_ result: Result) {
        guard onShowDatabase?(result.databaseID) == true,
              let session = sessionForDatabase(result.databaseID),
              session.databaseReference.id == result.databaseID,
              case .unlocked = session.state,
              session.hasUnsavedEditor == false
        else { return }
        session.revealEntry(result.entry.id)
    }

    /// The locked state hands off to the focused database's window, which
    /// owns unlocking it; with no open target, KeeForge chooses a database.
    func showDatabase() {
        if let databaseID = focusedDatabaseID(), sessionForDatabase(databaseID) != nil, onShowDatabase?(databaseID) == true {
            return
        }
        onShowDatabaseList?()
    }

    /// The target session when it is unlocked and is where `result` came from.
    private func sourceSession(for result: Result) -> DatabaseViewModel? {
        guard let session = unlockedTargetSession, session.databaseReference.id == result.databaseID else { return nil }
        return session
    }

    private var targetSession: DatabaseViewModel? {
        guard let databaseID = focusedDatabaseID(), let session = sessionForDatabase(databaseID),
              session.databaseReference.id == databaseID
        else { return nil }
        return session
    }

    private var unlockedTargetSession: DatabaseViewModel? {
        guard let session = targetSession, case .unlocked = session.state else { return nil }
        return session
    }

    private static func canCopy(_ field: CopyField, from entry: KPEntry, in session: DatabaseViewModel) -> Bool {
        switch field {
        case .username:
            return entry.username.isEmpty == false
        case .password:
            return entry.hasPassword && session.sessionKey != nil
        case .verificationCode:
            return entry.totpConfig != nil && session.sessionKey != nil
        }
    }

    /// The password, and a username whose field references reach a protected value.
    private static func isGated(_ field: CopyField, of entry: KPEntry, in session: DatabaseViewModel) -> Bool {
        switch field {
        case .password: true
        case .username: session.fieldReferenceResolution(of: entry.username) == .needsProtectedValue
        case .verificationCode: false
        }
    }

    /// The field as `session` has it now, or nil when it locked, the entry is
    /// gone, it no longer has a value for the field, or it needs the device-owner
    /// gate `isAuthorized` says was not passed.
    private static func currentValue(
        of field: CopyField, entryID: UUID, in session: DatabaseViewModel, isAuthorized: Bool
    ) -> String? {
        guard case .unlocked = session.state,
              let entry = session.entry(withID: entryID),
              canCopy(field, from: entry, in: session)
        else { return nil }

        let value: String
        switch field {
        case .username:
            if isAuthorized {
                value = session.resolvingFieldReferencesIncludingProtectedValues(entry.username)
            } else {
                guard let username = session.fieldReferenceResolution(of: entry.username).value else { return nil }
                value = username
            }
        case .password:
            guard isAuthorized else { return nil }
            value = session.resolvedPassword(for: entry)
        case .verificationCode:
            guard let config = entry.totpConfig, let sessionKey = session.sessionKey else { return nil }
            value = TOTPGenerator.generateCode(config: config, sessionKey: sessionKey)
        }
        return value.isEmpty ? nil : value
    }
}
#endif
