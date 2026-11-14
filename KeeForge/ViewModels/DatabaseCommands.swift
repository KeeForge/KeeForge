import Foundation

@MainActor
struct DatabaseCommands {
    let session: DatabaseViewModel?
    let passwordCopyAction: EntrySecretAction

    init(session: DatabaseViewModel?, passwordCopyAction: EntrySecretAction = EntrySecretAction()) {
        self.session = session
        self.passwordCopyAction = passwordCopyAction
    }

    var isUnlocked: Bool { session?.state == .unlocked }
    private var isEditable: Bool { isUnlocked && session?.isReadOnly == false }
    private func entry(withID entryID: UUID) -> KPEntry? {
        guard isUnlocked else { return nil }
        return session?.entry(withID: entryID)
    }
    private var commandEntryID: UUID? {
        session?.workspace.commandEntryID
    }

    var canNewEntry: Bool { isEditable }
    var canNewGroup: Bool { isEditable }
    // The draft stays dirty until the save lands, so `isSaving` is what stops a repeated save.
    var canSave: Bool {
        isUnlocked && session?.isDirty == true && session?.isReadOnly == false && session?.isSaving == false
    }
    var canCloseDatabase: Bool { session != nil }
    var canCopyUsername: Bool { commandEntryID.map { canCopyUsername(entryID: $0) } ?? false }
    var canCopyPassword: Bool { commandEntryID.map { canCopyPassword(entryID: $0) } ?? false }
    var canCopyURL: Bool { commandEntryID.map { canCopyURL(entryID: $0) } ?? false }
    var canCopyVerificationCode: Bool { commandEntryID.map { canCopyVerificationCode(entryID: $0) } ?? false }
    func canCopyUsername(entryID: UUID) -> Bool { entry(withID: entryID)?.username.isEmpty == false }
    func canCopyPassword(entryID: UUID) -> Bool {
        entry(withID: entryID)?.hasPassword == true && !passwordCopyAction.isAuthenticating
    }
    func canCopyURL(entryID: UUID) -> Bool { entry(withID: entryID)?.url.isEmpty == false }
    func canCopyVerificationCode(entryID: UUID) -> Bool {
        entry(withID: entryID)?.totpConfig != nil && session?.sessionKey != nil
    }
    var canEditEntry: Bool { session?.canEditSelectedEntry == true }
    var canDelete: Bool { session?.deletableSelection != nil }
    var canFind: Bool { isUnlocked }
    var canLock: Bool { isUnlocked }

    /// Mirrors the row context menus: a permanent delete has to say so in the menu bar too.
    var deletesPermanently: Bool {
        guard let session else { return false }
        return switch session.deletableSelection {
        case .entry(let id): session.isEntryInRecycleBin(entryID: id)
        case .group(let id): session.isGroupInRecycleBin(groupID: id)
        case nil: false
        }
    }

    func newEntry() { session?.requestNewEntry() }
    func newGroup() { session?.requestNewGroup() }
    @discardableResult
    func save() -> Task<Void, Never>? {
        guard let session else { return nil }
        return Task { await session.saveHandlingError() }
    }
    func copyUsername() {
        guard let entryID = commandEntryID else { return }
        copyUsername(entryID: entryID)
    }
    func copyUsername(entryID: UUID, copy: (String) -> Void = { ClipboardService.copy($0) }) {
        guard let session, let entry = entry(withID: entryID) else { return }
        copy(session.resolvingFieldReferences(entry.username))
    }
    /// `currentSession` answers, after authentication, which session the command's origin still shows.
    func copyPassword(currentSession: @escaping @MainActor () -> DatabaseViewModel?) {
        guard let session, let entryID = commandEntryID else { return }
        Self.copyEntryPassword(entryID: entryID, in: session, action: passwordCopyAction, currentSession: currentSession)
    }
    @discardableResult
    func copyPassword(
        entryID: UUID,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard let session, isUnlocked else { return nil }
        return Self.copyEntryPassword(entryID: entryID, in: session, action: passwordCopyAction,
                                      currentSession: currentSession, authenticate: authenticate, copy: copy)
    }
    func copyURL() {
        guard let entryID = commandEntryID else { return }
        copyURL(entryID: entryID)
    }
    func copyURL(entryID: UUID, copy: (String) -> Void = { ClipboardService.copy($0) }) {
        guard let session, let entry = entry(withID: entryID) else { return }
        copy(session.resolvingFieldReferences(entry.url))
    }
    func copyVerificationCode() {
        guard let entryID = commandEntryID else { return }
        copyVerificationCode(entryID: entryID)
    }
    /// Not behind the device-owner gate, matching the entry detail view: the code expires on its own.
    func copyVerificationCode(entryID: UUID, copy: (String) -> Void = { ClipboardService.copy($0) }) {
        guard let session, let config = entry(withID: entryID)?.totpConfig, let sessionKey = session.sessionKey else {
            return
        }
        copy(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
    }
    func editEntry() { session?.requestEntryEdit() }
    func deleteSelection() { session?.requestDeleteSelection() }
    func lock() { session?.lockRequest(manuallyTriggered: true) }

    /// Same device-owner gate as reveal/copy in the entry detail view, skipped only inside the
    /// session's authentication grace period or when the device has no protection at all. The
    /// disclosure also needs the lock cycle, content and selection the request started from.
    @discardableResult
    static func copyEntryPassword(
        entryID: UUID,
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard viewModel.entry(withID: entryID)?.hasPassword == true else { return nil }
        let isCurrentSession = EntrySecretAction.currentSession(viewModel)
        let secretAccess = viewModel.secretAccess
        return action.perform(
            authenticate: authenticate ?? {
                if secretAccess.requiresAuthentication {
                    try await secretAccess.authenticate(reason: String(localized: "Copy password"))
                }
            },
            isCurrent: { currentSession() === viewModel && isCurrentSession() },
            disclose: {
                guard let entry = viewModel.entry(withID: entryID) else { return }
                copy(viewModel.resolvedPassword(for: entry))
            }
        )
    }
}
