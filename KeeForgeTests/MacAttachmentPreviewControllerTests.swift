#if os(macOS)
import AppKit
import CryptoKit
import Quartz
import XCTest
@testable import KeeForge

@MainActor
final class MacAttachmentPreviewControllerTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testThePanelShowsThePreviewAndEndingControlRemovesTheFile() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let panel = RecordingPreviewPanel()
        let controller = makeController(session, panel: panel)
        XCTAssertFalse(controller.acceptsPreviewPanelControl(nil), "Nothing to preview, so another window keeps the panel")

        await controller.preview(attachmentAt: 0, ofEntry: entry.id)?.value
        await settle()
        let url = try XCTUnwrap(controller.previews.previewURL)
        XCTAssertEqual(panel.shown, 1)
        XCTAssertTrue(controller.isPreviewing(entryID: entry.id, attachmentIndex: 0))
        XCTAssertTrue(controller.acceptsPreviewPanelControl(nil))
        controller.beginPreviewPanelControl(nil)
        XCTAssertTrue(controller.isControllingPanel)
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 1)
        XCTAssertEqual(controller.previewPanel(nil, previewItemAt: 0)?.previewItemURL, url)

        controller.endPreviewPanelControl(nil)
        XCTAssertFalse(controller.isControllingPanel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.previews.state, .idle)
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 0)
    }

    func testSpaceTogglesThePreviewFromTheRowAndFromThePanel() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController(session)

        await controller.togglePreview(attachmentAt: 0, ofEntry: entry.id)?.value
        let url = try XCTUnwrap(controller.previews.previewURL)
        XCTAssertNil(controller.togglePreview(attachmentAt: 0, ofEntry: entry.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        await controller.togglePreview(attachmentAt: 0, ofEntry: entry.id)?.value
        let second = try XCTUnwrap(controller.previews.previewURL)
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        XCTAssertTrue(controller.previewPanel(nil, handle: space))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testAnotherEntryLockAndWindowCloseCloseThePanelAndTheFile() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let panel = RecordingPreviewPanel()
        let controller = makeController(session, panel: panel)

        await controller.preview(attachmentAt: 0, ofEntry: entry.id)?.value
        await settle()
        var url = try XCTUnwrap(controller.previews.previewURL)
        var closes = panel.closed
        session.workspace.selectedEntryID = UUID()
        await settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(panel.closed, closes, "Selecting another entry closes the panel")

        session.workspace.selectedEntryID = entry.id
        await controller.preview(attachmentAt: 0, ofEntry: entry.id)?.value
        await settle()
        url = try XCTUnwrap(controller.previews.previewURL)
        closes = panel.closed
        controller.windowClosed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(panel.closed, closes)
        XCTAssertNil(controller.preview(attachmentAt: 0, ofEntry: entry.id), "Nothing is written after the window closes")

        let other = makeController(session, panel: panel)
        await other.preview(attachmentAt: 0, ofEntry: entry.id)?.value
        await settle()
        url = try XCTUnwrap(other.previews.previewURL)
        closes = panel.closed
        session.lockRequest(force: true)
        await settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(other.previews.state, .idle)
        XCTAssertGreaterThan(panel.closed, closes, "Lock closes the panel")
    }

    func testShareOpensThePickerOnceAndTheShareEndingRemovesTheFile() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        var presented: [(URL, NSView)] = []
        let controller = MacAttachmentPreviewController(
            database: session,
            previews: AttachmentPreviewSession(currentSession: { session }),
            panel: RecordingPreviewPanel(),
            presentSharePicker: { url, anchor, _ in presented.append((url, anchor)) }
        )
        let anchor = NSView()
        let picker = NSSharingServicePicker(items: [])

        await controller.share(attachmentAt: 0, ofEntry: entry.id, from: anchor)?.value
        await settle()
        var url = try XCTUnwrap(controller.previews.shareURL)
        XCTAssertEqual(presented.map(\.0), [url])
        XCTAssertTrue(presented.first?.1 === anchor, "The picker opens from the row's Share button")
        await settle()
        XCTAssertEqual(presented.count, 1, "One picker per share")
        controller.sharingServicePicker(picker, didChoose: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Cancelling the picker removes the file")

        let service = NSSharingService(title: "Test", image: NSImage(), alternateImage: nil) {}
        await controller.share(attachmentAt: 0, ofEntry: entry.id, from: anchor)?.value
        await settle()
        url = try XCTUnwrap(controller.previews.shareURL)
        XCTAssertTrue(controller.sharingServicePicker(picker, delegateFor: service) === controller)
        controller.sharingServicePicker(picker, didChoose: service)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The chosen service still needs the file")
        controller.sharingService(service, didShareItems: [url])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        await controller.share(attachmentAt: 0, ofEntry: entry.id, from: anchor)?.value
        await settle()
        url = try XCTUnwrap(controller.previews.shareURL)
        controller.sharingService(service, didFailToShareItems: [url], error: CocoaError(.userCancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.previews.state, .idle)
    }

    func testInstallPutsTheControllerRightAfterTheWindowInItsResponderChain() async throws {
        let (session, _) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let controller = makeController(session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let windowController = NSWindowController(window: window)
        let next = window.nextResponder

        controller.install(in: window)
        controller.install(in: window)

        XCTAssertTrue(window.nextResponder === controller)
        XCTAssertTrue(controller.nextResponder === next)
        XCTAssertTrue(next === windowController || next == nil)
    }

    // MARK: - Helpers

    private func makeController(
        _ session: DatabaseViewModel, panel: RecordingPreviewPanel = RecordingPreviewPanel()
    ) -> MacAttachmentPreviewController {
        MacAttachmentPreviewController(database: session, previews: AttachmentPreviewSession(currentSession: { session }),
                                       panel: panel, presentSharePicker: { _, _, _ in })
    }

    /// The controller observes on the next main-actor turn.
    private func settle() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    private func makeSession() async throws -> (DatabaseViewModel, KPEntry) {
        let entry = KPEntry(title: "Files", attachments: [KPAttachment(name: "report.txt", ref: 0)])
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: key,
            binaryPool: BinaryPool(rawFields: [Data([0]) + Data("report".utf8)]), bundle: Bundle(for: Self.self)
        )
        session.workspace.selectedEntryID = entry.id
        return (session, entry)
    }
}

@MainActor
final class RecordingPreviewPanel: MacPreviewPanelPresenting {
    private(set) var shown = 0
    private(set) var reloaded = 0
    private(set) var closed = 0

    func show() { shown += 1 }
    func reload() { reloaded += 1 }
    func close(controlledBy controller: AnyObject) { closed += 1 }
}

extension MacAttachmentPreviewController {
    /// A controller whose panel and share picker are never shown.
    static func unshown(_ database: DatabaseViewModel) -> MacAttachmentPreviewController {
        MacAttachmentPreviewController(database: database,
                                       previews: AttachmentPreviewSession(currentSession: { database }),
                                       panel: RecordingPreviewPanel(), presentSharePicker: { _, _, _ in })
    }
}
#endif
