#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEntryEditorSessionTests: XCTestCase {
    func testEditModeRevealsTakeTheGateCreateModeDoesNotAndClosingConcealsEverything() async throws {
        let prompts = PromptLog(results: [false, true, false])
        let gate = SecretAccessGate(gracePeriod: { .fiveMinutes }, isAuthenticationAvailable: { true },
                                    prompt: { _ in try await prompts.next() })
        let key = SymmetricKey(size: .bits256)
        let entry = KPEntry(title: "Mail", password: try EncryptedValue.encrypt("secret", using: key))
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: key, secretAccess: gate, bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        gate.invalidate()
        let presentation = MacWorkspacePresentation()
        session.workspace.selectedEntryID = entry.id
        presentation.beginEntryEdit(entryID: entry.id, in: session)
        let editor = try XCTUnwrap(presentation.entryEditor)
        XCTAssertFalse(editor.isPasswordVisible, "An edited password opens concealed")

        editor.togglePasswordVisibility()
        await settle(editor)
        XCTAssertFalse(editor.isPasswordVisible, "A declined prompt reveals nothing")
        editor.togglePasswordVisibility()
        await settle(editor)
        XCTAssertTrue(editor.isPasswordVisible)
        let promptCount = await prompts.count
        XCTAssertEqual(promptCount, 2)
        editor.togglePasswordVisibility()
        XCTAssertFalse(editor.isPasswordVisible, "Hiding never asks")

        editor.form.addCustomField()
        let fieldID = try XCTUnwrap(editor.form.customFields.last?.id)
        editor.form.customFields[0].key = "PIN"
        editor.form.customFields[0].value = "1234"
        editor.setCustomFieldProtection(fieldID, isProtected: true)
        XCTAssertEqual(editor.form.customFields.first?.isProtected, true, "Protecting is immediate")
        gate.invalidate()
        editor.setCustomFieldProtection(fieldID, isProtected: false)
        await settle(editor)
        XCTAssertEqual(editor.form.customFields.first?.isProtected, true, "Unprotecting shows the value, so it is gated")

        editor.togglePasswordVisibility()
        await settle(editor)
        XCTAssertFalse(editor.isPasswordVisible, "After the gate was invalidated a reveal asks again")
        presentation.closeEntryEditor()
        XCTAssertFalse(editor.isPasswordVisible)
        XCTAssertFalse(editor.isTOTPSecretVisible)
        XCTAssertTrue(editor.revealedCustomFieldIDs.isEmpty)

        presentation.beginNewEntry(in: session)
        let creator = try XCTUnwrap(presentation.entryEditor)
        gate.invalidate()
        XCTAssertTrue(creator.isPasswordVisible, "A new password is typed in the open")
        creator.togglePasswordVisibility()
        creator.togglePasswordVisibility()
        XCTAssertTrue(creator.isPasswordVisible)
        let finalCount = await prompts.count
        XCTAssertEqual(finalCount, 4, "Create mode never prompts")
    }

    func testAttachmentImportsLandOnlyInTheSameLockCycleAndReportFailures() async throws {
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root"), bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()
        presentation.beginNewEntry(in: session)
        let editor = try XCTUnwrap(presentation.entryEditor)
        let file = URL(fileURLWithPath: "/nonexistent/report.txt")
        var errors: [String] = []

        await editor.importAttachments([file], load: { _, _ in
            (files: [EntryAttachmentFileLoader.LoadedFile(name: "report.txt", data: Data("report".utf8))],
             error: CocoaError(.fileReadNoPermission))
        }, onError: { errors.append($0.localizedDescription) })?.value
        XCTAssertEqual(editor.form.attachments.map(\.name), ["report.txt"], "Files read before a failure are kept")
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(editor.attachmentLoads.isLoading)
        XCTAssertNil(editor.importAttachments([], onError: { _ in }), "Nothing picked starts nothing")

        await editor.importAttachments([file], load: { _, _ in
            session.lockRequest(force: true)
            return (files: [EntryAttachmentFileLoader.LoadedFile(name: "late.txt", data: Data("late".utf8))], error: nil)
        }, onError: { _ in XCTFail("A stale import reports nothing") })?.value
        XCTAssertEqual(editor.form.attachments.map(\.name), ["report.txt"], "Nothing lands after a lock")
    }

    private func settle(_ editor: MacEntryEditorSession) async {
        for _ in 0..<200 where editor.isAuthenticating { await Task.yield() }
        await Task { @MainActor in }.value
    }
}

private actor PromptLog {
    private var results: [Bool]
    private(set) var count = 0

    init(results: [Bool]) { self.results = results }

    func next() throws {
        count += 1
        let accepted = results.isEmpty ? false : results.removeFirst()
        if accepted == false { throw CancellationError() }
    }
}
#endif
