#if os(macOS)
import AppKit
import LocalAuthentication
import XCTest
@testable import KeeForge

@MainActor
final class MacMasterKeySheetTests: XCTestCase {
    private final class EventLog {
        var events: [String] = []
    }

    func testSaveConfirmsThenAuthenticatesThenChanges() async {
        let log = EventLog()
        let sheet = makeSheet(log: log)
        sheet.confirm = { alert, _ in
            log.events.append("confirm")
            XCTAssertEqual(alert.messageText, String(localized: "Change Master Key?"))
            return true
        }

        await sheet.save()

        XCTAssertEqual(log.events, ["confirm", "authenticate", "change"])
        XCTAssertFalse(sheet.shell.isPresented)
        XCTAssertEqual(sheet.model.newPassword, "")
        XCTAssertEqual(sheet.model.confirmPassword, "")
    }

    func testDeclinedConfirmationOrCancelledAuthenticationWritesNothing() async {
        let log = EventLog()
        let declined = makeSheet(log: log)
        declined.confirm = { _, _ in log.events.append("confirm"); return false }
        await declined.save()
        XCTAssertEqual(log.events, ["confirm"])
        XCTAssertTrue(declined.shell.isPresented)
        declined.shell.end()

        log.events = []
        let cancelled = makeSheet(log: log, authenticate: { throw LAError(.userCancel) })
        await cancelled.save()
        XCTAssertEqual(log.events, ["confirm", "authenticate"], "No change after a cancelled prompt")
        XCTAssertNil(cancelled.model.changeError)
        XCTAssertTrue(cancelled.shell.isPresented)

        let failed = makeSheet(log: log, authenticate: { throw LAError(.authenticationFailed) })
        await failed.save()
        XCTAssertEqual(log.events, ["confirm", "authenticate", "confirm", "authenticate"])
        XCTAssertEqual(failed.model.changeError, String(localized: "Authentication didn't complete. The master key was not changed."))
        XCTAssertTrue(failed.shell.isPresented)
        cancelled.shell.end()
        failed.shell.end()
    }

    func testInvalidFormIsNeverConfirmed() async {
        let log = EventLog()
        let sheet = makeSheet(log: log)
        sheet.model.confirmPassword = "different"
        await sheet.save()
        XCTAssertEqual(log.events, [])
        XCTAssertNotNil(sheet.model.validationError)
        sheet.shell.end()
    }

    func testConfirmationKeepsTheExistingTitlesAndIdentifiers() {
        let change = MacMasterKeySheet.confirmation(removingPassword: false)
        XCTAssertEqual(change.messageText, String(localized: "Change Master Key?"))
        XCTAssertEqual(change.buttons.map(\.title), [String(localized: "Change Master Key"), String(localized: "Cancel")])
        XCTAssertEqual(change.buttons.map { $0.accessibilityIdentifier() }, ["master-key.confirm-change", "master-key.cancel-change"])
        XCTAssertTrue(change.buttons[0].hasDestructiveAction)
        let removal = MacMasterKeySheet.confirmation(removingPassword: true)
        XCTAssertEqual(removal.messageText, String(localized: "Save Without a Master Password?"))
        XCTAssertEqual(removal.buttons.first?.title, String(localized: "Save Without Password"))
    }

    func testFooterPromisesAuthenticationOnlyWhenTheMacCanAuthenticate() {
        func labels(canAuthenticate: Bool) -> [String] {
            let model = MasterKeyChangeViewModel(currentKeyFileFilename: nil, currentKeyFileBookmarkData: nil,
                loadCurrentKeyFile: { nil }, changeOperation: { _, _, _, _ in })
            let sheet = MacMasterKeySheet(name: "Personal", databaseFilename: "Personal.kdbx", model: model,
                canAuthenticateDeviceOwner: canAuthenticate) { _ in false }
            defer { sheet.shell.end() }
            func collect(_ view: NSView) -> [String] {
                ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(collect)
            }
            return sheet.shell.window?.contentView.map(collect) ?? []
        }
        let promise = String(localized: "You confirm with Touch ID or your Mac password before anything changes.")
        XCTAssertTrue(labels(canAuthenticate: true).contains(promise))
        let without = labels(canAuthenticate: false)
        XCTAssertFalse(without.contains(promise))
        XCTAssertTrue(without.contains(String(localized: "Nothing changes until you confirm.")))
    }

    func testCancelAndEscapeAreDisabledWhileChangingAndEndingClearsFieldsWithoutStoppingTheWrite() async {
        let gate = SaveGate()
        var finishedWrite = false
        let model = MasterKeyChangeViewModel(currentKeyFileFilename: nil, currentKeyFileBookmarkData: nil,
            loadCurrentKeyFile: { nil }, changeOperation: { password, _, _, _ in
                XCTAssertEqual(password, "new password")
                await gate.signalStarted()
                await gate.waitUntilOpen()
                finishedWrite = true
            })
        let sheet = makeSheet(model: model)
        let save = Task { await sheet.save() }
        await gate.waitUntilStarted()
        await settle()

        XCTAssertTrue(sheet.shell.isBusy)
        XCTAssertFalse(sheet.shell.cancelButton.isEnabled)
        XCTAssertFalse(sheet.shell.defaultButton.isEnabled)
        sheet.shell.performCancel()
        sheet.shell.window?.cancelOperation(nil)
        XCTAssertTrue(sheet.shell.isPresented, "Cancel and Escape do nothing while the rekey runs")

        sheet.shell.end()
        XCTAssertTrue(sheet.hasEnded)
        XCTAssertEqual(model.newPassword, "")
        XCTAssertTrue(model.isWorking, "Ending the sheet never cancels the write")
        await gate.open()
        await save.value
        XCTAssertTrue(finishedWrite)
    }

    func testCreateKeyFileWritesToTheSavePanelURLAndSelectsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var suggested: String?
        let panels = MacFilePanels(present: { _, _ in nil }, presentSave: { panel, _ in
            suggested = panel.nameFieldStringValue
            return directory.appendingPathComponent(panel.nameFieldStringValue)
        })
        let sheet = makeSheet(panels: panels)
        sheet.createKeyFile()
        for _ in 0..<200 where sheet.model.keyFileChange != .replace { await settle() }

        XCTAssertEqual(suggested, "Personal.keyx")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Personal.keyx"])
        XCTAssertEqual(sheet.model.keyFileSummary, "Personal.keyx")
        XCTAssertEqual(sheet.model.pickedKeyFileData, try Data(contentsOf: directory.appendingPathComponent("Personal.keyx")))
        sheet.shell.end()
    }

    func testDatabaseSettingsOpensTheSheetFromTheMenuAndLockEndsBothWhileTheWriteContinues() async throws {
        let gate = SaveGate()
        let (presenter, database, state) = try await makePresenter(save: { _, _, _, _, _, _, _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            throw SaveError.saveContextUnavailable
        })
        defer { presenter.invalidate() }
        MacWorkspaceCommands(session: database, presentation: state).changeMasterKey()
        await settle()
        let settings = try XCTUnwrap(presenter.databaseSettings)
        XCTAssertEqual(settings.model.selection, .security)
        XCTAssertFalse(state.masterKeyChangeRequested)
        let child = try XCTUnwrap(settings.masterKeySheet)
        XCTAssertTrue(child.shell.isPresented)
        XCTAssertEqual(child.shell.window?.accessibilityIdentifier(), "master-key.sheet")

        child.confirm = { _, _ in true }
        child.performChange = { await $0.performConfirmedChange {} }
        child.model.newPassword = "new password"
        child.model.confirmPassword = "new password"
        let save = Task { await child.save() }
        await gate.waitUntilStarted()
        await settle()
        XCTAssertTrue(database.isSaving)
        XCTAssertTrue(child.shell.isBusy)
        XCTAssertFalse(settings.shell.defaultButton.isEnabled, "Done is disabled while the rekey runs")

        database.lockRequest(force: true)
        await settle()
        XCTAssertNil(presenter.sheet)
        XCTAssertFalse(settings.shell.isPresented)
        XCTAssertFalse(child.shell.isPresented)
        XCTAssertEqual(child.model.newPassword, "")
        XCTAssertTrue(database.isSaving, "Lock ends the sheets but not the write")

        await gate.open()
        await save.value
        XCTAssertFalse(database.isSaving)
        XCTAssertEqual(database.failedSettingsWriteCount, 1)
    }

    func testSecurityTabOpensOneChildAtATimeAndClosingSettingsEndsIt() async throws {
        let (presenter, database, state) = try await makePresenter()
        defer { presenter.invalidate(); database.lockRequest(force: true) }
        state.isShowingDatabaseDetails = true
        await settle()
        let settings = try XCTUnwrap(presenter.databaseSettings)
        settings.showMasterKey()
        let child = try XCTUnwrap(settings.masterKeySheet)
        settings.showMasterKey()
        settings.showEncryptionSettings()
        XCTAssertTrue(settings.masterKeySheet === child)
        XCTAssertNil(settings.encryptionSheet)
        child.model.newPassword = "typed"
        settings.shell.end()
        await settle()
        XCTAssertFalse(child.shell.isPresented)
        XCTAssertEqual(child.model.newPassword, "")
        XCTAssertFalse(state.isShowingDatabaseDetails)
    }

    private func makeSheet(log: EventLog = EventLog(), model: MasterKeyChangeViewModel? = nil, panels: MacFilePanels = MacFilePanels(),
                           authenticate: @escaping @MainActor () async throws -> Void = {}) -> MacMasterKeySheet {
        let model = model ?? MasterKeyChangeViewModel(currentKeyFileFilename: nil, currentKeyFileBookmarkData: nil,
            loadCurrentKeyFile: { nil }, changeOperation: { _, _, _, _ in log.events.append("change") })
        model.newPassword = "new password"
        model.confirmPassword = "new password"
        let sheet = MacMasterKeySheet(name: "Personal", databaseFilename: "Personal.kdbx", model: model, panels: panels) { model in
            await model.performConfirmedChange {
                log.events.append("authenticate")
                try await authenticate()
            }
        }
        sheet.confirm = { _, _ in log.events.append("confirm"); return true }
        sheet.shell.presentWindow = { _, _, _ in }
        sheet.shell.begin(on: NSWindow()) { _ in }
        return sheet
    }

    private func makePresenter(save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) })
        async throws -> (MacWorkspaceSheets, DatabaseViewModel, MacWorkspacePresentation) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let database = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false),
            localSaveOperation: save, quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await database.unlock(password: "testpassword123")
        let state = MacWorkspacePresentation()
        let window = NSWindow()
        let presenter = MacWorkspaceSheets(session: database, presentation: state) { window }
        presenter.present = { shell, parent, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: parent, completion: completion)
        }
        presenter.groupLockPrompt.present = { _, _, _ in }
        presenter.start()
        return (presenter, database, state)
    }

    private func settle() async { for _ in 0..<8 { await Task { @MainActor in }.value } }
}
#endif
