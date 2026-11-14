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
        launcher.open(ids: [oneDrive.id])
        XCTAssertTrue(recorder.opened.isEmpty)

        launcher.requestConnect(.dropbox)
        XCTAssertNil(launcher.connectRequest)
        launcher.requestConnect(.ftp)
        XCTAssertEqual(launcher.connectRequest?.provider, .ftp)
        let firstRequest = launcher.connectRequest?.id
        launcher.requestConnect(.ftp)
        XCTAssertNotEqual(launcher.connectRequest?.id, firstRequest, "A repeated request is a new request")

        XCTAssertTrue(launcher.canConnect)
        let secondRequest = launcher.connectRequest?.id
        launcher.requestConnect()
        XCTAssertNotEqual(launcher.connectRequest?.id, secondRequest)
        XCTAssertNotNil(launcher.connectRequest, "File ▸ Connect to Server… asks for a request")
        XCTAssertNil(launcher.connectRequest?.provider, "With two server types the window offers them first")
    }

    func testOpenOpensOrFrontsTheRowAndFollowsSelection() throws {
        let first = try reference()
        let second = try reference()
        let (recorder, launcher) = makeLauncher([first, second])
        recorder.openWindows = [second.id]

        XCTAssertEqual(launcher.openAction(for: first), .open)
        XCTAssertEqual(launcher.openAction(for: second), .front)
        XCTAssertFalse(launcher.canOpenSelection)
        launcher.openSelection()
        XCTAssertTrue(recorder.opened.isEmpty)

        launcher.selectedDatabaseID = first.id
        XCTAssertTrue(launcher.canOpenSelection)
        launcher.openSelection()
        launcher.open(ids: [second.id])
        XCTAssertEqual(recorder.opened, [first.id, second.id])
        XCTAssertEqual(launcher.selectedDatabaseID, second.id)

        recorder.references = [second]
        launcher.selectedDatabaseID = first.id
        XCTAssertFalse(launcher.canOpenSelection, "A removed row cannot be opened")
        launcher.open(first)
        XCTAssertEqual(recorder.opened.count, 2)
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
