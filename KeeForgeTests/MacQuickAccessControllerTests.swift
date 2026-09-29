#if os(macOS)
import AppKit
import Carbon.HIToolbox
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

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: menuBarKey)
        UserDefaults.standard.removeObject(forKey: shortcutKey)
        presenter = FakePresenter()
        hotKey = FakeHotKey()
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

    func testHandingOffToTheMainWindowOpensOneWhenNoneIsLeft() {
        let controller = makeStartedController(menuBarEnabled: true)
        var openRequests = 0
        controller.openMainWindow = { openRequests += 1 }
        controller.togglePanel()

        controller.searchModel.showMainWindow()

        XCTAssertFalse(presenter.isPanelVisible)
        XCTAssertEqual(presenter.hideCalls.last, false, "KeeForge is the app the user is going to")
        XCTAssertEqual(openRequests, 1)
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

    // MARK: - Helpers

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
