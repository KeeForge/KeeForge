#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabasesLauncherViewModelTests: XCTestCase {
    @MainActor
    private final class Recorder {
        var references: [DatabaseReference] = []
        var openWindows: Set<UUID> = []
        var opened: [UUID] = []
        var chosen: [UUID] = []
        var cancelled = 0
        var unsaved: Set<UUID> = []
        var removed: [UUID] = []
        var unlocked: Set<UUID> = []
        var statuses: [UUID: DatabaseRowStatus] = [:]
        var lastOpened: [UUID: String] = [:]
    }

    func testOnlyLocalWebDAVAndFTPDatabasesAreListedAndOpened() throws {
        let local = try reference()
        let webDAV = try reference(provider: .webDAV)
        let ftp = try reference(provider: .ftp)
        let dropbox = try reference(provider: .dropbox)
        let oneDrive = try reference(provider: .oneDrive)
        let (recorder, launcher) = makeLauncher([local, dropbox, webDAV, oneDrive, ftp])

        XCTAssertEqual(launcher.databases.map(\.id), [local.id, webDAV.id, ftp.id])
        XCTAssertEqual(launcher.connectProviders, [.webDAV, .ftp])
        XCTAssertNil(launcher.emptyState)
        XCTAssertNil(launcher.openAction(for: dropbox))
        XCTAssertNil(launcher.openAction(for: oneDrive))
        launcher.open(dropbox)
        launcher.open(oneDrive)
        XCTAssertTrue(recorder.opened.isEmpty)

        launcher.requestConnect(.dropbox)
        XCTAssertNil(launcher.sheet)
        XCTAssertFalse(launcher.isChoosingServer)
        launcher.requestConnect(.ftp)
        XCTAssertEqual(launcher.sheet, .connect(.ftp))

        XCTAssertTrue(launcher.canConnect)
        XCTAssertEqual(launcher.connectCaption, "WebDAV, FTP")
        launcher.sheet = nil
        launcher.requestConnect()
        XCTAssertNil(launcher.sheet, "With two server types the window offers them first")
        XCTAssertTrue(launcher.isChoosingServer, "File ▸ Connect to Server… asks which server")
        launcher.requestConnect(.webDAV)
        XCTAssertFalse(launcher.isChoosingServer)
        XCTAssertEqual(launcher.sheet, .connect(.webDAV))
    }

    func testOpenOpensOrFrontsTheRowAndFollowsSelection() throws {
        let first = try reference()
        let second = try reference()
        let (recorder, launcher) = makeLauncher([first, second])
        recorder.openWindows = [second.id]

        XCTAssertEqual(launcher.openAction(for: first), .open)
        XCTAssertEqual(launcher.openAction(for: second), .front)
        launcher.openSelection()
        XCTAssertTrue(recorder.opened.isEmpty)

        launcher.selectedDatabaseID = first.id
        launcher.openSelection()
        launcher.open(second)
        XCTAssertEqual(recorder.opened, [first.id, second.id])
        XCTAssertEqual(launcher.selectedDatabaseID, second.id)

        recorder.references = [second]
        launcher.selectedDatabaseID = first.id
        XCTAssertNil(launcher.selectedDatabase, "A removed row cannot be opened")
        launcher.open(first)
        XCTAssertEqual(recorder.opened.count, 2)
    }

    /// Return, double-click and the row's Open act on the selected row only; adding a file is a separate command.
    func testOpenSelectionOpensTheSelectedRowAndPresentsNothingElse() throws {
        let first = try reference()
        let second = try reference()
        let (recorder, launcher) = makeLauncher([first, second])
        launcher.selectedDatabaseID = second.id
        launcher.openSelection()
        XCTAssertEqual(recorder.opened, [second.id])
        XCTAssertNil(launcher.sheet)
        XCTAssertNil(launcher.keyFileTarget)
        XCTAssertNil(launcher.selectionAlert)
        XCTAssertFalse(launcher.isChoosingServer)

        launcher.perform(.open, on: first)
        XCTAssertEqual(recorder.opened, [second.id, first.id])
        XCTAssertEqual(launcher.selectedDatabaseID, first.id)
        XCTAssertNil(launcher.sheet)

        launcher.requestNewDatabase()
        XCTAssertEqual(launcher.sheet, .newDatabase)
        XCTAssertEqual(recorder.opened.count, 2, "New Database never opens the selection")
    }

    func testRowsCarryStorageStateBadgesAndTheProblemOrLastOpenedLine() throws {
        var local = try reference()
        local.filename = "archive-2019.kdbx"
        local.isQuickLaunch = true
        var webDAV = try reference(provider: .webDAV)
        webDAV.filename = "work-vault.kdbx"
        webDAV.nickname = "Work Vault"
        webDAV.isReadOnly = true
        let ftp = try reference(provider: .ftp)
        let (recorder, launcher) = makeLauncher([local, webDAV, ftp])
        recorder.unlocked = [local.id]
        recorder.statuses[webDAV.id] = DatabaseRowStatus(hasStoredKey: true, hasAccessIssue: false,
            cloudState: CloudRowState(providerName: "WebDAV", isConnected: true, warningText: "Sync older than 24h",
                displayPath: "/work-vault.kdbx", accountLabel: "alex"))
        recorder.lastOpened[local.id] = "Last opened yesterday"
        recorder.lastOpened[webDAV.id] = "Last opened today"

        let rows = launcher.rows
        XCTAssertEqual(rows.map(\.id), [local.id, webDAV.id, ftp.id])
        XCTAssertEqual(rows[0].title, "archive-2019")
        XCTAssertEqual(rows[0].subtitle, "archive-2019.kdbx · \(String(localized: "On This Mac"))")
        XCTAssertEqual(rows[0].storage, .thisMac)
        XCTAssertTrue(rows[0].isUnlocked)
        XCTAssertTrue(rows[0].isQuickLaunch)
        XCTAssertFalse(rows[0].offersTouchID)
        XCTAssertEqual(rows[0].detail, .lastOpened("Last opened yesterday"))

        XCTAssertEqual(rows[1].title, "Work Vault")
        XCTAssertEqual(rows[1].subtitle, "work-vault.kdbx · WebDAV")
        XCTAssertEqual(rows[1].storage, .server)
        XCTAssertFalse(rows[1].isUnlocked, "Not unlocked reads as locked")
        XCTAssertTrue(rows[1].isReadOnly)
        XCTAssertTrue(rows[1].offersTouchID)
        XCTAssertEqual(rows[1].detail, .problem("Sync older than 24h"), "A problem replaces the last-opened line")

        XCTAssertEqual(rows[2].subtitle, "\(ftp.filename) · FTP")
        XCTAssertNil(rows[2].detail)
    }

    func testRowMenuFollowsKeyFilePendingUploadsAndToggles() throws {
        var plain = try reference()
        var keyed = try reference(provider: .webDAV)
        keyed.keyFileFilename = "vault.keyx"
        keyed.isQuickLaunch = true
        keyed.isReadOnly = true
        let dropbox = try reference(provider: .dropbox)
        plain.isQuickLaunch = false
        let (recorder, launcher) = makeLauncher([plain, keyed, dropbox])
        recorder.statuses[keyed.id] = DatabaseRowStatus(hasStoredKey: false, hasAccessIssue: false, cloudState: nil,
            pendingUploadCount: 2, pendingUploadConflictCount: 1)

        XCTAssertEqual(launcher.rowActions(for: plain), [.open, .rename, .setKeyFile, .quickLaunch(isOn: false),
            .readOnly(isOn: false), .exportCopy, .details, .remove])
        XCTAssertEqual(launcher.rowActions(for: keyed), [.open, .rename, .changeKeyFile, .clearKeyFile,
            .quickLaunch(isOn: true), .pushPendingChanges, .discardPendingUpload, .readOnly(isOn: true), .exportCopy,
            .details, .remove])
        XCTAssertEqual(launcher.rowActions(for: dropbox), [], "A database the Mac cannot open has no menu")
        XCTAssertEqual(MacDatabasesLauncherViewModel.RowAction.quickLaunch(isOn: true).accessibilityIdentifier,
                       "database-row.quick-launch-toggle")
        XCTAssertEqual(MacDatabasesLauncherViewModel.RowAction.readOnly(isOn: true).accessibilityIdentifier,
                       "database-row.read-only-toggle")
    }

    func testRowActionsRaiseTheirPresentations() throws {
        let local = try reference()
        let (recorder, launcher) = makeLauncher([local])
        launcher.perform(.rename, on: local)
        XCTAssertEqual(launcher.renameTarget?.id, local.id)
        launcher.perform(.setKeyFile, on: local)
        XCTAssertEqual(launcher.keyFileTarget?.id, local.id)
        launcher.perform(.discardPendingUpload, on: local)
        XCTAssertEqual(launcher.pendingUploadDiscardTarget?.id, local.id)
        launcher.perform(.exportCopy, on: local)
        XCTAssertEqual(launcher.exportRequest, .currentCopy(local))
        launcher.perform(.details, on: local)
        XCTAssertEqual(launcher.sheet, .details(local.id))
        launcher.perform(.remove, on: local)
        XCTAssertEqual(launcher.pendingRemoval?.id, local.id)
        XCTAssertTrue(recorder.removed.isEmpty, "Remove asks first")
    }

    func testRemoveButtonConfirmsOrRefusesAndConfirmationChecksAgain() throws {
        let dirty = try reference()
        let clean = try reference()
        let (recorder, launcher) = makeLauncher([dirty, clean])
        XCTAssertFalse(launcher.canRemoveSelection)
        launcher.removeSelection()
        XCTAssertNil(launcher.pendingRemoval)

        recorder.unsaved = [dirty.id]
        launcher.selectedDatabaseID = dirty.id
        XCTAssertTrue(launcher.canRemoveSelection)
        launcher.removeSelection()
        XCTAssertNil(launcher.pendingRemoval)
        XCTAssertEqual(launcher.refusedRemoval?.id, dirty.id, "Unsaved work refuses instead of asking")

        launcher.refusedRemoval = nil
        launcher.selectedDatabaseID = clean.id
        launcher.removeSelection()
        XCTAssertEqual(launcher.pendingRemoval?.id, clean.id)
        recorder.unsaved = [clean.id]
        launcher.confirmRemoval()
        XCTAssertNil(launcher.pendingRemoval)
        XCTAssertEqual(launcher.refusedRemoval?.id, clean.id, "Confirming checks again")
        XCTAssertTrue(recorder.removed.isEmpty)

        recorder.unsaved = []
        launcher.refusedRemoval = nil
        launcher.removeSelection()
        launcher.confirmRemoval()
        XCTAssertEqual(recorder.removed, [clean.id])
        XCTAssertNil(launcher.selectedDatabaseID, "The removed row is no longer selected")
    }

    func testFirstRunAndNoUsableDatabaseStates() throws {
        let (recorder, launcher) = makeLauncher([])
        XCTAssertEqual(launcher.emptyState, .firstRun)
        recorder.references = [try reference(provider: .dropbox)]
        XCTAssertEqual(launcher.emptyState, .noneAvailable)
        XCTAssertTrue(launcher.databases.isEmpty)
        recorder.references.append(try reference())
        XCTAssertNil(launcher.emptyState)
    }

    func testEnrollmentDestinationChoiceOnlyWhileAsked() throws {
        let local = try reference()
        let dropbox = try reference(provider: .dropbox)
        let (recorder, launcher) = makeLauncher([local, dropbox])
        launcher.chooseEnrollmentDestination(local.id)
        launcher.cancelEnrollmentDestination()
        XCTAssertTrue(recorder.chosen.isEmpty)
        XCTAssertEqual(recorder.cancelled, 0)

        launcher.isChoosingEnrollmentDestination = true
        XCTAssertEqual(launcher.enrollmentCandidates.map(\.id), [local.id])
        launcher.chooseEnrollmentDestination(dropbox.id)
        XCTAssertTrue(recorder.chosen.isEmpty)
        launcher.chooseEnrollmentDestination(local.id)
        XCTAssertEqual(recorder.chosen, [local.id])
        XCTAssertFalse(launcher.isChoosingEnrollmentDestination)

        launcher.isChoosingEnrollmentDestination = true
        launcher.cancelEnrollmentDestination()
        launcher.cancelEnrollmentDestination()
        XCTAssertEqual(recorder.cancelled, 1)
    }

    /// Removal force-retires the session, so it never runs while that session holds unsaved work.
    func testRemovalIsRefusedWhileTheDatabaseHasUnsavedWork() throws {
        let dirty = try reference()
        let clean = try reference()
        let (recorder, launcher) = makeLauncher([dirty, clean])
        recorder.unsaved = [dirty.id]

        XCTAssertFalse(launcher.requestRemoval(dirty))
        XCTAssertEqual(launcher.refusedRemoval?.id, dirty.id)
        launcher.refusedRemoval = nil
        launcher.remove(dirty)
        XCTAssertEqual(launcher.refusedRemoval?.id, dirty.id, "Confirming checks again")
        XCTAssertTrue(recorder.removed.isEmpty)

        launcher.refusedRemoval = nil
        XCTAssertTrue(launcher.requestRemoval(clean))
        launcher.remove(clean)
        XCTAssertNil(launcher.refusedRemoval)
        XCTAssertEqual(recorder.removed, [clean.id])

        recorder.unsaved = []
        launcher.remove(dirty)
        XCTAssertEqual(recorder.removed, [clean.id, dirty.id])
    }

    private func makeLauncher(_ references: [DatabaseReference]) -> (Recorder, MacDatabasesLauncherViewModel) {
        let recorder = Recorder()
        recorder.references = references
        let launcher = MacDatabasesLauncherViewModel(references: { recorder.references })
        launcher.hasWindow = { recorder.openWindows.contains($0) }
        launcher.openDatabase = { recorder.opened.append($0.id) }
        launcher.chooseEnrollmentDestinationHandler = { recorder.chosen.append($0) }
        launcher.cancelEnrollmentDestinationHandler = { recorder.cancelled += 1 }
        launcher.hasUnsavedWork = { recorder.unsaved.contains($0) }
        launcher.removeDatabase = { recorder.removed.append($0.id) }
        launcher.isUnlocked = { recorder.unlocked.contains($0) }
        launcher.status = { recorder.statuses[$0.id] ?? DatabaseRowStatus(hasStoredKey: false, hasAccessIssue: false, cloudState: nil) }
        launcher.lastOpenedDescription = { recorder.lastOpened[$0.id] }
        return (recorder, launcher)
    }

    private func reference(provider: CloudProviderKind? = nil) throws -> DatabaseReference {
        var reference = try TestDatabaseSupport.makeReference(
            for: TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self)), autoFillEnabled: false)
        if let provider {
            reference.source = .cloud(CloudSyncMetadata(provider: provider.rawValue, accountId: "account",
                fileId: "/vault.kdbx", displayPath: "/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
                remoteRev: nil, lastSyncedAt: nil, lastSyncIssue: nil))
        }
        return reference
    }
}
#endif
