#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabaseExporterTests: XCTestCase {
    private func reference(at url: URL) throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
    }

    func testRecoveryExportsPreserveEncryptedBytesAndRejectAReplacedSource() async throws {
        let source = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try reference(at: source)
        let bytes = try Data(contentsOf: source)
        let prepared = try PendingLocalSaveStore.prepareSource(bytes, for: reference.id,
            baseCacheSHA512: FileDigest.sha512(bytes))
        defer { PendingLocalSaveStore.clearAll() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        defer { try? FileManager.default.removeItem(at: destination) }
        var names: [String] = []
        let panels = MacFilePanels(presentSave: { panel, _ in
            names.append(panel.nameFieldStringValue)
            return destination
        })
        var errors: [String] = []
        let exporter = MacDatabaseExporter(panels: panels, showError: { errors.append($0) })
        await exporter.export(.localRecovery(UUID(), bytes, "Unsaved.kdbx"))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(names, ["Unsaved.kdbx"])
        await exporter.export(.pendingLocal(prepared.receipt, reference))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(try Data(contentsOf: prepared.save.fileURL), bytes)
        try FileManager.default.removeItem(at: prepared.save.fileURL)
        try bytes.write(to: prepared.save.fileURL)
        await exporter.export(.pendingLocal(prepared.receipt, reference))
        XCTAssertEqual(names.count, 2, "A stale receipt cannot reach the Save panel")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: prepared.save.fileURL), bytes)
    }

    func testCurrentCopyAndBackupWriteOnlyTheChosenFileByteForByte() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Personal.kdbx")
        let bytes = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 0, 1, 2])
        try bytes.write(to: source)
        let reference = try reference(at: source)
        let output = directory.appendingPathComponent("chosen.kdbx")
        var names: [String] = []
        let panels = MacFilePanels(presentSave: { panel, _ in
            names.append(panel.nameFieldStringValue)
            return output
        })
        var errors: [String] = []
        let exporter = MacDatabaseExporter(panels: panels) { errors.append($0) }
        await exporter.export(.currentCopy(reference))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(names, ["Personal.kdbx"])
        try FileManager.default.removeItem(at: output)
        await exporter.export(.backup(.init(url: source, createdAt: nil), reference))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(names[1].contains("backup"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["Personal.kdbx", "chosen.kdbx"])
        XCTAssertTrue(errors.isEmpty)
    }

    func testCancellationDuringLoadingCannotOpenALateSavePanel() async throws {
        let source = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try reference(at: source)
        let gate = SaveGate()
        let panels = MacFilePanels(presentSave: { _, _ in XCTFail("Cancelled read opened a Save panel"); return nil })
        let exporter = MacDatabaseExporter(panels: panels, load: { _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            return .init(data: Data([1]), suggestedFilename: "unused.kdbx")
        }, showError: { XCTFail($0) })
        let task = Task { await exporter.export(.currentCopy(reference)) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        await task.value
    }

    func testCloudCurrentCopyUsesTheCachedEncryptedBytes() async throws {
        let reference = DatabaseListStore.addCloud(provider: CloudProviderKind.webDAV.rawValue, accountId: "export-test",
            file: CloudFile(id: "/Personal.kdbx", name: "Personal.kdbx", path: "/Personal.kdbx", isFolder: false, modifiedDate: nil, size: nil))
        defer { DatabaseListStore.clearAll() }
        let bytes = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 4, 5])
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kdbx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let panels = MacFilePanels(presentSave: { _, _ in destination })
        await MacDatabaseExporter(panels: panels, showError: { XCTFail($0) }).export(.currentCopy(reference))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testCancelWritesNothingAndWriteFailureReportsOnlyTheSystemReason() async throws {
        let source = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let reference = try reference(at: source)
        let cancel = MacFilePanels(presentSave: { _, _ in nil })
        var errors: [String] = []
        let cancelled = MacDatabaseExporter(panels: cancel, write: { _, _ in XCTFail("Cancelled export wrote bytes") }, showError: { errors.append($0) })
        await cancelled.export(.currentCopy(reference))
        XCTAssertTrue(errors.isEmpty)
        let reason = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSLocalizedDescriptionKey: "System reason"])
        let panels = MacFilePanels(presentSave: { _, _ in URL(fileURLWithPath: "/unused.kdbx") })
        let failed = MacDatabaseExporter(panels: panels, write: { _, _ in throw reason }, showError: { errors.append($0) })
        await failed.export(.currentCopy(reference))
        XCTAssertEqual(errors, [reason.localizedDescription])
    }
}
#endif
