#if os(macOS)
import AppKit
import KDBXKit
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabaseSettingsModelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    func testLocalAndRemoteTabsAndLauncherRestrictions() throws {
        let local = try reference()
        let model = MacDatabaseSettingsModel(reference: local)
        XCTAssertEqual(model.tabs, [.general, .security, .autoFill, .backups])
        XCTAssertFalse(model.hasDestination)
        XCTAssertFalse(model.canChangeSecurity)
        XCTAssertNil(model.masterKeyChangedText)
        for provider in [CloudProviderKind.webDAV, .ftp] {
            var remote = local
            remote.source = .cloud(CloudSyncMetadata(provider: provider.rawValue, accountId: UUID().uuidString,
                fileId: "/vault.kdbx", displayPath: "/vault.kdbx", remoteContentHash: nil, remoteModifiedAt: nil,
                remoteRev: nil, lastSyncedAt: nil, lastSyncIssue: nil))
            XCTAssertEqual(MacDatabaseSettingsModel(reference: remote).tabs, [.general, .security, .sync, .autoFill, .backups])
        }
    }

    func testFactsReadOnlyAndReload() async throws {
        actor Reads {
            var count: Int64 = 0
            func next() -> DatabaseFileInfo {
                count += 1
                return DatabaseFileInfo(fileSizeBytes: count * 1000, modifiedAt: nil,
                    summary: KDBXFileSummary(formatVersion: .kdbx3_1, cipher: .aes256CBC, isCompressed: true, keyDerivation: .aesKDF(rounds: 10)))
            }
        }
        let reads = Reads()
        let model = MacDatabaseSettingsModel(reference: try reference(), loadFileInfo: { _ in await reads.next() })
        await model.reloadFacts()
        XCTAssertTrue(model.fixedReadOnly)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertTrue(model.facts.contains("KDBX 3.1"))
        XCTAssertEqual(model.cachedCopyCaption, String(localized: "Values reflect the locally cached copy of this database."))
        let first = model.facts
        await model.reloadFacts()
        XCTAssertNotEqual(first, model.facts)
    }

    func testSessionWritesCompositionAndLock() async throws {
        let previousQuickAutoFill = SettingsService.quickAutoFillEnabled
        SettingsService.quickAutoFillEnabled = true
        defer { SettingsService.quickAutoFillEnabled = previousQuickAutoFill }
        let reference = try reference()
        DatabaseListStore.update(reference)
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        defer { session.lock() }
        let model = MacDatabaseSettingsModel(reference: reference, session: session)
        await model.reloadFacts()
        XCTAssertTrue(model.hasDestination)
        XCTAssertTrue(model.canChangeSecurity)
        XCTAssertEqual(model.masterKeySummary, String(localized: "Password"))
        XCTAssertNotNil(model.list.autoFillEnabledRefreshHandler)
        model.setAutoFillEnabled(true)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
        XCTAssertTrue(model.current.autoFillEnabled)
        model.setAutoFillEnabled(false)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
        model.nickname = "  Work  "
        model.commitNickname()
        XCTAssertEqual(session.databaseReference.nickname, "Work")
        model.setReadOnly(true)
        XCTAssertTrue(session.isReadOnly)
        XCTAssertFalse(model.canChangeSecurity)
        model.setReadOnly(false)
        XCTAssertFalse(session.isReadOnly)
        session.lock()
        XCTAssertNil(session.masterKeyComposition)
        XCTAssertFalse(model.hasDestination)
        XCTAssertFalse(model.canChangeSecurity)
    }

    func testCommittingANicknameAfterTheDatabaseWasRemovedDoesNotAddItBack() async throws {
        let reference = try reference()
        DatabaseListStore.update(reference)
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        let model = MacDatabaseSettingsModel(reference: reference, session: session)
        model.nickname = "Typed"
        DatabaseListViewModel().removeDatabase(reference)
        model.commitNickname()
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
        session.setNickname("Direct")
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
    }

    func testLauncherWritesAutoFillBridgeAndHardwareKeyReadOnly() async throws {
        let reference = try reference()
        DatabaseListStore.update(reference)
        let list = DatabaseListViewModel()
        var refreshed: [UUID] = []
        list.autoFillEnabledRefreshHandler = { refreshed.append($0) }
        let model = MacDatabaseSettingsModel(reference: reference, list: list)
        await model.reloadFacts()
        model.nickname = "  Launcher  "
        model.commitNickname()
        model.setReadOnly(true)
        XCTAssertEqual(model.current.nickname, "Launcher")
        XCTAssertTrue(model.current.isReadOnly)
        model.setAutoFillEnabled(true)
        XCTAssertTrue(model.current.autoFillEnabled)
        XCTAssertEqual(refreshed, [reference.id])
        var hardware = model.current
        hardware.hardwareKey = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        DatabaseListStore.update(hardware)
        list.reload()
        model.setReadOnly(false)
        XCTAssertTrue(model.fixedReadOnly)
        XCTAssertTrue(model.current.isReadOnly)
        XCTAssertFalse(model.canChangeSecurity)
    }

    func testSecuritySummaryUsesTypedComponentsAndClearsOnLock() async throws {
        let fixture = KDBXTestFixture.demoKeyfile
        let url = try fixture.url(in: Bundle(for: Self.self))
        let reference = try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
        let session = DatabaseViewModel(databaseReference: reference,
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: fixture.password, keyFileData: try fixture.keyFileData(in: Bundle(for: Self.self)))
        defer { session.lock() }
        let model = MacDatabaseSettingsModel(reference: reference, session: session)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertEqual(model.masterKeySummary, String(localized: "Password and key file"))
        XCTAssertFalse(model.canChangeSecurity, "Header facts must load first")
        await model.reloadFacts()
        XCTAssertTrue(model.canChangeSecurity)
        session.lock()
        XCTAssertEqual(model.masterKeySummary, String(localized: "Unavailable"))
        XCTAssertFalse(model.canChangeSecurity)
    }

    func testFactsRefreshAfterSaveAndKeyOnlySummaryAfterRekey() async throws {
        actor Reads {
            var count: Int64 = 0
            func next() -> DatabaseFileInfo {
                count += 1
                return DatabaseFileInfo(fileSizeBytes: count * 1000, summary:
                    KDBXFileSummary(formatVersion: .kdbx4(minor: 1), cipher: .aes256CBC,
                        isCompressed: true, keyDerivation: .aesKDF(rounds: 10)))
            }
        }
        let reference = try reference()
        DatabaseListStore.update(reference)
        let session = DatabaseViewModel(databaseReference: reference,
            localSaveOperation: { _, _, _, _, _, _, _ in .saved(newSHA512: Data([2])) },
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await session.unlock(password: "testpassword123")
        defer { session.lock() }
        let reads = Reads()
        let model = MacDatabaseSettingsModel(reference: reference, session: session, loadFileInfo: { _ in await reads.next() })
        await model.refreshFactsIfNeeded()
        XCTAssertEqual(model.fileInfo?.fileSizeBytes, 1000)
        await model.refreshFactsIfNeeded()
        XCTAssertEqual(model.fileInfo?.fileSizeBytes, 1000)
        let oldHash = session.openTimeSHA512
        try await session.changeMasterKey(newPassword: nil, newKeyFileData: Data(repeating: 0x42, count: 32),
            newKeyFileBookmarkData: nil, newKeyFileFilename: nil)
        XCTAssertNotEqual(session.openTimeSHA512, oldHash)
        await model.refreshFactsIfNeeded()
        XCTAssertEqual(model.fileInfo?.fileSizeBytes, 2000)
        XCTAssertEqual(model.masterKeySummary, String(localized: "Key file"))
        XCTAssertNotNil(model.masterKeyChangedText)
    }

    func testLauncherPresentsNativeSettingsAndDoneCommitsNicknameWithoutShowingWindow() async throws {
        let reference = try reference()
        DatabaseListStore.update(reference)
        let list = DatabaseListViewModel()
        let launcher = MacDatabasesLauncherViewModel(references: { list.databases })
        let parent = NSWindow()
        let presenter = MacDatabaseSettingsLauncherPresenter(launcher: launcher, list: list, window: { parent })
        presenter.present = { shell, window, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: window, completion: completion)
        }
        presenter.start()
        launcher.perform(.details, on: reference)
        for _ in 0..<8 { await Task { @MainActor in }.value }
        let settings = try XCTUnwrap(presenter.settings)
        XCTAssertNil(settings.model.session)
        XCTAssertFalse(settings.model.hasDestination)
        XCTAssertFalse(parent.isVisible)
        settings.model.nickname = "Native settings"
        settings.shell.performDefault()
        XCTAssertNil(launcher.sheet)
        XCTAssertNil(presenter.settings)
        XCTAssertEqual(list.databases.first?.nickname, "Native settings")
    }

    func testNativeShellUsesDoneAndIconTabsWithoutShowingWindow() throws {
        let sheet = MacDatabaseSettingsSheet(model: MacDatabaseSettingsModel(reference: try reference()))
        let model = sheet.model
        XCTAssertEqual(model.tabs, [.general, .security, .autoFill, .backups], "A local database has no Sync tab")
        let tabs = sheet.tabs
        XCTAssertEqual(tabs.accessibilityIdentifier(), "database-settings.tabs")
        XCTAssertEqual(tabs.accessibilityRole(), .tabGroup)
        XCTAssertEqual(tabs.buttons.map(\.title), model.tabs.map(\.title))
        XCTAssertEqual(MacDatabaseSettingsModel.Tab.allCases.map(\.symbol),
                       ["gearshape", "lock.shield", "arrow.triangle.2.circlepath", "ellipsis.rectangle", "archivebox"])
        XCTAssertTrue(tabs.buttons.allSatisfy { $0.image != nil && $0.imagePosition == .imageAbove }, "Every tab draws its icon")
        XCTAssertEqual(tabs.buttons.map(\.isSelected), [true, false, false, false])
        tabs.buttons[3].performClick(nil)
        XCTAssertEqual(model.selection, .backups)
        XCTAssertEqual(tabs.buttons.map(\.isSelected), [false, false, false, true])
        XCTAssertEqual(tabs.buttons[3].accessibilityValue() as? Int, 1)
        sheet.showMasterKey(selectingSecurityTab: true)
        XCTAssertEqual(model.selection, .backups, "Without an unlocked session the Security tab is not forced")
        XCTAssertEqual(sheet.shell.defaultButton.title, String(localized: "Done"))
        XCTAssertTrue(sheet.shell.cancelButton.isHidden)
        XCTAssertEqual(sheet.shell.window?.accessibilityIdentifier(), "database-settings.sheet")
        XCTAssertEqual(sheet.shell.defaultButton.accessibilityIdentifier(), "database-settings.done")
        XCTAssertEqual(sheet.shell.window?.frame.width, 720)
        XCTAssertEqual(sheet.shell.window?.isVisible, false)
    }

    private func reference() throws -> DatabaseReference {
        let url = try KDBXTestFixture.test.url(in: Bundle(for: Self.self))
        return try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false)
    }
}
#endif
