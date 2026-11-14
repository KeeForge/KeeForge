#if os(macOS)
import Foundation
import Observation

/// One open Mac entry editor: the form, the coordinator that registers its unsaved fields with
/// the session and saves them, its attachment imports and its reveal state. The window's
/// presentation (or the enrollment sheet) owns it, so a redraw of the view that shows it keeps
/// the unsaved work and the lock-prompt registration.
@MainActor @Observable
final class MacEntryEditorSession {
    let form: EntryEditViewModel
    let coordinator: DatabaseEditorCoordinator
    let attachmentLoads = AttachmentLoadCoordinator()
    /// The lock cycle it was opened in; a later cycle never shows or freezes on it.
    let lockCycleID: Int
    /// The title takes focus once, when the editor opens, never on a later redraw.
    var hasFocusedTitle = false
    private(set) var isPasswordVisible: Bool
    private(set) var isTOTPSecretVisible: Bool
    private(set) var revealedCustomFieldIDs: Set<UUID> = []

    private let secretAction = EntrySecretAction()
    private let database: DatabaseViewModel
    private let onComplete: @MainActor (EntryEditCompletion) -> Void

    var id: UUID { form.id }
    var isAuthenticating: Bool { secretAction.isAuthenticating }

    init(
        form: EntryEditViewModel,
        database: DatabaseViewModel,
        onComplete: @escaping @MainActor (EntryEditCompletion) -> Void
    ) {
        self.form = form
        self.database = database
        self.onComplete = onComplete
        coordinator = DatabaseEditorCoordinator(entry: form, database: database)
        lockCycleID = database.lockCycleID
        isPasswordVisible = form.isPasswordInitiallyVisible
        isTOTPSecretVisible = form.isPasswordInitiallyVisible
    }

    func activate() {
        coordinator.activate()
        attachmentLoads.activate()
    }

    /// Drops the registration, any import in flight and every reveal.
    func deactivate() {
        concealAll()
        attachmentLoads.deactivate()
        coordinator.deactivate()
    }

    /// Whether it still belongs to the session as it is now.
    func isCurrent(in session: DatabaseViewModel) -> Bool {
        session === database && session.state == .unlocked && session.lockCycleID == lockCycleID
    }

    var isEditingExistingEntry: Bool {
        if case .edit = form.mode { return true }
        return false
    }

    /// An edit target the database can no longer take: the entry is gone or the database turned read-only.
    var cannotSaveReason: String? {
        let isGone = if case .edit(let entryID) = form.mode { database.entry(withID: entryID) == nil } else { false }
        guard database.isReadOnly || isGone else { return nil }
        return String(localized: "This entry can no longer be edited. It may have been deleted, or the database may have been reopened read-only.")
    }

    var canSave: Bool {
        form.canSave && coordinator.isSavingInProgress == false && attachmentLoads.isLoading == false
            && cannotSaveReason == nil
    }

    var canSaveAndLock: Bool {
        form.canSave && attachmentLoads.isLoading == false
    }

    @discardableResult
    func save(resuming request: DatabaseViewModel.PendingLockRequest? = nil) -> Task<Void, Never> {
        let onComplete = onComplete
        return Task { await coordinator.save(resuming: request, onComplete: onComplete) }
    }

    func discard(resuming request: DatabaseViewModel.PendingLockRequest? = nil) {
        concealAll()
        coordinator.discard(resuming: request, onComplete: onComplete)
    }

    func completeAfterConflictIfSettled() {
        coordinator.completeAfterConflictIfSettled(onComplete: onComplete)
    }

    // MARK: - Attachments

    /// Reads the picked files off the main actor and adds what fits the database's budget; files
    /// read before a failure are kept. Nothing lands after a lock or once the editor has closed.
    @discardableResult
    func importAttachments(
        _ urls: [URL],
        load: @escaping @MainActor ([URL], Int) async -> (files: [EntryAttachmentFileLoader.LoadedFile], error: Error?) = {
            await EntryAttachmentFileLoader.load($0, maximumByteCount: $1)
        },
        onError: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never>? {
        guard urls.isEmpty == false else { return nil }
        let database = database
        let lockCycle = database.lockCycleID
        let byteBudget = form.attachmentImportByteBudget(availableByteCount: database.attachmentImportByteBudget)
        return attachmentLoads.load(
            operation: { await load(urls, byteBudget) },
            isCurrent: { database.lockCycleID == lockCycle && database.sessionKey != nil }
        ) { [weak self] loaded in
            loaded.files.forEach { self?.form.addAttachment(named: $0.name, data: $0.data) }
            if let error = loaded.error { onError(error) }
        }
    }

    // MARK: - Reveals

    /// A secret value changed under a pending prompt: the prompt no longer discloses anything.
    func secretsChanged() {
        secretAction.invalidate()
    }

    func concealAll() {
        secretAction.invalidate()
        isPasswordVisible = false
        isTOTPSecretVisible = false
        revealedCustomFieldIDs = []
    }

    func togglePasswordVisibility() {
        let password = form.password
        toggleVisibility(
            isVisible: isPasswordVisible,
            set: { [weak self] in self?.isPasswordVisible = $0 },
            reason: String(localized: "View password"),
            isCurrentSource: { [weak self] in self?.form.password == password }
        )
    }

    func toggleTOTPSecretVisibility() {
        let secret = form.totpSecret
        toggleVisibility(
            isVisible: isTOTPSecretVisible,
            set: { [weak self] in self?.isTOTPSecretVisible = $0 },
            reason: String(localized: "View verification code secret"),
            isCurrentSource: { [weak self] in self?.form.totpSecret == secret }
        )
    }

    func toggleCustomFieldVisibility(_ id: UUID) {
        guard let field = form.customFields.first(where: { $0.id == id }) else { return }
        toggleVisibility(
            isVisible: revealedCustomFieldIDs.contains(id),
            set: { [weak self] isVisible in
                if isVisible { self?.revealedCustomFieldIDs.insert(id) } else { self?.revealedCustomFieldIDs.remove(id) }
            },
            reason: String(localized: "View protected field"),
            isCurrentSource: { [weak self] in self?.form.customFields.first(where: { $0.id == id }) == field }
        )
    }

    /// Protecting is immediate; unprotecting shows the value, so it takes the reveal gate in edit mode.
    func setCustomFieldProtection(_ id: UUID, isProtected: Bool) {
        guard let field = form.customFields.first(where: { $0.id == id }), field.isProtected != isProtected else { return }
        let currentSession = EntrySecretAction.currentSession(database)
        let update: @MainActor () -> Void = { [weak self] in
            guard let self, let index = form.customFields.firstIndex(where: { $0.id == id }) else { return }
            revealedCustomFieldIDs.remove(id)
            form.customFields[index].isProtected = isProtected
        }
        guard currentSession() else { return }
        if isProtected || form.requiresAuthenticationToRevealPassword == false
            || database.secretAccess.requiresAuthentication == false {
            update()
            return
        }
        let database = database
        secretAction.perform(
            authenticate: { try await database.secretAccess.authenticate(reason: String(localized: "View protected field")) },
            isCurrent: { [weak self] in currentSession() && self?.form.customFields.first(where: { $0.id == id }) == field },
            disclose: update
        )
    }

    func removeCustomField(_ id: UUID) {
        revealedCustomFieldIDs.remove(id)
        form.removeCustomField(id: id)
    }

    /// Reveal takes the device-owner gate in edit mode; a create-mode value was typed this session.
    private func toggleVisibility(
        isVisible: Bool,
        set: @escaping @MainActor (Bool) -> Void,
        reason: String,
        isCurrentSource: @escaping @MainActor () -> Bool
    ) {
        if isVisible {
            set(false)
            return
        }
        let currentSession = EntrySecretAction.currentSession(database)
        guard secretAction.isAuthenticating == false, currentSession(), isCurrentSource() else { return }
        guard form.requiresAuthenticationToRevealPassword, database.secretAccess.requiresAuthentication else {
            set(true)
            return
        }
        let database = database
        secretAction.perform(
            authenticate: { try await database.secretAccess.authenticate(reason: reason) },
            isCurrent: { currentSession() && isCurrentSource() },
            disclose: { set(true) }
        )
    }

    // MARK: - Group

    /// "Work › Development" for a destination in `options`, which lists groups depth-first from the
    /// visible root. Like `folderPathComponents`, the path starts below that root, so the root is `[]`.
    static func groupPath(of groupID: UUID, in options: [DatabaseViewModel.MoveDestinationOption]) -> [String] {
        guard let index = options.firstIndex(where: { $0.id == groupID }), options[index].depth > 0 else { return [] }
        var path = [options[index].name]
        var depth = options[index].depth
        for option in options[..<index].reversed() where option.depth < depth && option.depth > 0 {
            path.insert(option.name, at: 0)
            depth = option.depth
        }
        return path
    }

    /// The Group row's label: the path, or the root's own name for the root.
    static func groupLabel(of groupID: UUID, in options: [DatabaseViewModel.MoveDestinationOption]) -> String {
        let path = groupPath(of: groupID, in: options)
        return path.isEmpty ? options.first { $0.id == groupID }?.name ?? "" : path.joined(separator: " › ")
    }
}
#endif
