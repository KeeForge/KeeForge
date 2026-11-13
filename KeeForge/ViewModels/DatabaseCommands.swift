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
    private var selectedEntry: KPEntry? {
        guard isUnlocked, let session, let entryID = session.workspace.commandEntryID else { return nil }
        return session.entry(withID: entryID)
    }

    var canNewEntry: Bool { isEditable }
    var canNewGroup: Bool { isEditable }
    // The draft stays dirty until the save lands, so `isSaving` is what stops a repeated save.
    var canSave: Bool {
        isUnlocked && session?.isDirty == true && session?.isReadOnly == false && session?.isSaving == false
    }
    var canCloseDatabase: Bool { session != nil }
    var canCopyUsername: Bool { selectedEntry?.username.isEmpty == false }
    var canCopyPassword: Bool { selectedEntry?.hasPassword == true && !passwordCopyAction.isAuthenticating }
    var canCopyURL: Bool { selectedEntry?.url.isEmpty == false }
    var canCopyVerificationCode: Bool { selectedEntry?.totpConfig != nil && session?.sessionKey != nil }
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
        guard let session, let entry = selectedEntry else { return }
        ClipboardService.copy(session.resolvingFieldReferences(entry.username))
    }
    func copyPassword(activeSession: @escaping @MainActor () -> DatabaseViewModel?) {
        guard let session else { return }
        Self.copySelectedEntryPassword(in: session, action: passwordCopyAction, activeSession: activeSession)
    }
    func copyURL() {
        guard let session, let entry = selectedEntry else { return }
        ClipboardService.copy(session.resolvingFieldReferences(entry.url))
    }
    /// Not behind the device-owner gate, matching the entry detail view: the code expires on its own.
    func copyVerificationCode() {
        guard let session, let config = selectedEntry?.totpConfig, let sessionKey = session.sessionKey else { return }
        ClipboardService.copy(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
    }
    func editEntry() { session?.requestEntryEdit() }
    func deleteSelection() { session?.requestDeleteSelection() }
    func find() { session?.requestSearchFocus() }
    func lock() { session?.lockRequest(manuallyTriggered: true) }

    /// Same device-owner gate as reveal/copy in the entry detail view, skipped only inside the
    /// session's authentication grace period or when the device has no protection at all.
    @discardableResult
    static func copySelectedEntryPassword(
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        activeSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard let entryID = viewModel.workspace.commandEntryID,
              viewModel.entry(withID: entryID)?.hasPassword == true else { return nil }
        let isCurrentSession = EntrySecretAction.currentSession(viewModel)
        let secretAccess = viewModel.secretAccess
        return action.perform(
            authenticate: authenticate ?? {
                if secretAccess.requiresAuthentication {
                    try await secretAccess.authenticate(reason: String(localized: "Copy password"))
                }
            },
            isCurrent: { activeSession() === viewModel && isCurrentSession() },
            disclose: {
                guard let entry = viewModel.entry(withID: entryID) else { return }
                copy(viewModel.resolvedPassword(for: entry))
            }
        )
    }
}
