import Foundation

/// Which context-menu actions an entry row offers and what each does, shared by
/// the SwiftUI row menus and the Mac entry table so their gates cannot drift.
/// It hands editors and pending moves back instead of presenting them, because
/// the host differs per shell.
@MainActor
struct EntryRowActions {
    static let copyUsernameIdentifier = "entry-row.copy-username-context"
    static let copyPasswordIdentifier = "entry-row.copy-password-context"
    static let duplicateIdentifier = "entry-row.duplicate-context"
    static let restoreIdentifier = "entry-row.restore-context"
    static let moveIdentifier = "entry-row.move-context"
    static let selectIdentifier = "entry-row.select-context"
    static let deleteIdentifier = "entry-row.delete-context"
    static let deletePermanentlyIdentifier = "entry-row.delete-permanent"

    let entryID: UUID
    let session: DatabaseViewModel
    private let rowEntry: KPEntry?

    /// For a row that holds the entry value it renders; the copy gates read that value.
    init(entry: KPEntry, session: DatabaseViewModel) {
        entryID = entry.id
        self.session = session
        rowEntry = entry
    }

    init(entryID: UUID, session: DatabaseViewModel) {
        self.entryID = entryID
        self.session = session
        rowEntry = nil
    }

    private var entry: KPEntry? {
        rowEntry ?? session.entry(withID: entryID)
    }

    // MARK: - Copy

    var canCopyUsername: Bool {
        entry?.username.isEmpty == false
    }

    var canCopyPassword: Bool {
        entry?.hasPassword == true && session.sessionKey != nil
    }

    /// A username whose field references reach a protected value waits on the
    /// same gate as Copy Password; any other copies at once.
    func copyUsername(using action: EntrySecretAction, copy: @escaping @MainActor (String) -> Void) {
        guard let entry else { return }
        let session = session
        switch session.fieldReferenceResolution(of: entry.username) {
        case .resolved(let username):
            copy(username)
        case .needsProtectedValue:
            copySecret(reason: String(localized: "Copy protected field"), using: action, copy: copy) {
                session.resolvingFieldReferencesIncludingProtectedValues($0.username)
            }
        }
    }

    /// Same device-owner gate as the detail view's copy button and the macOS
    /// ⇧⌘C command: skipped only inside the authentication grace period or
    /// when the device has no protection.
    func copyPassword(using action: EntrySecretAction, copy: @escaping @MainActor (String) -> Void) {
        let session = session
        copySecret(reason: String(localized: "Copy password"), using: action, copy: copy) {
            session.resolvedPassword(for: $0)
        }
    }

    private func copySecret(
        reason: String,
        using action: EntrySecretAction,
        copy: @escaping @MainActor (String) -> Void,
        value: @escaping @MainActor (KPEntry) -> String
    ) {
        let session = session
        let entryID = entryID
        let isCurrent = EntrySecretAction.currentSession(session)
        guard isCurrent() else { return }
        let disclose: @MainActor () -> Void = {
            guard let currentEntry = session.entry(withID: entryID) else { return }
            copy(value(currentEntry))
        }
        guard session.secretAccess.requiresAuthentication else {
            disclose()
            return
        }
        action.perform(
            authenticate: {
                try await session.secretAccess.authenticate(reason: reason)
            },
            isCurrent: isCurrent,
            disclose: disclose
        )
    }

    // MARK: - Duplicate, restore, move, select

    /// Moving is an edit, so the database has to accept one; and an entry in
    /// the recycle bin comes back through the restore flow, not through a move.
    var canMove: Bool {
        session.isReadOnly == false
            && session.isEntryInRecycleBin(entryID: entryID) == false
    }

    /// Move's gate plus the session key the copy's secrets need.
    var canDuplicate: Bool {
        canMove && session.sessionKey != nil
    }

    /// Built when the item is chosen rather than per render, so the copy is
    /// seeded from the entry as it stands at that moment.
    func makeDuplicateEditor() -> EntryEditViewModel? {
        guard let sessionKey = session.sessionKey,
              let entry = session.entry(withID: entryID),
              let parentGroupID = session.parentGroupID(forEntryID: entryID) else { return nil }

        return EntryEditViewModel(
            duplicating: entry,
            sessionKey: sessionKey,
            into: parentGroupID,
            knownTags: session.tagsInDisplayOrder,
            inheritedTags: session.inheritedTags(forGroupID: parentGroupID)
        )
    }

    var canRestore: Bool {
        session.canRestore(.entry(entryID))
    }

    func restore(chooseDestination: (PendingMove) -> Void) {
        PendingMove.restoreOrChooseDestination(.entry(entryID), viewModel: session, choose: chooseDestination)
    }

    var pendingMove: PendingMove {
        .entry(entryID)
    }

    /// Moving is what a selection is for.
    var canSelect: Bool {
        canMove
    }

    func beginSelection() {
        session.workspace.beginEntrySelection(with: entryID)
    }

    // MARK: - Delete

    var canDelete: Bool {
        session.isReadOnly == false
    }

    /// Inside the Recycle Bin a delete cannot be undone.
    var deletesPermanently: Bool {
        session.isEntryInRecycleBin(entryID: entryID)
    }

    var deleteTitle: String {
        deletesPermanently ? String(localized: "Delete Permanently") : String(localized: "Delete")
    }

    var deleteAccessibilityIdentifier: String {
        deletesPermanently ? Self.deletePermanentlyIdentifier : Self.deleteIdentifier
    }

    var pendingDeletion: PendingDeletion {
        .entry(PendingEntryDeletion(entryID: entryID, sendToRecycleBin: deletesPermanently == false))
    }
}
