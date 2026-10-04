#if os(macOS)
import Foundation

/// The menu bar quick search: what the panel shows for the active database
/// session, and the copy/open actions it offers.
///
/// It never holds entry data of its own. Everything is read from the session on
/// demand, so a lock anywhere in the app empties the panel on its next render.
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

    typealias SessionProvider = @MainActor () -> DatabaseViewModel?
    typealias DeviceOwnerAuthenticator = @MainActor () async -> Bool
    typealias ClipboardWriter = @MainActor (String) -> Void

    /// Long lists belong in the main window; the panel is for picking one.
    static let resultLimit = 50

    var query = "" {
        didSet {
            if oldValue != query { selectedEntryID = nil }
        }
    }
    /// `nil` means the first result.
    var selectedEntryID: UUID?
    /// Bumped on every presentation so the view refocuses its search field.
    private(set) var presentationID = 0

    /// A value reached the clipboard; the panel should close.
    @ObservationIgnored var onCopied: (() -> Void)?
    /// The password prompt ended without a copy: it was declined, or the
    /// session locked or the entry changed while it was up. The prompt
    /// activated KeeForge, so the panel should close and hand focus back just
    /// as a copy does. A copy refused before the prompt changes nothing, and
    /// the panel stays open.
    @ObservationIgnored var onCopyAborted: (() -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Bring the main window forward, reopening it if it was closed.
    @ObservationIgnored var onShowMainWindow: (() -> Void)?

    /// Read on every access, never cached, so the panel always shows the
    /// session that is active now.
    @ObservationIgnored var sessionProvider: SessionProvider
    @ObservationIgnored private let authenticateDeviceOwner: DeviceOwnerAuthenticator
    @ObservationIgnored private let copyToClipboard: ClipboardWriter

    init(
        sessionProvider: @escaping SessionProvider = { nil },
        authenticateDeviceOwner: @escaping DeviceOwnerAuthenticator = MacQuickSearchViewModel.deviceOwnerGate,
        copyToClipboard: @escaping ClipboardWriter = { ClipboardService.copy($0) }
    ) {
        self.sessionProvider = sessionProvider
        self.authenticateDeviceOwner = authenticateDeviceOwner
        self.copyToClipboard = copyToClipboard
    }

    /// Same gate as the entry detail view, the row context menus and ⇧⌘C:
    /// Touch ID, the login password or Apple Watch, skipped only when the Mac
    /// has no way to authenticate its owner at all.
    static func deviceOwnerGate() async -> Bool {
        guard BiometricService.canAuthenticateDeviceOwner else { return true }
        do {
            _ = try await BiometricService.authenticateDeviceOwner(reason: String(localized: "Copy password"))
            return true
        } catch {
            return false
        }
    }

    var content: Content {
        guard let session = sessionProvider() else { return .noDatabase }
        let name = session.databaseReference.displayName
        guard case .unlocked = session.state else { return .locked(databaseName: name) }
        return .unlocked(databaseName: name)
    }

    var results: [KPEntry] {
        guard let session = unlockedSession else { return [] }
        return Array(session.entries(matching: query).prefix(Self.resultLimit))
    }

    var selectedEntry: KPEntry? {
        let results = results
        return results.first { $0.id == selectedEntryID } ?? results.first
    }

    /// Display values for a result row, read from the live session.
    func username(for entry: KPEntry) -> String {
        unlockedSession?.resolvingFieldReferences(entry.username) ?? ""
    }

    func folderPath(for entry: KPEntry) -> String? {
        unlockedSession?.folderPath(forEntryID: entry.id)
    }

    func customIconData(for entry: KPEntry) -> Data? {
        unlockedSession?.customIconData(for: entry)
    }

    func canCopy(_ field: CopyField, from entry: KPEntry) -> Bool {
        guard let session = unlockedSession else { return false }
        switch field {
        case .username:
            return entry.username.isEmpty == false
        case .password:
            return entry.hasPassword && session.sessionKey != nil
        case .verificationCode:
            return entry.totpConfig != nil && session.sessionKey != nil
        }
    }

    func prepareForPresentation() {
        query = ""
        selectedEntryID = nil
        presentationID += 1
    }

    func perform(_ command: Command) {
        switch command {
        case .moveUp:
            moveSelection(by: -1)
        case .moveDown:
            moveSelection(by: 1)
        case .primaryAction:
            guard let entry = selectedEntry else {
                if unlockedSession == nil { showMainWindow() }
                return
            }
            let field: CopyField = canCopy(.password, from: entry) ? .password : .username
            Task { await copy(field, from: entry) }
        case .openInKeeForge:
            guard let entry = selectedEntry else { return }
            openInKeeForge(entry)
        case .copy(let field):
            guard let entry = selectedEntry else { return }
            Task { await copy(field, from: entry) }
        case .dismiss:
            onDismiss?()
        }
    }

    func moveSelection(by offset: Int) {
        let results = results
        guard results.isEmpty == false else { return }
        let current = results.firstIndex { $0.id == selectedEntryID } ?? 0
        let next = min(max(current + offset, 0), results.count - 1)
        selectedEntryID = results[next].id
    }

    /// Copies one field of `entry` and reports whether anything reached the
    /// clipboard. The password waits on the device-owner gate, and the session
    /// and source revision are checked afterwards: they may change while the
    /// prompt is up.
    @discardableResult
    func copy(_ field: CopyField, from entry: KPEntry) async -> Bool {
        guard let source = unlockedSession, canCopy(field, from: entry) else { return false }

        let value: String?
        if field == .password {
            let lockCycleID = source.lockCycleID
            let contentRevision = source.contentRevision
            let presentationID = presentationID
            let authenticated = await authenticateDeviceOwner()
            // Authentication hides the panel and clears its query without ending the copy.
            guard self.presentationID == presentationID else { return false }
            let sourceIsCurrent = unlockedSession === source
                && source.lockCycleID == lockCycleID
                && source.contentRevision == contentRevision
            value = authenticated && sourceIsCurrent ? currentValue(of: field, entryID: entry.id) : nil
            if value == nil { onCopyAborted?() }
        } else {
            value = currentValue(of: field, entryID: entry.id)
        }
        guard let value else { return false }

        copyToClipboard(value)
        onCopied?()
        return true
    }

    /// Shows the entry in the main window. An open editor keeps its place:
    /// moving the selection under it would hide what the user is editing.
    func openInKeeForge(_ entry: KPEntry) {
        if let session = unlockedSession, session.hasUnsavedEditor == false {
            session.revealEntry(entry.id)
        }
        onShowMainWindow?()
    }

    /// The locked and no-database states hand off to the main window, which
    /// owns choosing and unlocking a database.
    func showMainWindow() {
        onShowMainWindow?()
    }

    /// The field as the live session has it now, or nil when the session locked,
    /// the entry is gone, or it no longer has a value for the field.
    private func currentValue(of field: CopyField, entryID: UUID) -> String? {
        guard let session = unlockedSession,
              let entry = session.entry(withID: entryID),
              canCopy(field, from: entry)
        else { return nil }

        let value: String
        switch field {
        case .username:
            value = session.resolvingFieldReferences(entry.username)
        case .password:
            value = session.resolvedPassword(for: entry)
        case .verificationCode:
            guard let config = entry.totpConfig, let sessionKey = session.sessionKey else { return nil }
            value = TOTPGenerator.generateCode(config: config, sessionKey: sessionKey)
        }
        return value.isEmpty ? nil : value
    }

    private var unlockedSession: DatabaseViewModel? {
        guard let session = sessionProvider(), case .unlocked = session.state else { return nil }
        return session
    }
}
#endif
