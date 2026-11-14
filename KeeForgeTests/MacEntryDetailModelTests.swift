#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class MacEntryDetailModelTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testFieldsComeInBoardOrderWithKindsLabelsAndPlainOrConcealedValues() async throws {
        let entry = try fullEntry()
        let session = try await makeSession(entries: [entry])
        defer { session.lockRequest(force: true) }
        let model = makeModel(.live(entry.id), session: session)
        model.appeared()

        XCTAssertEqual(model.fields.map(\.kind), [
            .username, .password, .website(0), .website(1), .verificationCode,
            .passkeyRelyingParty, .passkeyUsername, .custom("Hostname"), .custom("Deploy Token"), .notes,
        ])
        XCTAssertEqual(model.fields.map(\.label), [
            String(localized: "Username"), String(localized: "Password"), String(localized: "Website"),
            String(localized: "Website \(2)"), String(localized: "Verification Code"),
            String(localized: "Relying Party"), String(localized: "Username"), "Hostname", "Deploy Token",
            String(localized: "Notes"),
        ])
        XCTAssertEqual(model.fields.map(\.display), [
            .plain("alice"), .concealed, .plain("https://github.com/org"), .plain("https://status.github.com"),
            .verificationCode, .plain("github.com"), .plain("alexrivers"), .plain("db.local"), .concealed,
            .plain("Line one"),
        ])
        XCTAssertEqual(model.fields.filter(\.isProtected).map(\.kind), [.password, .custom("Deploy Token")])
        XCTAssertEqual(model.fields.filter(\.canShowInLargeType).map(\.kind), [.password])
        XCTAssertFalse(try XCTUnwrap(model.fields.last).canCopy, "Notes have no copy button")
        XCTAssertEqual(model.fields[2].openableURL, URL(string: "https://github.com/org"))
        XCTAssertNotNil(model.verificationCodeConfig)
        XCTAssertEqual(model.passkeyRelyingParty, "github.com")
        XCTAssertEqual(model.title, "GitHub")
        XCTAssertEqual(model.historyCount, 1)
    }

    func testAFieldReferenceReachingAProtectedValueIsConcealedInEveryKind() async throws {
        let source = KPEntry(title: "Source", username: "plain", password: try EncryptedValue.encrypt("hunter2", using: key))
        let alias = KPEntry(
            title: "Alias",
            username: "{REF:P@I:\(source.id.kdbxHexString)}",
            url: "https://example.com/{REF:P@T:Source}",
            notes: "Password: {REF:P@T:Source}",
            customFields: ["Mirror": "{REF:P@T:Source}", "Name": "{REF:U@T:Source}"],
            customFieldOrder: ["Mirror", "Name"]
        )
        let session = try await makeSession(entries: [source, alias])
        defer { session.lockRequest(force: true) }
        let model = makeModel(.live(alias.id), session: session)
        model.appeared()

        XCTAssertEqual(model.fields.map(\.display), [.concealed, .concealed, .concealed, .plain("plain"), .concealed])
        XCTAssertEqual(model.fields.map(\.isProtected), [true, true, true, false, true])
        XCTAssertNil(model.fields[1].openableURL, "A concealed website does not open")
    }

    func testARevealWaitsForTheGateAndAPendingOrFailedPromptNeverDiscloses() async throws {
        let authentication = SuspendedAuthentication()
        let gate = SecretAccessGate(gracePeriod: { .fiveMinutes }, isAuthenticationAvailable: { true },
                                    prompt: { _ in try await authentication.authenticate() })
        let entry = try fullEntry()
        let session = try await makeSession(entries: [entry], secretAccess: gate)
        defer { session.lockRequest(force: true) }
        gate.invalidate()
        let model = makeModel(.live(entry.id), session: session)
        XCTAssertNil(model.toggleReveal(.password), "Nothing reveals before the detail is on screen")
        model.appeared()
        XCTAssertNil(model.toggleReveal(.username), "A plain field has nothing to reveal")

        let declined = try XCTUnwrap(model.toggleReveal(.password))
        await authentication.waitUntilRequested()
        XCTAssertTrue(model.isAuthenticating)
        XCTAssertEqual(display(.password, in: model), .concealed, "Pending authentication discloses nothing")
        XCTAssertNil(model.passwordStrength)
        authentication.fail()
        await declined.value
        XCTAssertEqual(display(.password, in: model), .concealed, "A failed prompt discloses nothing")

        let revealed = try XCTUnwrap(model.toggleReveal(.custom("Deploy Token")))
        await authentication.waitUntilRequested()
        authentication.complete()
        await revealed.value
        XCTAssertEqual(display(.custom("Deploy Token"), in: model), .revealed("tok-123"))
        XCTAssertEqual(display(.password, in: model), .concealed, "Each field reveals on its own")

        XCTAssertNil(model.toggleReveal(.custom("Deploy Token")), "Hiding asks nothing")
        XCTAssertEqual(display(.custom("Deploy Token"), in: model), .concealed)
    }

    func testLeavingTheScreenMidPromptCancelsTheRevealButACompletedRevealSurvivesTheEditor() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let session = try await makeSession(entries: [entry], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        session.workspace.selectedEntryID = entry.id
        let model = makeModel(.live(entry.id), session: session)
        model.appeared()

        harness.duringPrompt = { model.disappeared() }
        await model.toggleReveal(.password)?.value
        model.appeared()
        XCTAssertEqual(display(.password, in: model), .concealed, "A detail that left during the prompt reveals nothing")

        harness.duringPrompt = nil
        await model.toggleReveal(.password)?.value
        XCTAssertEqual(display(.password, in: model), .revealed("hunter2"))
        XCTAssertEqual(model.passwordStrength, PasswordStrengthEstimator.estimate("hunter2"), "Strength once revealed")

        model.disappeared()
        XCTAssertEqual(display(.password, in: model), .concealed, "No plaintext while off screen")
        XCTAssertNil(model.passwordStrength)
        model.appeared()
        XCTAssertEqual(display(.password, in: model), .revealed("hunter2"), "Back from the editor without a prompt")
        XCTAssertEqual(harness.promptReasons.count, 2)
    }

    func testSelectionContentLockAndInvalidationConceal() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let other = KPEntry(title: "Other")
        let session = try await makeSession(entries: [entry, other], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        session.workspace.selectedEntryID = entry.id
        let model = makeModel(.live(entry.id), session: session)
        model.appeared()
        func reveal() async {
            await model.toggleReveal(.password)?.value
            XCTAssertEqual(display(.password, in: model), .revealed("hunter2"))
        }

        await reveal()
        session.workspace.selectedEntryID = other.id
        XCTAssertEqual(display(.password, in: model), .concealed, "A selection change conceals")
        model.disappeared()
        session.workspace.selectedEntryID = entry.id
        model.appeared()
        XCTAssertEqual(display(.password, in: model), .concealed, "and selecting the entry again asks again")

        await reveal()
        try session.applyEntryEdit(.updateEntry(entryID: other.id, draft: EntryDraftPayload(title: "Renamed")))
        XCTAssertEqual(display(.password, in: model), .concealed, "A content change conceals")

        await reveal()
        model.invalidate()
        XCTAssertEqual(display(.password, in: model), .concealed, "A window reset conceals")

        await reveal()
        session.lockRequest(force: true)
        XCTAssertEqual(model.fields, [], "Nothing while locked")
        await session.unlock(password: "testpassword123")
        try await session.reloadDiscardingDraft()
        session.workspace.selectedEntryID = entry.id
        XCTAssertEqual(display(.password, in: model), .concealed, "Nothing revealed survives a lock")
    }

    func testThePresentationReplacesTheModelWhenTheSelectionChangesAndOnReset() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let other = KPEntry(title: "Other")
        let session = try await makeSession(entries: [entry, other], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        let presentation = MacWorkspacePresentation()
        let model = presentation.detailModel(for: entry.id, in: session, currentSession: { session })
        XCTAssertTrue(presentation.detailModel(for: entry.id, in: session, currentSession: { session }) === model)
        model.appeared()
        await model.toggleReveal(.password)?.value
        XCTAssertEqual(display(.password, in: model), .revealed("hunter2"))

        let otherModel = presentation.detailModel(for: other.id, in: session, currentSession: { session })
        XCTAssertFalse(otherModel === model)
        XCTAssertEqual(display(.password, in: model), .concealed, "The replaced model forgets its reveal")
        let again = presentation.detailModel(for: entry.id, in: session, currentSession: { session })
        again.appeared()
        XCTAssertEqual(display(.password, in: again), .concealed, "Coming back to the entry asks again")

        await again.toggleReveal(.password)?.value
        presentation.reset()
        XCTAssertEqual(display(.password, in: again), .concealed)
        XCTAssertFalse(presentation.detailModel(for: entry.id, in: session, currentSession: { session }) === again)
    }

    func testCopiesGoThroughTheGateAndTickOnlyAfterTheClipboardWrite() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let session = try await makeSession(entries: [entry], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        let feedback = MacCopyFeedback(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        var copied: [String] = []
        let model = makeModel(.live(entry.id), session: session, feedback: feedback) { copied.append($0) }

        XCTAssertNil(model.copy(.website(1)), "A plain value copies at once")
        XCTAssertEqual(copied, ["https://status.github.com"])
        XCTAssertTrue(model.isShowingCopied(.website(1)))
        XCTAssertFalse(model.isShowingCopied(.website(0)))
        XCTAssertNil(model.copy(.passkeyUsername))
        XCTAssertNil(model.copy(.notes), "Notes are not copied from the detail")
        XCTAssertNil(model.copy(.verificationCode), "The code copies without the gate")
        XCTAssertEqual(copied.count, 3)
        XCTAssertTrue(model.isShowingCopied(.verificationCode))
        feedback.clear()

        harness.promptSucceeds = false
        await model.copy(.password)?.value
        await model.copy(.custom("Deploy Token"))?.value
        XCTAssertEqual(copied.count, 3, "Declined prompts copy nothing")
        XCTAssertNil(feedback.copied, "and show no tick")

        harness.promptSucceeds = true
        await model.copy(.custom("Deploy Token"))?.value
        await model.copy(.password)?.value
        XCTAssertEqual(Array(copied.suffix(2)), ["tok-123", "hunter2"])
        XCTAssertTrue(model.isShowingCopied(.password))
        XCTAssertEqual(harness.promptReasons, [
            String(localized: "Copy password"), String(localized: "Copy protected field"),
            String(localized: "Copy protected field"), String(localized: "Copy password"),
        ])
        XCTAssertEqual(display(.password, in: model), .concealed, "Copying does not reveal")
    }

    func testLargeTypeTakesTheRevealGateAndItsRechecks() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let other = KPEntry(title: "Other")
        let session = try await makeSession(entries: [entry, other], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        let model = makeModel(.live(entry.id), session: session)
        var presented: [String] = []
        XCTAssertNil(model.showPasswordInLargeType { presented.append($0) }, "Not while off screen")
        model.appeared()

        harness.promptSucceeds = false
        await model.showPasswordInLargeType { presented.append($0) }?.value
        harness.promptSucceeds = true
        harness.duringPrompt = { session.workspace.selectedEntryID = other.id }
        await model.showPasswordInLargeType { presented.append($0) }?.value
        harness.duringPrompt = { model.disappeared() }
        await model.showPasswordInLargeType { presented.append($0) }?.value
        XCTAssertTrue(presented.isEmpty, "A declined prompt, a selection change or leaving the screen shows nothing")

        harness.duringPrompt = nil
        model.appeared()
        await model.showPasswordInLargeType { presented.append($0) }?.value
        XCTAssertEqual(presented, ["hunter2"])
        XCTAssertEqual(harness.promptReasons, Array(repeating: String(localized: "View password"), count: 4))
        XCTAssertEqual(display(.password, in: model), .concealed, "Large Type does not reveal the row")
    }

    func testAHistorySourceShowsAndDisclosesTheVersionsValues() async throws {
        let harness = SecretAccessGateHarness(gracePeriod: .alwaysAsk)
        let entry = try fullEntry()
        let session = try await makeSession(entries: [entry], secretAccess: harness.gate)
        defer { session.lockRequest(force: true) }
        var copied: [String] = []
        let model = makeModel(.history(entryID: entry.id, index: 0), session: session) { copied.append($0) }
        model.appeared()

        XCTAssertEqual(model.title, "GitHub (old)")
        XCTAssertEqual(model.fields.map(\.kind), [.username, .password, .custom("Old Token")])
        XCTAssertEqual(model.historyCount, 0)
        XCTAssertEqual(model.tags, MacEntryDetailModel.Tags(own: ["legacy"], inherited: []))
        await model.toggleReveal(.password)?.value
        await model.toggleReveal(.custom("Old Token"))?.value
        XCTAssertEqual(display(.password, in: model), .revealed("old-password"))
        XCTAssertEqual(display(.custom("Old Token"), in: model), .revealed("old-token"))
        await model.copy(.password)?.value
        XCTAssertEqual(copied, ["old-password"])

        XCTAssertEqual(makeModel(.history(entryID: entry.id, index: 5), session: session).fields, [],
                       "A version that is gone shows nothing")
    }

    func testHeaderFooterAttachmentsAndTags() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = KPEntry(
            title: "Files", tags: ["own"], hasTagsElement: true, creationTime: created,
            lastModificationTime: created.addingTimeInterval(60), expires: true,
            expiryTime: created.addingTimeInterval(-60),
            attachments: [KPAttachment(name: "id_ed25519", ref: 0), KPAttachment(name: "gone.txt", ref: 7)]
        )
        let root = KPGroup(name: "Root", entries: [KPEntry(title: "Top")], groups: [
            KPGroup(name: "Work", tags: ["shared"], hasTagsElement: true, groups: [
                KPGroup(name: "Development", entries: [entry]),
            ]),
        ])
        let pool = BinaryPool(rawFields: [Data([0]) + Data(repeating: 7, count: 411)])
        let session = try await TestDatabaseSupport.makeUnlockedSession(root: root, key: key, binaryPool: pool,
                                                                        bundle: Bundle(for: Self.self))
        defer { session.lockRequest(force: true) }
        let model = makeModel(.live(entry.id), session: session)

        XCTAssertEqual(model.pathComponents, ["Work", "Development"])
        XCTAssertEqual(model.created, created)
        XCTAssertEqual(model.modified, created.addingTimeInterval(60))
        XCTAssertEqual(model.expiry, created.addingTimeInterval(-60))
        XCTAssertTrue(model.isExpired)
        XCTAssertEqual(model.attachments, [
            MacEntryDetailModel.Attachment(index: 0, name: "id_ed25519", byteCount: 411),
            MacEntryDetailModel.Attachment(index: 1, name: "gone.txt", byteCount: nil),
        ])
        XCTAssertEqual(model.attachments.map(\.isDangling), [false, true])
        let work = try XCTUnwrap(root.groups.first)
        XCTAssertEqual(model.tags, MacEntryDetailModel.Tags(
            own: ["own"],
            inherited: [DatabaseViewModel.InheritedTagSource(tag: "shared", groupID: work.id, groupName: "Work")]
        ))
    }

    func testFormatting() {
        XCTAssertEqual(MacEntryFormatting.website("https://github.com/"), "github.com")
        XCTAssertEqual(MacEntryFormatting.website("https://github.com/org/repo/"), "github.com/org/repo")
        XCTAssertEqual(MacEntryFormatting.website("http://localhost:8080/admin?tab=1"), "localhost:8080/admin?tab=1")
        XCTAssertEqual(MacEntryFormatting.website("github.com"), "github.com", "Text without a scheme stays as stored")
        XCTAssertEqual(MacEntryFormatting.website("not a url"), "not a url")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(120 * 86_400)
        let earlier = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(MacEntryFormatting.expiry(nil, now: now), String(localized: "Never expires"))
        XCTAssertEqual(MacEntryFormatting.expiry(later, now: now),
                       String(localized: "Expires \(MacEntryFormatting.relative(later, now: now))"))
        XCTAssertEqual(MacEntryFormatting.expiry(earlier, now: now),
                       String(localized: "Expired \(MacEntryFormatting.relative(earlier, now: now))"))
        XCTAssertEqual(MacEntryFormatting.modified(earlier, now: now),
                       String(localized: "Modified \(MacEntryFormatting.relative(earlier, now: now))"))
        XCTAssertEqual(MacEntryFormatting.created(now),
                       String(localized: "Created \(now.formatted(date: .long, time: .omitted))"))
    }

    // MARK: - Support

    /// Every field kind, plus one stored version.
    private func fullEntry() throws -> KPEntry {
        let version = KPEntry(
            title: "GitHub (old)", username: "alice-old",
            password: try EncryptedValue.encrypt("old-password", using: key), tags: ["legacy"],
            customFields: ["Old Token": "old-token"], protectedStringKeys: ["Old Token"]
        )
        return KPEntry(
            title: "GitHub",
            username: "alice",
            password: try EncryptedValue.encrypt("hunter2", using: key),
            url: "https://github.com/org",
            notes: "Line one",
            customFields: [
                "KP2A_URL_1": "https://status.github.com",
                "Hostname": "db.local",
                "Deploy Token": "tok-123",
                PasskeyCredential.credentialIDKey: "Y3JlZA",
                PasskeyCredential.relyingPartyKey: "github.com",
                PasskeyCredential.usernameKey: "alexrivers",
                PasskeyCredential.userHandleKey: "dXNlcg",
            ],
            customFieldOrder: ["Hostname", "Deploy Token"],
            passkeyPrivateKey: try EncryptedValue.encrypt("PEM", using: key),
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: key)),
            history: [version],
            protectedStringKeys: ["Deploy Token"]
        )
    }

    private func makeSession(
        entries: [KPEntry], secretAccess: SecretAccessGate = SecretAccessGate()
    ) async throws -> DatabaseViewModel {
        try await TestDatabaseSupport.makeUnlockedSession(root: KPGroup(name: "Root", entries: entries), key: key,
                                                          secretAccess: secretAccess, bundle: Bundle(for: Self.self))
    }

    private func makeModel(
        _ source: EntrySource,
        session: DatabaseViewModel,
        feedback: MacCopyFeedback = MacCopyFeedback(sleep: { _ in try await Task.sleep(for: .seconds(60)) }),
        copy: @escaping @MainActor (String) -> Void = { _ in }
    ) -> MacEntryDetailModel {
        MacEntryDetailModel(source: source, session: session, copyFeedback: feedback,
                            currentSession: { session }, copy: copy)
    }

    private func display(_ kind: MacEntryField.Kind, in model: MacEntryDetailModel) -> MacEntryField.Display? {
        model.fields.first { $0.kind == kind }?.display
    }

    @MainActor
    private final class SuspendedAuthentication {
        private struct Declined: Error {}
        private var completion: CheckedContinuation<Void, Error>?
        private var started: CheckedContinuation<Void, Never>?

        func authenticate() async throws {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilRequested() async {
            guard completion == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func complete() {
            completion?.resume()
            completion = nil
        }

        func fail() {
            completion?.resume(throwing: Declined())
            completion = nil
        }
    }
}
#endif
