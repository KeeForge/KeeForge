#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacPasswordImportSheetTests: XCTestCase {
    func testPickedURLLoadsOnceAndImportDiscardsPlaintextAndShowsFinishedHeading() async throws {
        let database = try await makeDatabase()
        defer { database.lockRequest(force: true) }
        let url = URL(fileURLWithPath: "/picked/Passwords.csv")
        let reads = ReadRecorder()
        let preview = try ApplePasswordsCSVImporter.preview(from: Data("Title,URL,Username,Password,Notes,OTPAuth\nImported,https://example.com,me,secret,,\n".utf8))
        let panels = MacFilePanels(present: { _, _ in url })
        let importer = MacPasswordImportSheet(session: database, presentation: MacWorkspacePresentation(), panels: panels,
            fileLoader: { picked in
                await reads.record(picked)
                return preview
            })
        importer.chooseFile()
        while importer.model.preview == nil { await Task.yield() }
        let initialReads = await reads.urls()
        XCTAssertEqual(initialReads, [url])
        importer.confirm()
        while importer.model.summary == nil { await Task.yield() }
        await settle()
        XCTAssertNil(importer.model.preview)
        XCTAssertNil(importer.model.fileName)
        let finalReads = await reads.urls()
        XCTAssertEqual(finalReads, [url], "Import uses the preview without reading or copying the CSV again")
        XCTAssertEqual(importer.shell.window?.title, String(localized: "Import Finished"))
        XCTAssertTrue(database.visibleRootGroup?.allEntries.contains(where: { $0.title == "Imported" }) == true)
        importer.discard()
    }

    func testFrozenConfirmationCannotImportAndCloseOrLockDropsThePreview() async throws {
        for lock in [false, true] {
            let database = try await makeDatabase()
            let state = MacWorkspacePresentation()
            let importer = MacPasswordImportSheet(session: database, presentation: state)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            try Data("Title,URL,Username,Password,Notes,OTPAuth\nImported,,me,secret,,\n".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            await importer.model.loadFile(at: url)
            state.beginNewEntry(in: database)
            importer.confirm()
            await settle()
            XCTAssertNil(importer.model.summary)
            XCTAssertFalse(database.visibleRootGroup?.allEntries.contains(where: { $0.title == "Imported" }) == true)
            state.closeEntryEditor()
            let window = NSWindow()
            importer.shell.presentWindow = { _, _, _ in }
            importer.shell.begin(on: window) { _ in }
            if lock { database.lockRequest(force: true); await settle() }
            else { importer.shell.performCancel() }
            XCTAssertNil(importer.model.preview)
            XCTAssertNil(importer.model.fileName)
            importer.discard()
            database.lockRequest(force: true)
        }
    }

    private func makeDatabase() async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let database = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false),
            localSaveOperation: { _, _, _, hash, _, _, _ in .saved(newSHA512: hash) },
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await database.unlock(password: "testpassword123")
        XCTAssertEqual(database.state, .unlocked)
        return database
    }

    private func settle() async { for _ in 0..<12 { await Task { @MainActor in }.value } }

    private actor ReadRecorder {
        private var picked: [URL] = []
        func record(_ url: URL) { picked.append(url) }
        func urls() -> [URL] { picked }
    }
}
#endif
