#if os(macOS)
import CryptoKit
import KDBXXML
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

    /// The Mac editor shows no passkey or unknown-XML rows; saving through it must still keep both exactly.
    func testSavingThroughTheInlineEditorKeepsPasskeyDataAndUnknownXMLExactly() async throws {
        let key = SymmetricKey(size: .bits256)
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomData><Item><Key>Plugin</Key><Value>kept</Value></Item></CustomData>", insertionIndex: 2)
        let passkeyFields = [
            PasskeyCredential.credentialIDKey: "Y3JlZA",
            PasskeyCredential.relyingPartyKey: "github.com",
            PasskeyCredential.usernameKey: "alexrivers",
            PasskeyCredential.userHandleKey: "dXNlcg",
        ]
        let entry = KPEntry(
            title: "GitHub", username: "alice", password: try EncryptedValue.encrypt("secret", using: key),
            customFields: passkeyFields.merging(["Note": "visible"]) { $1 }, customFieldOrder: ["Note"],
            passkeyPrivateKey: try EncryptedValue.encrypt("-----BEGIN PRIVATE KEY-----", using: key),
            unknownXML: unknownXML
        )
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: key, bundle: Bundle(for: Self.self)
        )
        defer { session.lockRequest(force: true) }
        let before = try XCTUnwrap(session.entry(withID: entry.id))
        let presentation = MacWorkspacePresentation()
        session.workspace.selectedEntryID = entry.id
        presentation.beginEntryEdit(entryID: entry.id, in: session)
        let editor = try XCTUnwrap(presentation.entryEditor)

        editor.form.title = "GitHub (work)"
        editor.form.username = "alice-work"
        await editor.save().value

        XCTAssertNil(presentation.entryEditor, "The save completed")
        let saved = try XCTUnwrap(session.entry(withID: entry.id))
        XCTAssertEqual(saved.title, "GitHub (work)")
        XCTAssertEqual(saved.unknownXML, before.unknownXML)
        XCTAssertEqual(saved.customFields.filter { PasskeyCredential.allFieldKeys.contains($0.key) },
                       before.customFields.filter { PasskeyCredential.allFieldKeys.contains($0.key) })
        XCTAssertEqual(saved.customFields["Note"], "visible")
        XCTAssertEqual(try saved.passkeyPrivateKey?.decryptData(using: key),
                       try before.passkeyPrivateKey?.decryptData(using: key))
        XCTAssertEqual(saved.protectedStringKeys, before.protectedStringKeys)
        XCTAssertEqual(saved.passkeyCredential?.relyingParty, "github.com")
        XCTAssertEqual(saved.passkeyCredential?.username, "alexrivers")
        XCTAssertEqual(saved.history.first?.unknownXML, before.unknownXML, "The replaced version keeps it too")
    }

    /// The same edit saved through the real saver to a KDBX file and parsed back: the writer keeps
    /// the passkey fields, the private key and the unknown XML, in the entry and its new version.
    func testAnInlineEditorSaveWritesPasskeyDataAndUnknownXMLToTheFile() async throws {
        let bundle = Bundle(for: Self.self)
        let writeKey = SymmetricKey(size: .bits256)
        let loaded = try KDBXCompatibilitySupport.load(.aesBaseline, bundle: bundle, sessionKey: writeKey)
        var unknownXML = OpaqueXMLNodes()
        unknownXML.append(xml: "<CustomData><Item><Key>Plugin</Key><Value>kept</Value></Item></CustomData>", insertionIndex: 2)
        let passkeyFields = [
            PasskeyCredential.credentialIDKey: "Y3JlZA",
            PasskeyCredential.relyingPartyKey: "github.com",
            PasskeyCredential.usernameKey: "alexrivers",
            PasskeyCredential.userHandleKey: "dXNlcg",
        ]
        let entry = KPEntry(
            title: "GitHub", username: "alice", password: try EncryptedValue.encrypt("secret", using: writeKey),
            customFields: passkeyFields, passkeyPrivateKey: try EncryptedValue.encrypt("-----BEGIN PRIVATE KEY-----", using: writeKey),
            unknownXML: unknownXML
        )
        let root = loaded.rootGroup
        root.entries.append(entry)
        let sourceData = try KDBXWriter.write(rootGroup: root, meta: loaded.meta, compositeKey: loaded.compositeKey,
                                              header: loaded.header, sessionKey: writeKey)
        let originalKey = SymmetricKey(size: .bits256)
        let original = try XCTUnwrap(KDBXParser.parse(data: sourceData, compositeKey: loaded.compositeKey, sessionKey: originalKey)
            .allEntries.first { $0.id == entry.id })
        XCTAssertFalse(original.unknownXML.isEmpty, "The source file carries the unknown XML")
        XCTAssertNotNil(original.passkeyPrivateKey, "The source file carries the passkey")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("inline-editor-passkey.kdbx")
        try sourceData.write(to: databaseURL)
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL, autoFillEnabled: false)
        defer {
            try? FileManager.default.removeItem(at: DatabaseListStore.cacheLocation(for: reference))
            try? FileManager.default.removeItem(at: DatabaseListStore.databaseBackupDirectoryURL(for: reference))
        }
        let database = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { draft, reference, key, hash, reconciledHash, newKey, settings in
                try await LocalDatabaseSaver.save(
                    draft: draft, reference: reference, compositeKey: key, openTimeSHA512: hash,
                    reconciledRemoteSHA512: reconciledHash, kdfPolicy: .mainApp,
                    newCompositeKey: newKey, encryptionSettings: settings
                )
            },
            storedKeyPresenceCheck: { _ in false }
        )
        defer { database.lock() }
        await database.unlock(password: loaded.fixture.password)
        let presentation = MacWorkspacePresentation()
        database.workspace.selectedEntryID = entry.id
        presentation.beginEntryEdit(entryID: entry.id, in: database)
        let editor = try XCTUnwrap(presentation.entryEditor)

        editor.form.title = "GitHub (work)"
        await editor.save().value

        XCTAssertNil(presentation.entryEditor, "The save completed")
        let readKey = SymmetricKey(size: .bits256)
        let saved = try XCTUnwrap(KDBXParser.parse(data: Data(contentsOf: databaseURL), compositeKey: loaded.compositeKey,
                                                   sessionKey: readKey).allEntries.first { $0.id == entry.id })
        XCTAssertEqual(saved.title, "GitHub (work)")
        XCTAssertEqual(saved.unknownXML, original.unknownXML)
        XCTAssertEqual(saved.customFields.filter { PasskeyCredential.allFieldKeys.contains($0.key) },
                       original.customFields.filter { PasskeyCredential.allFieldKeys.contains($0.key) })
        XCTAssertEqual(try saved.passkeyPrivateKey?.decryptData(using: readKey),
                       try original.passkeyPrivateKey?.decryptData(using: originalKey))
        XCTAssertEqual(saved.protectedStringKeys, original.protectedStringKeys)
        XCTAssertEqual(saved.passkeyCredential?.relyingParty, "github.com")
        XCTAssertEqual(saved.history.first?.title, "GitHub")
        XCTAssertEqual(saved.history.first?.unknownXML, original.unknownXML, "The replaced version keeps it too")
        XCTAssertEqual(try saved.history.first?.passkeyPrivateKey?.decryptData(using: readKey),
                       try original.passkeyPrivateKey?.decryptData(using: originalKey))
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
