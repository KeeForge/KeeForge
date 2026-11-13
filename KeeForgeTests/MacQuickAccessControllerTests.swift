#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import KeeForge

/// Menu bar quick access with the status item, panel, and Carbon registration
/// replaced by fakes: nothing here adds a real menu bar item or claims a real
/// system-wide shortcut.
@MainActor
final class MacQuickAccessControllerTests: XCTestCase {
    private let menuBarKey = "KeeForge.macMenuBarQuickAccess"
    private let shortcutKey = "KeeForge.macQuickSearchShortcut"
    private let shortcut = SettingsService.MacHotKey(
        keyCode: UInt32(kVK_ANSI_K),
        carbonModifiers: UInt32(cmdKey | optionKey),
        keyLabel: "K"
    )

    private var presenter: FakePresenter!
    private var hotKey: FakeHotKey!
    private var renderedContent: [MacQuickSearchViewModel.Content] = []

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: menuBarKey)
        UserDefaults.standard.removeObject(forKey: shortcutKey)
        presenter = FakePresenter()
        hotKey = FakeHotKey()
        renderedContent = []
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: menuBarKey)
        UserDefaults.standard.removeObject(forKey: shortcutKey)
        presenter = nil
        hotKey = nil
        try await super.tearDown()
    }

    // MARK: - Opt-in defaults

    func testNothingIsInstalledByDefault() {
        let controller = makeStartedController()

        XCTAssertFalse(controller.isMenuBarItemEnabled)
        XCTAssertNil(controller.shortcut)
        XCTAssertEqual(presenter.statusItemVisible, false)
        XCTAssertTrue(hotKey.registered.isEmpty)
    }

    func testNothingTouchesAppKitBeforeStart() {
        SettingsService.macMenuBarQuickAccessEnabled = true
        SettingsService.macQuickSearchShortcut = shortcut

        _ = MacQuickAccessController(presenter: presenter, hotKey: hotKey, activateApp: {})

        XCTAssertNil(presenter.statusItemVisible)
        XCTAssertTrue(hotKey.registered.isEmpty)
    }

    func testStartRestoresTheSavedChoices() {
        SettingsService.macMenuBarQuickAccessEnabled = true
        SettingsService.macQuickSearchShortcut = shortcut

        // Not `makeStartedController()`: it would overwrite the saved choice.
        let controller = MacQuickAccessController(presenter: presenter, hotKey: hotKey, activateApp: {})
        controller.start()

        XCTAssertTrue(controller.isMenuBarItemEnabled)
        XCTAssertEqual(controller.shortcut, shortcut)
        XCTAssertEqual(presenter.statusItemVisible, true)
        XCTAssertEqual(hotKey.registered, [shortcut])
    }

    // MARK: - Settings changes

    func testEnablingTheMenuBarItemPersistsAndShowsIt() {
        let controller = makeStartedController()

        controller.isMenuBarItemEnabled = true

        XCTAssertTrue(SettingsService.macMenuBarQuickAccessEnabled)
        XCTAssertEqual(presenter.statusItemVisible, true)
    }

    func testTheShortcutOnlyExistsWhileTheMenuBarItemDoes() {
        let controller = makeStartedController()

        controller.shortcut = shortcut
        XCTAssertEqual(SettingsService.macQuickSearchShortcut, shortcut)
        XCTAssertTrue(hotKey.registered.isEmpty, "No shortcut without the menu bar item")

        controller.isMenuBarItemEnabled = true
        XCTAssertEqual(hotKey.registered, [shortcut])

        controller.isMenuBarItemEnabled = false
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertEqual(presenter.statusItemVisible, false)
    }

    func testClearingTheShortcutReleasesIt() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.shortcut = shortcut
        XCTAssertTrue(hotKey.isRegistered)

        controller.shortcut = nil

        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertNil(SettingsService.macQuickSearchShortcut)
    }

    func testRecordingReleasesTheShortcutUntilItEnds() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.shortcut = shortcut

        controller.isRecordingShortcut = true
        XCTAssertFalse(hotKey.isRegistered)

        controller.isRecordingShortcut = false
        XCTAssertTrue(hotKey.isRegistered)
    }

    func testAShortcutAnotherAppHoldsIsReported() {
        hotKey.refuses = true
        let controller = makeStartedController(menuBarEnabled: true)

        controller.shortcut = shortcut

        XCTAssertTrue(controller.isShortcutUnavailable)
        XCTAssertEqual(SettingsService.macQuickSearchShortcut, shortcut, "Kept, so the conflict stays visible")

        controller.shortcut = nil
        XCTAssertFalse(controller.isShortcutUnavailable)
    }

    // MARK: - Opening and closing the panel

    func testTheShortcutAndTheStatusItemToggleThePanel() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.searchModel.query = "left over"

        hotKey.onPressed?()
        XCTAssertTrue(presenter.isPanelVisible)
        XCTAssertEqual(controller.searchModel.query, "", "Each presentation starts from an empty search")

        presenter.onToggleRequested?()
        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(presenter.hideCalls.last, true, "Closing hands focus back to the app the user came from")
    }

    func testAToggleWithoutTheMenuBarItemDoesNothing() {
        let controller = makeStartedController()

        controller.togglePanel()

        XCTAssertFalse(presenter.isPanelVisible)
    }

    func testDisablingTheMenuBarItemClosesAnOpenPanel() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.togglePanel()

        controller.isMenuBarItemEnabled = false

        XCTAssertFalse(presenter.isPanelVisible)
    }

    func testACopyClosesThePanelAndRestoresTheOtherApp() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.togglePanel()

        controller.searchModel.onCopied?()

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(presenter.hideCalls.last, true)
    }

    func testAnAbortedPasswordCopyClosesThePanelAndRestoresTheOtherApp() {
        let controller = makeStartedController(menuBarEnabled: true)
        controller.togglePanel()
        // The authentication prompt took key status, which hides the panel
        // without handing focus back.
        presenter.hidePanel(restoringPreviousApp: false)

        controller.searchModel.onCopyAborted?()

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(presenter.hideCalls, [false, true])
    }

    func testHandingOffWithoutADatabaseOpensKeeForgeToChooseOne() {
        let controller = makeStartedController(menuBarEnabled: true)
        var listRequests = 0
        var windowRequests: [UUID] = []
        controller.showDatabaseList = { listRequests += 1 }
        controller.showDatabaseWindow = { windowRequests.append($0); return true }
        controller.togglePanel()

        controller.searchModel.showDatabase()

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(presenter.hideCalls.last, false, "KeeForge is the app the user is going to")
        XCTAssertEqual(listRequests, 1)
        XCTAssertTrue(windowRequests.isEmpty)
    }

    func testHandingOffALockedDatabaseFrontsItsWindow() throws {
        let controller = makeStartedController(menuBarEnabled: true)
        let store = DatabaseSessionStore()
        let session = store.adopt(try makeSession())
        controller.sessionForDatabase = { store.session(for: $0) }
        controller.focusedDatabaseID = session.databaseReference.id
        var listRequests = 0
        var windowRequests: [UUID] = []
        controller.showDatabaseList = { listRequests += 1 }
        controller.showDatabaseWindow = { windowRequests.append($0); return true }
        controller.togglePanel()

        controller.searchModel.showDatabase()

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(windowRequests, [session.databaseReference.id])
        XCTAssertEqual(listRequests, 0)
    }

    /// "Open in KeeForge" asks the app for the window of the result's own
    /// database, after the focus has moved to another with the same entry.
    func testOpeningAnEntryAsksForItsDatabasesWindow() async throws {
        let controller = makeStartedController(menuBarEnabled: true)
        let store = DatabaseSessionStore()
        let personal = store.adopt(try makeSession())
        let work = store.adopt(try makeSession())
        defer {
            personal.lockRequest(force: true)
            work.lockRequest(force: true)
        }
        await personal.unlock(password: "testpassword123")
        await work.unlock(password: "testpassword123")
        controller.sessionForDatabase = { store.session(for: $0) }
        controller.focusedDatabaseID = work.databaseReference.id
        var windowRequests: [UUID] = []
        controller.showDatabaseWindow = { windowRequests.append($0); return true }
        controller.togglePanel()
        controller.searchModel.query = "GitHub"
        let github = try XCTUnwrap(controller.searchModel.selectedResult)

        controller.focusedDatabaseID = personal.databaseReference.id
        controller.searchModel.openInKeeForge(github)

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(windowRequests, [work.databaseReference.id])
        XCTAssertEqual(work.workspace.selectedEntryID, github.entry.id)
        XCTAssertNotEqual(personal.workspace.selectedEntryID, github.entry.id)
    }

    // MARK: - Recorded shortcuts

    func testARecordedShortcutNeedsCommandOptionOrControl() {
        XCTAssertNil(SettingsService.MacHotKey(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [], charactersIgnoringModifiers: "k"))
        XCTAssertNil(SettingsService.MacHotKey(keyCode: UInt16(kVK_ANSI_K), modifierFlags: .shift, charactersIgnoringModifiers: "K"))
        XCTAssertNotNil(SettingsService.MacHotKey(keyCode: UInt16(kVK_ANSI_K), modifierFlags: .control, charactersIgnoringModifiers: "k"))
    }

    func testEscapeAndGlyphlessKeysAreNeverShortcuts() {
        XCTAssertNil(SettingsService.MacHotKey(keyCode: UInt16(kVK_Escape), modifierFlags: .command, charactersIgnoringModifiers: "\u{1B}"))
        XCTAssertNil(SettingsService.MacHotKey(keyCode: UInt16(kVK_Help), modifierFlags: .command, charactersIgnoringModifiers: "\u{F746}"))
    }

    func testARecordedShortcutMapsToCarbonAndDisplaysInMenuOrder() throws {
        let recorded = try XCTUnwrap(SettingsService.MacHotKey(
            keyCode: UInt16(kVK_Space),
            modifierFlags: [.command, .shift, .option, .control, .capsLock],
            charactersIgnoringModifiers: " "
        ))

        XCTAssertEqual(recorded.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(recorded.carbonModifiers, UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(recorded.displayString, "⌃⌥⇧⌘Space")

        let letter = try XCTUnwrap(SettingsService.MacHotKey(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: [.command, .option],
            charactersIgnoringModifiers: "k"
        ))
        XCTAssertEqual(letter.displayString, "⌥⌘K")
    }

    // MARK: - Panel keys

    func testPanelKeysMapToCommands() throws {
        XCTAssertEqual(try command(keyCode: kVK_DownArrow), .moveDown)
        XCTAssertEqual(try command(keyCode: kVK_UpArrow), .moveUp)
        XCTAssertEqual(try command(keyCode: kVK_Return), .primaryAction)
        XCTAssertEqual(try command(keyCode: kVK_Return, modifiers: .command), .openInKeeForge)
        XCTAssertEqual(try command(keyCode: kVK_Escape), .dismiss)
        XCTAssertEqual(try command(keyCode: kVK_ANSI_B, modifiers: [.command, .shift], characters: "b"), .copy(.username))
        XCTAssertEqual(try command(keyCode: kVK_ANSI_C, modifiers: [.command, .shift], characters: "c"), .copy(.password))
        XCTAssertEqual(try command(keyCode: kVK_ANSI_T, modifiers: [.command, .shift], characters: "t"), .copy(.verificationCode))
    }

    func testTypingAndTextEditingKeysReachTheSearchField() throws {
        XCTAssertNil(try command(keyCode: kVK_ANSI_A, characters: "a"))
        XCTAssertNil(try command(keyCode: kVK_ANSI_C, modifiers: .command, characters: "c"), "⌘C stays the field's copy")
        XCTAssertNil(try command(keyCode: kVK_ANSI_V, modifiers: .command, characters: "v"))
        XCTAssertNil(try command(keyCode: kVK_Return, modifiers: .shift))
    }

    func testAnInputMethodKeepsItsKeysWhileItComposes() {
        let fieldEditor = NSTextView()
        XCTAssertFalse(MacQuickSearchPanel.isComposingText(in: fieldEditor))

        // A Japanese input method holding "にほん" before the user confirms it.
        fieldEditor.setMarkedText(
            "にほん",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(MacQuickSearchPanel.isComposingText(in: fieldEditor), "Return, arrows and Escape belong to the candidate window")

        fieldEditor.unmarkText()
        XCTAssertFalse(MacQuickSearchPanel.isComposingText(in: fieldEditor))
        XCTAssertFalse(MacQuickSearchPanel.isComposingText(in: nil))
        XCTAssertFalse(MacQuickSearchPanel.isComposingText(in: NSView()))
    }

    // MARK: - Focused database

    /// The panel reads the target from a view body in its own hosting view.
    /// A source that is only current outside a view update, such as a binding
    /// captured from the app's state, renders "No Database Open" forever.
    func testAHostedViewBodyFollowsTheFocusedDatabase() async throws {
        let controller = makeStartedController(menuBarEnabled: true)
        let store = DatabaseSessionStore()
        controller.sessionForDatabase = { store.session(for: $0) }
        let hosting = NSHostingView(rootView: ContentProbe(model: controller.searchModel) { [weak self] in
            self?.renderedContent.append($0)
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .noDatabase)

        let session = store.adopt(try makeSession())
        let name = session.databaseReference.displayName
        controller.focusedDatabaseID = session.databaseReference.id
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .locked(databaseName: name))

        await session.unlock(password: "testpassword123")
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .unlocked(databaseName: name))

        session.lockRequest(force: true)
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .locked(databaseName: name))

        store.retire(session.databaseReference.id)
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .noDatabase)
    }

    /// While the panel is open, the focus moving to another database or the
    /// focused one locking is shown on the next render.
    func testAnOpenPanelFollowsFocusChangesAndAFocusedLock() async throws {
        let controller = makeStartedController(menuBarEnabled: true)
        let store = DatabaseSessionStore()
        let personal = store.adopt(try makeSession(nickname: "Personal"))
        let work = store.adopt(try makeSession(nickname: "Work"))
        defer {
            personal.lockRequest(force: true)
            work.lockRequest(force: true)
        }
        await personal.unlock(password: "testpassword123")
        await work.unlock(password: "testpassword123")
        controller.sessionForDatabase = { store.session(for: $0) }
        controller.focusedDatabaseID = personal.databaseReference.id
        controller.togglePanel()
        let hosting = NSHostingView(rootView: ContentProbe(model: controller.searchModel) { [weak self] in
            self?.renderedContent.append($0)
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .unlocked(databaseName: "Personal"))

        controller.focusedDatabaseID = work.databaseReference.id
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .unlocked(databaseName: "Work"))

        work.lockRequest(force: true)
        await render(hosting)
        XCTAssertEqual(renderedContent.last, .locked(databaseName: "Work"), "No fallback to the unlocked database")
        XCTAssertTrue(presenter.isPanelVisible)
    }

    func testThePanelKeepsNoClosedDatabaseAlive() throws {
        let controller = makeStartedController(menuBarEnabled: true)
        let store = DatabaseSessionStore()
        controller.sessionForDatabase = { store.session(for: $0) }
        weak var released: DatabaseViewModel?
        var databaseID: UUID?
        try autoreleasepool {
            let session = store.adopt(try makeSession())
            released = session
            databaseID = session.databaseReference.id
            controller.focusedDatabaseID = session.databaseReference.id
            XCTAssertEqual(
                controller.searchModel.content,
                .locked(databaseName: session.databaseReference.displayName)
            )
        }
        XCTAssertNotNil(released)

        store.retire(try XCTUnwrap(databaseID))

        XCTAssertNil(released, "The panel must not keep a closed database alive")
        XCTAssertEqual(controller.searchModel.content, .noDatabase)
    }

    // MARK: - Helpers

    private func makeSession(nickname: String? = nil) throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        return DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, nickname: nickname))
    }

    /// Lets SwiftUI act on an observed change, then runs the pending update.
    private func render(_ hosting: NSView) async {
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
    }

    private func makeStartedController(menuBarEnabled: Bool = false) -> MacQuickAccessController {
        SettingsService.macMenuBarQuickAccessEnabled = menuBarEnabled
        let controller = MacQuickAccessController(presenter: presenter, hotKey: hotKey, activateApp: {})
        controller.start()
        return controller
    }

    private func command(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = ""
    ) throws -> MacQuickSearchViewModel.Command? {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
        return MacQuickSearchPanel.command(for: event)
    }
}

/// Reads `content` the way `MacQuickSearchView` does: from a view body.
private struct ContentProbe: View {
    let model: MacQuickSearchViewModel
    let record: (MacQuickSearchViewModel.Content) -> Void

    var body: some View {
        let _ = record(model.content)
        Color.clear
    }
}

@MainActor
private final class FakePresenter: MacQuickSearchPanelPresenting {
    var isPanelVisible = false
    var onToggleRequested: (() -> Void)?
    var statusItemVisible: Bool?
    var hideCalls: [Bool] = []

    func setStatusItemVisible(_ visible: Bool) {
        statusItemVisible = visible
    }

    func showPanel() {
        isPanelVisible = true
    }

    func hidePanel(restoringPreviousApp: Bool) {
        isPanelVisible = false
        hideCalls.append(restoringPreviousApp)
    }
}

@MainActor
private final class FakeHotKey: MacHotKeyRegistering {
    var onPressed: (() -> Void)?
    var refuses = false
    private(set) var registered: [SettingsService.MacHotKey] = []
    private(set) var isRegistered = false

    func register(_ hotKey: SettingsService.MacHotKey) -> Bool {
        registered.append(hotKey)
        isRegistered = refuses == false
        return isRegistered
    }

    func unregister() {
        isRegistered = false
    }
}
#endif
