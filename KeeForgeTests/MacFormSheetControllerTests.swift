#if os(macOS)
import AppKit
import XCTest
import SwiftUI
@testable import KeeForge

@MainActor
final class MacFormSheetControllerTests: XCTestCase {
    func testEscapeCancelsReturnConfirmsAndEndClearsCompletion() {
        for confirm in [false, true] {
            let shell = makeShell()
            var answers: [Bool] = []
            shell.begin(on: NSWindow()) { answers.append($0) }
            if confirm { shell.performDefault() } else { shell.window?.cancelOperation(nil) }
            shell.end()
            XCTAssertEqual(answers, [confirm])
            XCTAssertFalse(shell.isPresented)
        }
    }

    func testBusyDisablesEscapeAndDefaultButForcedEndStillCancels() {
        let shell = makeShell()
        var answers: [Bool] = []
        shell.begin(on: NSWindow()) { answers.append($0) }
        shell.setBusy(true, label: "Saving")
        shell.performDefault()
        shell.window?.cancelOperation(nil)
        XCTAssertTrue(answers.isEmpty)
        XCTAssertFalse(shell.cancelButton.isEnabled)
        XCTAssertFalse(shell.defaultButton.isEnabled)
        shell.end()
        XCTAssertEqual(answers, [false])
    }

    func testInitialFocusRunsOnceAndInvalidSelectionDoesNotConfirm() {
        let shell = makeShell()
        let parent = NSWindow()
        var focusCalls = 0
        shell.begin(on: parent, initialFocus: { focusCalls += 1; return nil }) { _ in }
        shell.canConfirm = false
        shell.performDefault()
        shell.isBusy = true
        shell.isBusy = false
        XCTAssertEqual(focusCalls, 1)
        XCTAssertTrue(shell.isPresented)
        shell.end()
    }

    func testEndRunsHostedCancellationOnceAndLateRegistrationCancelsImmediately() {
        let shell = makeShell()
        var cancellations = 0
        shell.cancellationScope.register { cancellations += 1 }
        shell.begin(on: NSWindow()) { _ in }
        shell.end()
        shell.end()
        XCTAssertEqual(cancellations, 1)
        shell.cancellationScope.register { cancellations += 1 }
        XCTAssertEqual(cancellations, 2)
    }

    func testEndCancelsPendingMasterKeyPreparationBeforeItCanWrite() async {
        let gate = SaveGate()
        var changes = 0
        let form = MasterKeyChangeViewModel(currentKeyFileFilename: "key.keyx", currentKeyFileBookmarkData: Data([1]),
            loadCurrentKeyFile: {
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return (Data([2]), "key.keyx")
            }, changeOperation: { _, _, _, _, _ in changes += 1 })
        form.newPassword = "new password"
        form.confirmPassword = form.newPassword
        let shell = makeShell()
        shell.cancellationScope.register { form.cancelPendingChange() }
        shell.begin(on: NSWindow()) { _ in }
        let change = Task { await form.performChange() }
        await gate.waitUntilStarted()
        shell.end()
        XCTAssertTrue(form.isCancelled)
        XCTAssertEqual(form.newPassword, "")
        XCTAssertEqual(form.confirmPassword, "")
        await gate.open()
        let succeeded = await change.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(changes, 0)
    }

    func testEndClearsMasterKeyFieldsButDoesNotCancelAWriteAlreadyStarted() async {
        let gate = SaveGate()
        var finishedWrite = false
        let form = MasterKeyChangeViewModel(currentKeyFileFilename: nil, currentKeyFileBookmarkData: nil,
            loadCurrentKeyFile: { nil }, changeOperation: { password, _, _, _, _ in
                XCTAssertEqual(password, "new password")
                await gate.signalStarted()
                await gate.waitUntilOpen()
                finishedWrite = true
            })
        form.newPassword = "new password"
        form.confirmPassword = form.newPassword
        let shell = makeShell()
        shell.cancellationScope.register { form.cancelPendingChange() }
        shell.begin(on: NSWindow()) { _ in }
        let change = Task { await form.performChange() }
        await gate.waitUntilStarted()
        shell.end()
        XCTAssertTrue(form.isWorking)
        XCTAssertEqual(form.newPassword, "")
        await gate.open()
        let succeeded = await change.value
        XCTAssertTrue(succeeded)
        XCTAssertTrue(finishedWrite)
    }

    /// Light/Dark comes from the app-wide `MacAppAppearance`, so the sheet pins none of its own.
    func testSheetCopiesParentCapturePolicyBeforePresentationAndLeavesItsAppearanceToTheApp() {
        let shell = makeShell()
        let parent = NSWindow()
        parent.sharingType = .none
        shell.presentWindow = { window, _, _ in
            XCTAssertEqual(window.sharingType, .none)
            XCTAssertNil(window.appearance)
        }
        shell.begin(on: parent) { _ in }
        shell.end()
    }

    func testDefaultActionKeepsSheetOpenForValidationAndBusyWork() {
        let shell = makeShell()
        var attempts = 0
        shell.onConfirm = { attempts += 1; shell.setBusy(true, label: "Connecting") }
        shell.begin(on: NSWindow()) { _ in }
        shell.performDefault()
        shell.performCancel()
        shell.performDefault()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(shell.isPresented)
        shell.setBusy(false, label: "")
        shell.performCancel()
        XCTAssertFalse(shell.isPresented)
        XCTAssertNil(shell.onConfirm)
    }

    func testSheetKeepsItsRequestedContentSizeUnderTheHeightCeiling() {
        let content = NSViewController()
        content.view = NSView()
        let appKit = MacFormSheetController(title: "Test", content: content, size: NSSize(width: 400, height: 800))
        XCTAssertEqual(appKit.window?.contentView?.frame.size, NSSize(width: 400, height: MacSheetMetrics.maxHeight))
        let hosted = MacFormSheetController(title: "Test", content: Text("Form"), size: NSSize(width: 740, height: 540))
        XCTAssertEqual(hosted.window?.contentView?.frame.size, NSSize(width: 740, height: min(540, MacSheetMetrics.maxHeight)))
    }

    private func makeShell() -> MacFormSheetController {
        let content = NSViewController()
        content.view = NSView()
        let shell = MacFormSheetController(title: "Test", content: content, size: NSSize(width: 400, height: 800))
        shell.presentWindow = { _, _, _ in }
        XCTAssertLessThanOrEqual(shell.window?.contentView?.frame.height ?? 0, MacSheetMetrics.maxHeight)
        return shell
    }
}
#endif
