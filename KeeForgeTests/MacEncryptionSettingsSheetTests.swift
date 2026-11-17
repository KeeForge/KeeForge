#if os(macOS)
import AppKit
import KDBXKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEncryptionSettingsSheetTests: XCTestCase {
    func testCommittedWarningOffersDoneAndCannotRepeatEncryption() async {
        var writes = 0
        let sheet = makeSheet { _, _, _ in writes += 1; throw SaveDurabilityWarning() }
        sheet.model.cipher = .chacha20
        await sheet.save()
        await settle()
        XCTAssertEqual(writes, 1)
        XCTAssertNotNil(sheet.model.completedWarning)
        XCTAssertTrue(sheet.shell.isPresented)
        XCTAssertEqual(sheet.shell.defaultButton.title, String(localized: "Done"))
        XCTAssertTrue(sheet.shell.defaultButton.isEnabled)
        await sheet.save()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(sheet.shell.isPresented)
    }

    func testSaveIsDisabledUntilAChangeAndEndsTheSheetAfterTheWrite() async {
        var writes = 0
        let sheet = makeSheet { _, _, _ in writes += 1 }
        await settle()
        XCTAssertFalse(sheet.shell.defaultButton.isEnabled)
        XCTAssertEqual(sheet.shell.window?.accessibilityIdentifier(), "encryption-settings.sheet")
        XCTAssertEqual(sheet.shell.defaultButton.accessibilityIdentifier(), "encryption-settings.save")

        sheet.model.cipher = .chacha20
        await settle()
        XCTAssertTrue(sheet.shell.defaultButton.isEnabled)
        await sheet.save()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(sheet.shell.isPresented)
    }

    func testCancelIsDisabledWhileReEncryptingAndEndingCancelsTheBenchmarkButNotTheWrite() async {
        let gate = SaveGate()
        var finished = false
        let sheet = makeSheet { _, _, _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            finished = true
        }
        sheet.model.cipher = .chacha20
        let save = Task { await sheet.save() }
        await gate.waitUntilStarted()
        await settle()
        XCTAssertTrue(sheet.shell.isBusy)
        XCTAssertFalse(sheet.shell.cancelButton.isEnabled)
        sheet.shell.performCancel()
        XCTAssertTrue(sheet.shell.isPresented)

        sheet.shell.end()
        XCTAssertTrue(sheet.hasEnded)
        XCTAssertTrue(sheet.model.isWorking)
        await gate.open()
        await save.value
        XCTAssertTrue(finished)
    }

    func testClosingTheSheetCancelsARunningBenchmark() async {
        let release = DispatchSemaphore(value: 0)
        let model = EncryptionSettingsViewModel(current: summary(), measure: { _ in release.wait(); return 1 }) { _, _, _ in }
        let sheet = MacEncryptionSettingsSheet(name: "Personal", model: model)
        sheet.shell.presentWindow = { _, _, _ in }
        sheet.shell.begin(on: NSWindow()) { _ in }
        let benchmark = model.benchmark()
        XCTAssertTrue(model.isBenchmarking)
        sheet.shell.end()
        XCTAssertFalse(model.isBenchmarking)
        release.signal()
        await benchmark?.value
        XCTAssertNil(model.benchmarkSeconds)
    }

    private func makeSheet(change: @escaping EncryptionSettingsViewModel.ChangeOperation) -> MacEncryptionSettingsSheet {
        let sheet = MacEncryptionSettingsSheet(name: "Personal", model: EncryptionSettingsViewModel(current: summary(), changeOperation: change))
        sheet.shell.presentWindow = { _, _, _ in }
        sheet.shell.begin(on: NSWindow()) { _ in }
        return sheet
    }

    private func summary() -> KDBXFileSummary {
        KDBXFileSummary(formatVersion: .kdbx4(minor: 0), cipher: .aes256CBC, isCompressed: true,
                        keyDerivation: .argon2id(iterations: DatabaseCreationKDFPreset.balanced.iterations,
                                                 memoryBytes: DatabaseCreationKDFPreset.balanced.memoryBytes, parallelism: 2))
    }

    private func settle() async { for _ in 0..<8 { await Task { @MainActor in }.value } }
}
#endif
