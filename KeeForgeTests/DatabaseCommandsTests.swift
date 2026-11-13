import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseCommandsTests: XCTestCase {
    func testEnablementWithoutSessionAndWhileLocked() throws {
        assertEnablement(DatabaseCommands(session: nil), unlocked: false, writable: false, hasSession: false)
        let session = try makeSession()
        assertEnablement(DatabaseCommands(session: session), unlocked: false, writable: false)
        let commands = DatabaseCommands(session: session)
        commands.newEntry()
        commands.newGroup()
        commands.find()
        commands.editEntry()
        commands.deleteSelection()
        assertRequests(session, expected: 0)
        XCTAssertFalse(commands.deletesPermanently)
    }

    func testUnlockedWritableAndReadOnlyEnablementAndRequests() async throws {
        for readOnly in [false, true] {
            let session = try makeSession(readOnly: readOnly)
            await session.unlock(password: "testpassword123")
            defer { session.lockRequest(force: true) }
            XCTAssertEqual(session.state, .unlocked)
            session.workspace.selectedEntryID = nil
            session.workspace.selectedGroupID = nil
            let commands = DatabaseCommands(session: session)
            assertEnablement(commands, unlocked: true, writable: !readOnly)
            commands.newEntry()
            commands.newGroup()
            commands.find()
            commands.editEntry()
            commands.deleteSelection()
            XCTAssertEqual(session.workspace.newEntryRequestID, readOnly ? 0 : 1)
            XCTAssertEqual(session.workspace.newGroupRequestID, readOnly ? 0 : 1)
            XCTAssertEqual(session.workspace.searchFocusRequestID, 1)
            XCTAssertEqual(session.workspace.editEntryRequestID, 0)
            XCTAssertEqual(session.workspace.deleteSelectionRequestID, 0)

            session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first).id
            XCTAssertEqual(commands.canEditEntry, !readOnly)
            XCTAssertEqual(commands.canDelete, !readOnly)
            commands.editEntry()
            commands.deleteSelection()
            XCTAssertEqual(session.workspace.editEntryRequestID, readOnly ? 0 : 1)
            XCTAssertEqual(session.workspace.deleteSelectionRequestID, readOnly ? 0 : 1)
        }
    }

    func testCopyEnablementFollowsFieldsAndBulkSelectionEvenWhenReadOnly() async throws {
        let key = SymmetricKey(size: .bits256)
        let entries = [
            KPEntry(title: "Empty"),
            KPEntry(title: "Username", username: "user"),
            KPEntry(title: "Password", password: try EncryptedValue.encrypt("secret", using: key)),
            KPEntry(title: "URL", url: "https://example.com"),
            KPEntry(title: "Code", totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: key))),
        ]
        let root = KPGroup(name: "Root", entries: entries)
        for readOnly in [false, true] {
            let session = try makeSession(readOnly: readOnly, root: root, key: key)
            await session.unlock(password: "testpassword123")
            try await session.reloadDiscardingDraft()
            defer { session.lockRequest(force: true) }
            let action = EntrySecretAction()
            let commands = DatabaseCommands(session: session, passwordCopyAction: action)
            for (index, entry) in entries.enumerated() {
                session.workspace.selectedEntryID = entry.id
                XCTAssertEqual(commands.canCopyUsername, index == 1)
                XCTAssertEqual(commands.canCopyPassword, index == 2)
                XCTAssertEqual(commands.canCopyURL, index == 3)
                XCTAssertEqual(commands.canCopyVerificationCode, index == 4)
            }
            session.workspace.selectedEntryID = entries[2].id
            let task = try XCTUnwrap(action.perform(authenticate: {}, isCurrent: { true }, disclose: {}))
            XCTAssertFalse(commands.canCopyPassword)
            await task.value
            XCTAssertTrue(commands.canCopyPassword)
            session.workspace.beginEntrySelection(with: entries[2].id)
            XCTAssertFalse(commands.canCopyUsername)
            XCTAssertFalse(commands.canCopyPassword)
            XCTAssertFalse(commands.canCopyURL)
            XCTAssertFalse(commands.canCopyVerificationCode)
            XCTAssertFalse(commands.canEditEntry)
            XCTAssertFalse(commands.canDelete)
        }
    }

    func testDeleteVariantForActiveAndRecycledEntriesAndGroups() async throws {
        let activeEntry = KPEntry(title: "Active")
        let recycledEntry = KPEntry(title: "Recycled")
        let activeGroup = KPGroup(name: "Active", entries: [activeEntry])
        let recycledGroup = KPGroup(name: "Recycled", entries: [recycledEntry])
        let bin = KPGroup(name: "Recycle Bin", groups: [recycledGroup])
        let root = KPGroup(name: "Root", groups: [activeGroup, bin], recycleBinUUID: bin.id)
        let session = try makeSession(root: root)
        await session.unlock(password: "testpassword123")
        try await session.reloadDiscardingDraft()
        defer { session.lockRequest(force: true) }
        let commands = DatabaseCommands(session: session)
        for (group, entry, permanent) in [(activeGroup, activeEntry, false), (recycledGroup, recycledEntry, true)] {
            session.workspace.selectedGroupID = group.id
            XCTAssertTrue(commands.canDelete)
            XCTAssertEqual(commands.deletesPermanently, permanent)
            session.workspace.selectedEntryID = entry.id
            XCTAssertTrue(commands.canDelete)
            XCTAssertEqual(commands.deletesPermanently, permanent)
            let revision = session.contentRevision
            commands.deleteSelection()
            XCTAssertNotNil(session.entry(withID: entry.id), "Delete must request confirmation before mutation")
            XCTAssertEqual(session.contentRevision, revision)
        }
        XCTAssertEqual(session.workspace.deleteSelectionRequestID, 2)
    }

    func testManualLockLocksAndClearsCommandAvailability() async throws {
        let session = try makeSession()
        await session.unlock(password: "testpassword123")
        let commands = DatabaseCommands(session: session)
        commands.lock()
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.didManuallyLock)
        XCTAssertNil(session.sessionKey)
        assertEnablement(commands, unlocked: false, writable: false)
    }

    func testSaveRequiresDirtyWritableIdleSessionAndHandlesFailure() async throws {
        let gate = SaveGate()
        let session = try makeSession(save: { _, _, _, _, _, _, _ in
            await gate.suspend()
            throw CocoaError(.fileWriteNoPermission)
        })
        await session.unlock(password: "testpassword123")
        defer { session.lockRequest(force: true) }
        let commands = DatabaseCommands(session: session)
        XCTAssertFalse(commands.canSave)
        try session.applyEntryEdit(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: try XCTUnwrap(session.rootGroup)),
            draft: EntryDraftPayload(title: "Unsaved", password: "secret")
        ))
        XCTAssertTrue(commands.canSave)
        let readOnly = try makeSession(readOnly: true)
        await readOnly.unlock(password: "testpassword123")
        defer { readOnly.lockRequest(force: true) }
        readOnly.draft = try DatabaseDraft(
            rootGroup: XCTUnwrap(readOnly.rootGroup), meta: KPMeta(), sessionKey: XCTUnwrap(readOnly.sessionKey)
        ).apply(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: try XCTUnwrap(readOnly.rootGroup)),
            draft: EntryDraftPayload(title: "Retained draft", password: "secret")
        ))
        XCTAssertTrue(readOnly.isDirty)
        XCTAssertFalse(DatabaseCommands(session: readOnly).canSave)
        let task = try XCTUnwrap(commands.save())
        await gate.waitUntilStarted()
        XCTAssertTrue(session.isSaving)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(commands.canSave)
        await gate.release()
        await task.value
        XCTAssertNotNil(session.saveError)
        XCTAssertTrue(commands.canSave)
    }

    private func assertEnablement(
        _ commands: DatabaseCommands, unlocked: Bool, writable: Bool, hasSession: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(commands.canNewEntry, writable, file: file, line: line)
        XCTAssertEqual(commands.canNewGroup, writable, file: file, line: line)
        XCTAssertFalse(commands.canSave, file: file, line: line)
        XCTAssertEqual(commands.canCloseDatabase, hasSession, file: file, line: line)
        XCTAssertFalse(commands.canCopyUsername, file: file, line: line)
        XCTAssertFalse(commands.canCopyPassword, file: file, line: line)
        XCTAssertFalse(commands.canCopyURL, file: file, line: line)
        XCTAssertFalse(commands.canCopyVerificationCode, file: file, line: line)
        XCTAssertFalse(commands.canEditEntry, file: file, line: line)
        XCTAssertFalse(commands.canDelete, file: file, line: line)
        XCTAssertEqual(commands.canFind, unlocked, file: file, line: line)
        XCTAssertEqual(commands.canLock, unlocked, file: file, line: line)
    }

    private func assertRequests(_ session: DatabaseViewModel, expected: Int) {
        XCTAssertEqual(session.workspace.newEntryRequestID, expected)
        XCTAssertEqual(session.workspace.newGroupRequestID, expected)
        XCTAssertEqual(session.workspace.searchFocusRequestID, expected)
        XCTAssertEqual(session.workspace.editEntryRequestID, expected)
        XCTAssertEqual(session.workspace.deleteSelectionRequestID, expected)
    }

    private func makeSession(
        readOnly: Bool = false,
        root: KPGroup = KPGroup(name: "Root"),
        key: SymmetricKey = SymmetricKey(size: .bits256),
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) }
    ) throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        var reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        reference.isReadOnly = readOnly
        return DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference, rootGroup: root,
                    meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
                    formatVersion: .kdbx4(minor: 1), sessionKey: key,
                    openTimeSHA512: Data("command-tree".utf8), binaryPool: BinaryPool(rawFields: [])
                )
            },
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false }
        )
    }

    private actor SaveGate {
        private var completion: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation {
                completion = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            guard completion == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() {
            completion?.resume()
            completion = nil
        }
    }
}
