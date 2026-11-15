#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabasesSheetsTests: XCTestCase {
    func testCancelAndWindowEndClearCreationAndBothServerPasswords() async throws {
        let launcher = MacDatabasesLauncherViewModel(references: { [] })
        let window = NSWindow()
        let presenter = MacDatabasesSheets(window: window, launcher: launcher, list: DatabaseListViewModel(), present: { shell, parent, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: parent, completion: completion)
        })
        launcher.requestNewDatabase()
        await settle()
        let creation = try XCTUnwrap(presenter.creation)
        creation.password = "master"
        creation.confirmPassword = "master"
        presenter.shell?.performCancel()
        XCTAssertEqual(creation.password, "")
        XCTAssertEqual(creation.confirmPassword, "")
        XCTAssertNil(launcher.sheet)
        launcher.requestConnect()
        await settle()
        let connect = try XCTUnwrap(presenter.connect)
        XCTAssertEqual(presenter.shell?.defaultButton.accessibilityIdentifier(), "webdav.connect.submit")
        connect.serverType = .ftp
        await settle()
        XCTAssertEqual(presenter.shell?.defaultButton.accessibilityIdentifier(), "ftp.connect.submit")
        XCTAssertEqual(presenter.shell?.cancelButton.accessibilityIdentifier(), "ftp.connect.cancel")
        connect.webDAV.password = "web secret"
        connect.ftp.password = "ftp secret"
        presenter.end()
        XCTAssertEqual(connect.webDAV.password, "")
        XCTAssertEqual(connect.ftp.password, "")
        XCTAssertNil(presenter.shell)
    }

    func testABusyConnectIsNotReplacedByNewDatabaseOrAnotherConnect() async throws {
        let launcher = MacDatabasesLauncherViewModel(references: { [] })
        let window = NSWindow()
        let presenter = MacDatabasesSheets(window: window, launcher: launcher, list: DatabaseListViewModel(), present: { shell, parent, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: parent, completion: completion)
        })
        launcher.requestConnect(.webDAV)
        await settle()
        let connect = try XCTUnwrap(presenter.connect)
        let shell = try XCTUnwrap(presenter.shell)
        XCTAssertTrue(launcher.canCreateDatabase)
        shell.setBusy(true, label: "")
        XCTAssertFalse(launcher.canCreateDatabase)
        XCTAssertFalse(launcher.canRequestConnect)
        launcher.requestNewDatabase()
        launcher.requestConnect(.ftp)
        await settle()
        XCTAssertEqual(launcher.sheet, .connect(.webDAV))
        launcher.sheet = .newDatabase
        await settle()
        XCTAssertEqual(launcher.sheet, .connect(.webDAV))
        XCTAssertTrue(presenter.connect === connect)
        XCTAssertTrue(presenter.shell === shell)
        XCTAssertNil(presenter.creation)
        shell.setBusy(false, label: "")
        XCTAssertTrue(launcher.canCreateDatabase)
        presenter.end()
    }

    func testChainingFromNewDatabaseToConnectAttachesToTheWindowOnARealSheet() async throws {
        let launcher = MacDatabasesLauncherViewModel(references: { [] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let presenter = MacDatabasesSheets(window: window, launcher: launcher, list: DatabaseListViewModel())
        launcher.requestNewDatabase()
        await settle()
        let creationShell = try XCTUnwrap(presenter.shell)
        try XCTSkipUnless(window.attachedSheet != nil, "AppKit attached no sheet to a window that was never shown")
        let creation = try XCTUnwrap(presenter.creation)
        creation.databaseName = "Chained"
        creation.password = "secret"
        creation.confirmPassword = "secret"
        creation.destinationChoice = .webDAV
        creationShell.performDefault()
        await settle()
        let connectShell = try XCTUnwrap(presenter.shell)
        XCTAssertFalse(connectShell === creationShell)
        XCTAssertNotNil(presenter.connect)
        XCTAssertNil(creationShell.window?.sheetParent)
        XCTAssertTrue(window.attachedSheet === connectShell.window, "The next sheet attaches to the window, not the outgoing sheet")
        XCTAssertEqual(launcher.sheet, .newDatabase)
        presenter.end()
        window.close()
    }

    func testReconnectNativeSheetBlocksCancelWhileConnectingAndDropsLateResultOnClose() async throws {
        let connector = P8ConnectGate()
        let form = WebDAVConnectViewModel(connector: connector, expectedAccountID: nil)
        form.serverURL = "https://vault.test/"
        form.username = "alex"
        form.password = "secret"
        let prompt = MacServerCredentialPrompt()
        let window = NSWindow()
        let presenter = MacServerReconnectSheet(prompt: prompt, window: { window })
        presenter.present = { shell, parent, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: parent, completion: completion)
        }
        presenter.start()
        let result = Task { await prompt.present(.webDAV(form)) }
        await settle()
        let sheet = try XCTUnwrap(presenter.sheet)
        sheet.performDefault()
        sheet.performCancel()
        XCTAssertTrue(sheet.isPresented)
        await connector.started()
        presenter.invalidate()
        XCTAssertEqual(form.password, "")
        XCTAssertFalse(sheet.isPresented)
        let connected = await result.value
        XCTAssertFalse(connected)
        await connector.finish(fails: false)
        await settle()
        XCTAssertNil(prompt.request)
        XCTAssertNil(presenter.sheet)
        XCTAssertEqual(form.password, "")
    }

    private func settle() async {
        for _ in 0..<15 { await Task.yield() }
    }
}
#endif
