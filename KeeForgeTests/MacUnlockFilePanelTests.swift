#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import KeeForge

/// The locked window's open panels through the form model; no panel is ever shown.
@MainActor
final class MacUnlockFilePanelTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        try await super.tearDown()
    }

    func testPanelsChooseOneFileOfTheRightKind() {
        let keyFile = MacUnlockFilePanel.makePanel(for: .keyFile)
        XCTAssertEqual(keyFile.allowedContentTypes, DocumentPickerService.keyFilePickerContentTypes)
        let database = MacUnlockFilePanel.makePanel(for: .databaseFile)
        XCTAssertEqual(database.allowedContentTypes, DocumentPickerService.databasePickerContentTypes)
        for panel in [keyFile, database] {
            XCTAssertFalse(panel.allowsMultipleSelection)
            XCTAssertFalse(panel.canChooseDirectories)
            XCTAssertTrue(panel.canChooseFiles)
        }
    }

    func testTheChosenKeyFileReachesTheFormOnThePanelsWindow() async throws {
        let url = try makeFile(named: "personal.keyx", contents: Data(repeating: 3, count: 32))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var requests: [(types: [UTType], window: NSWindow?)] = []
        let panel = MacUnlockFilePanel { openPanel, window in
            requests.append((openPanel.allowedContentTypes, window))
            return url
        }
        panel.window = window
        let session = PanelSession()
        let form = MacUnlockFormModel(session: session, filePicker: panel)

        await form.chooseKeyFile()

        XCTAssertEqual(form.keyLine, .picked("personal.keyx"))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.types, DocumentPickerService.keyFilePickerContentTypes)
        XCTAssertTrue(requests.first?.window === window, "A sheet on the locked window, which holds back Touch ID")
        form.password = "secret"
        await form.submit()
        XCTAssertEqual(session.unlockedWith.last?.keyFileData, Data(repeating: 3, count: 32))
    }

    func testLocateRelinksTheChosenDatabase() async throws {
        let url = try makeFile(named: "moved.kdbx",
            contents: Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5]) + Data(repeating: 0, count: 64))
        var requested: [UTType] = []
        let panel = MacUnlockFilePanel { openPanel, _ in
            requested = openPanel.allowedContentTypes
            return url
        }
        let session = PanelSession()
        session.canRelinkDatabaseFile = true
        let form = MacUnlockFormModel(session: session, filePicker: panel)

        await form.locateDatabaseFile()

        XCTAssertEqual(requested, DocumentPickerService.databasePickerContentTypes)
        XCTAssertEqual(session.relinked, [url])
    }

    func testCancellingEitherPanelChangesNothing() async {
        var presentations = 0
        let panel = MacUnlockFilePanel { _, _ in
            presentations += 1
            return nil
        }
        let session = PanelSession()
        session.canRelinkDatabaseFile = true
        let form = MacUnlockFormModel(session: session, filePicker: panel)

        await form.chooseKeyFile()
        await form.locateDatabaseFile()

        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(form.keyLine, .none)
        XCTAssertNil(form.selectionAlert)
        XCTAssertTrue(session.relinked.isEmpty)
    }

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        files.append(directory)
        return url
    }
}

@MainActor
private final class PanelSession: MacUnlockSession {
    var state: DatabaseViewModel.State = .locked
    var biometricUnlockAvailability: DatabaseViewModel.BiometricUnlockAvailability = .none
    var canRelinkDatabaseFile = false
    private(set) var relinked: [URL] = []
    private(set) var unlockedWith: [(password: String, keyFileData: Data?)] = []

    func unlock(password: String, keyFileData: Data?) async {
        unlockedWith.append((password, keyFileData))
        state = .error(DatabaseOpenFailure(title: "Couldn't Unlock Database", summary: "Wrong key", technicalDetails: "",
            errorCode: "auth.invalid_credentials", category: .authentication, countsTowardFailedAttempts: true,
            canChooseDifferentFile: false))
    }

    func unlockWithBiometrics() async -> DatabaseViewModel.BiometricUnlockOutcome { .cancelled }
    func loadAssociatedKeyFile() async -> (data: Data, filename: String)? { nil }
    func relinkDatabaseFile(to url: URL) throws { relinked.append(url) }
    func dismissOpenFailure() { state = .locked }
}
#endif
