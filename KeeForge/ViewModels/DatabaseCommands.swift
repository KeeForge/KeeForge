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
    var canShowPasswordInLargeType: Bool { commandEntryID.map { canShowPasswordInLargeType(entryID: $0) } ?? false }
    func canCopyUsername(entryID: UUID) -> Bool { entry(withID: entryID)?.username.isEmpty == false }
    func canCopyPassword(entryID: UUID) -> Bool {
        entry(withID: entryID)?.hasPassword == true && !passwordCopyAction.isAuthenticating
    }
    func canShowPasswordInLargeType(entryID: UUID) -> Bool { canCopyPassword(entryID: entryID) }
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
        case .entries, nil: false
        }
    }

    func newEntry() { session?.requestNewEntry() }
    func newGroup() { session?.requestNewGroup() }
    @discardableResult
    func save() -> Task<Void, Never>? {
        guard let session else { return nil }
        return Task { await session.saveHandlingError() }
    }
    /// `currentSession` answers, after any authentication, which session the command's origin still shows.
    @discardableResult
    func copyUsername(
        entryID: UUID,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard let session, entry(withID: entryID) != nil else { return nil }
        return Self.copyEntryField(\.username, entryID: entryID, in: session, action: passwordCopyAction,
                                   currentSession: currentSession, authenticate: authenticate, copy: copy)
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
    @discardableResult
    func copyURL(
        entryID: UUID,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard let session, entry(withID: entryID) != nil else { return nil }
        return Self.copyEntryField(\.url, entryID: entryID, in: session, action: passwordCopyAction,
                                   currentSession: currentSession, authenticate: authenticate, copy: copy)
    }
    /// Not behind the device-owner gate, matching the entry detail view: the code expires on its own.
    func copyVerificationCode(entryID: UUID, copy: (String) -> Void = { ClipboardService.copy($0) }) {
        guard let session, let config = entry(withID: entryID)?.totpConfig, let sessionKey = session.sessionKey else {
            return
        }
        copy(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
    }
    @discardableResult
    func showPasswordInLargeType(
        entryID: UUID,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        present: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never>? {
        guard let session, isUnlocked else { return nil }
        return Self.showEntryPasswordInLargeType(entryID: entryID, in: session, action: passwordCopyAction,
                                                 currentSession: currentSession, authenticate: authenticate,
                                                 present: present)
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
        return discloseEntrySecret(entryID: entryID, in: viewModel, action: action,
                                   reason: String(localized: "Copy password"),
                                   currentSession: currentSession, authenticate: authenticate,
                                   value: { viewModel.resolvedPassword(for: $0) }, disclose: copy)
    }

    /// Large Type takes the password's reveal gate and rechecks; `present` gets the plaintext only after them.
    @discardableResult
    static func showEntryPasswordInLargeType(
        entryID: UUID,
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        present: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never>? {
        guard viewModel.entry(withID: entryID)?.hasPassword == true else { return nil }
        return discloseEntrySecret(entryID: entryID, in: viewModel, action: action,
                                   reason: String(localized: "View password"),
                                   currentSession: currentSession, authenticate: authenticate,
                                   value: { viewModel.resolvedPassword(for: $0) }, disclose: present)
    }

    /// A plain field copies at once; one whose field references reach a protected value
    /// takes the password's gate and rechecks. Nil when nothing waits on authentication.
    @discardableResult
    static func copyEntryField(
        _ field: KeyPath<KPEntry, String> & Sendable,
        entryID: UUID,
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        copyEntryValue(entryID: entryID, in: viewModel, action: action, isProtected: false,
                       raw: { $0[keyPath: field] }, currentSession: currentSession,
                       authenticate: authenticate, copy: copy)
    }

    /// `copyEntryField` for any stored string `raw` reads from the entry (an extra URL, a custom
    /// or passkey field, a history version's field). A protected field always takes the gate.
    @discardableResult
    static func copyEntryValue(
        entryID: UUID,
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        isProtected: Bool,
        raw: @escaping @MainActor (KPEntry) -> String?,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) -> Task<Void, Never>? {
        guard let entry = viewModel.entry(withID: entryID), let rawValue = raw(entry) else { return nil }
        if isProtected == false, case .resolved(let value) = viewModel.fieldReferenceResolution(of: rawValue) {
            copy(value)
            return nil
        }
        return discloseEntrySecret(entryID: entryID, in: viewModel, action: action,
                                   reason: String(localized: "Copy protected field"),
                                   currentSession: currentSession, authenticate: authenticate,
                                   value: { raw($0).map(viewModel.resolvingFieldReferencesIncludingProtectedValues) },
                                   disclose: copy)
    }

    /// The one disclosure path for a protected value: the session's device-owner gate, then the
    /// origin's session, lock cycle, content and selection, then `isCurrent`, all rechecked after
    /// authentication. `value` reads the entry as it is then; nil discloses nothing.
    @discardableResult
    static func discloseEntrySecret(
        entryID: UUID,
        in viewModel: DatabaseViewModel,
        action: EntrySecretAction,
        reason: String,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        authenticate: (@MainActor () async throws -> Void)? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        value: @escaping @MainActor (KPEntry) -> String?,
        disclose: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never>? {
        let isCurrentSession = EntrySecretAction.currentSession(viewModel)
        let secretAccess = viewModel.secretAccess
        return action.perform(
            authenticate: authenticate ?? {
                if secretAccess.requiresAuthentication {
                    try await secretAccess.authenticate(reason: reason)
                }
            },
            isCurrent: { currentSession() === viewModel && isCurrentSession() && isCurrent() },
            disclose: {
                guard let entry = viewModel.entry(withID: entryID), let secret = value(entry) else { return }
                disclose(secret)
            }
        )
    }
}
