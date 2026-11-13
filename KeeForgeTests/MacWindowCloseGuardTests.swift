#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

/// Injected prompts and close actions exercise hidden database windows.
@MainActor
final class MacWindowCloseGuardTests: XCTestCase {
    private var vault: FakeWindowCloseVault!
    private var closeGuard: MacWindowCloseGuard!
    private var center: NotificationCenter!
    private var windows: [NSWindow] = []
    private var registry: MacDatabaseWindowRegistry!
    private var primaryWindow: NSWindow!
    private var promptedOffersSave: [Bool] = []
    private var promptChoice: MacWindowCloseGuard.Choice = .cancel
    private var closedWindowCount = 0

    override func setUp() async throws {
        try await super.setUp()
        vault = FakeWindowCloseVault()
        center = NotificationCenter()
        windows = []
        registry = MacDatabaseWindowRegistry(sessionStore: DatabaseSessionStore())
        primaryWindow = makeWindow()
        promptedOffersSave = []
        promptChoice = .cancel
        closedWindowCount = 0

        closeGuard = MacWindowCloseGuard(
            registry: registry,
            vaultProvider: { [weak self] _ in self?.vault },
            prompt: { [weak self] _, offersSave in
                self?.promptedOffersSave.append(offersSave)
                return self?.promptChoice ?? .cancel
            },
            closeWindow: { [weak self] _ in
                self?.closedWindowCount += 1
            },
            notificationCenter: center
        )
    }

    override func tearDown() async throws {
        closeGuard.stop()
        closeGuard = nil
        center = nil
        windows = []
        vault = nil
        try await super.tearDown()
    }

    // MARK: - Closes that need no answer

    func testUnregisteredWindowDoesNotAskAnySession() {
        XCTAssertTrue(closeGuard.windowShouldClose(NSWindow()))
        XCTAssertEqual(vault.requestCount, 0)
    }

    func testCloseIsAllowedWhenNothingIsUnsaved() {
        vault.decision = .close

        XCTAssertTrue(closeGuard.windowShouldClose(primaryWindow))
        XCTAssertEqual(vault.requestCount, 1)
        XCTAssertTrue(promptedOffersSave.isEmpty)
        XCTAssertEqual(closedWindowCount, 0, "the close was never held, so nothing has to close it")
    }

    // MARK: - An open editor answers for its own fields

    func testEditorDeferralHoldsTheCloseWithoutPromptingHere() {
        vault.decision = .waitForEditorPrompt

        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        XCTAssertTrue(promptedOffersSave.isEmpty, "the editor owns this prompt")
        XCTAssertEqual(closedWindowCount, 0)
    }

    func testEditorDeferralClosesTheWindowOnceTheVaultLocks() {
        vault.decision = .waitForEditorPrompt
        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))

        vault.grantClose()

        XCTAssertEqual(closedWindowCount, 1)
    }

    // MARK: - A dirty draft is answered here

    func testDirtyDraftPromptSaveDrivesTheRetry() async {
        vault.decision = .promptForUnsavedDraft
        promptChoice = .save
        vault.resolved = expectation(description: "prompt resolved")

        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        await fulfillment(of: [vault.resolved!], timeout: 1)

        XCTAssertEqual(promptedOffersSave, [true])
        XCTAssertEqual(vault.saveCount, 1)
        XCTAssertEqual(vault.discardCount, 0)
        XCTAssertEqual(vault.cancelCount, 0)
    }

    func testDirtyDraftPromptDiscardsAndClosesOnceTheVaultLocks() async {
        vault.decision = .promptForUnsavedDraft
        promptChoice = .discard
        vault.resolved = expectation(description: "prompt resolved")

        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        await fulfillment(of: [vault.resolved!], timeout: 1)
        vault.grantClose()

        XCTAssertEqual(vault.discardCount, 1)
        XCTAssertEqual(closedWindowCount, 1)
    }

    func testDirtyDraftPromptCancelKeepsTheWindowAndTheSession() async {
        vault.decision = .promptForUnsavedDraft
        promptChoice = .cancel
        vault.resolved = expectation(description: "prompt resolved")

        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        await fulfillment(of: [vault.resolved!], timeout: 1)

        XCTAssertEqual(vault.cancelCount, 1)
        XCTAssertEqual(vault.saveCount, 0)
        XCTAssertEqual(vault.discardCount, 0)
        XCTAssertEqual(closedWindowCount, 0)
        XCTAssertNil(vault.onWindowCloseGranted, "a cancelled close must not be granted later")
    }

    /// Save is not a legal operation on a read-only database, so the prompt
    /// must not offer it.
    func testReadOnlyDatabaseIsPromptedWithoutSave() async {
        vault.isReadOnly = true
        vault.decision = .promptForUnsavedDraft
        promptChoice = .discard
        vault.resolved = expectation(description: "prompt resolved")

        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        await fulfillment(of: [vault.resolved!], timeout: 1)

        XCTAssertEqual(promptedOffersSave, [false])
    }

    // MARK: - Delegate adoption

    /// The guard only ever sees a close because it is the window's delegate.
    /// These drive real `NSWindow`s — created, never shown — because that seam
    /// is AppKit's, not the app's.
    func testRegistrationWhileWindowIsAlreadyKeyInstallsCloseDelegate() throws {
        closeGuard.start()
        let window = NSWindow()
        registry.register(window, databaseID: UUID())
        vault.decision = .waitForEditorPrompt
        XCTAssertEqual(window.delegate?.windowShouldClose?(window), false)
    }

    func testAdoptedWindowRoutesItsCloseThroughTheGuard() throws {
        let window = makeWindow()
        let replaced = StubWindowDelegate()
        window.delegate = replaced
        closeGuard.start()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        let delegate = try XCTUnwrap(window.delegate)
        XCTAssertFalse(delegate === replaced, "the guard did not take over the window's delegate")

        vault.decision = .waitForEditorPrompt
        XCTAssertEqual(delegate.windowShouldClose?(window), false)
        XCTAssertEqual(vault.requestCount, 1)

        vault.cancelWindowClose()
        vault.decision = .close
        XCTAssertEqual(delegate.windowShouldClose?(window), true)
    }

    func testAdoptedWindowStillForwardsToTheDelegateItReplaced() throws {
        let window = makeWindow()
        let replaced = StubWindowDelegate()
        window.delegate = replaced
        closeGuard.start()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        let delegate = try XCTUnwrap(window.delegate)
        XCTAssertTrue(delegate.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))

        XCTAssertEqual(replaced.didResizeCount, 1)
    }

    /// A window whose own delegate refuses the close keeps refusing it, and the
    /// vault is never asked about work it would not have had to answer for.
    func testReplacedDelegatesRefusalStillWins() throws {
        let window = makeWindow()
        let replaced = StubWindowDelegate()
        replaced.shouldClose = false
        window.delegate = replaced
        closeGuard.start()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        let delegate = try XCTUnwrap(window.delegate)
        XCTAssertEqual(delegate.windowShouldClose?(window), false)
        XCTAssertEqual(vault.requestCount, 0)
    }

    func testStopRestoresTheDelegateTheWindowHad() throws {
        let window = makeWindow()
        let replaced = StubWindowDelegate()
        window.delegate = replaced
        closeGuard.start()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(window.delegate === replaced)

        closeGuard.stop()

        XCTAssertTrue(window.delegate === replaced)
    }

    func testTwoRegisteredWindowsHaveIndependentPromptsAndRepeatedCloseDoesNotStack() async {
        let secondWindow = makeWindow()
        let secondVault = FakeWindowCloseVault()
        vault.decision = .promptForUnsavedDraft
        secondVault.decision = .promptForUnsavedDraft
        var prompts: [NSWindow?] = []
        var answers: [CheckedContinuation<MacWindowCloseGuard.Choice, Never>] = []
        let firstVault = vault!
        let guardUnderTest = MacWindowCloseGuard(registry: registry,
            vaultProvider: { $0 === secondWindow ? secondVault : firstVault },
            prompt: { window, _ in
                prompts.append(window)
                return await withCheckedContinuation { answers.append($0) }
            })
        XCTAssertFalse(guardUnderTest.windowShouldClose(primaryWindow))
        XCTAssertFalse(guardUnderTest.windowShouldClose(primaryWindow))
        XCTAssertFalse(guardUnderTest.windowShouldClose(secondWindow))
        for _ in 0..<20 where answers.count < 2 { await Task.yield() }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(firstVault.requestCount, 1)
        XCTAssertEqual(secondVault.requestCount, 1)
        for answer in answers { answer.resume(returning: .cancel) }
        for _ in 0..<20 where firstVault.cancelCount + secondVault.cancelCount < 2 { await Task.yield() }
        XCTAssertEqual(firstVault.cancelCount, 1)
        XCTAssertEqual(secondVault.cancelCount, 1)
        guardUnderTest.stop()
    }

    func testLateGrantAfterRegistrationReplacementDoesNothing() throws {
        vault.decision = .waitForEditorPrompt
        XCTAssertFalse(closeGuard.windowShouldClose(primaryWindow))
        let staleGrant = try XCTUnwrap(vault.onWindowCloseGranted)
        registry.unregister(primaryWindow)
        registry.register(primaryWindow, databaseID: UUID())
        staleGrant()
        XCTAssertNil(vault.onWindowCloseGranted)
        XCTAssertEqual(closedWindowCount, 0)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        registry.register(window, databaseID: UUID())
        windows.append(window)
        return window
    }
}

private final class StubWindowDelegate: NSObject, NSWindowDelegate {
    var shouldClose = true
    private(set) var didResizeCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose
    }

    func windowDidResize(_ notification: Notification) {
        didResizeCount += 1
    }
}

@MainActor
private final class FakeWindowCloseVault: MacWindowCloseVault {
    var isReadOnly = false
    var onWindowCloseGranted: (() -> Void)?
    var decision: DatabaseViewModel.WindowCloseDecision = .close
    /// Fulfilled by whichever resolution the guard drove.
    var resolved: XCTestExpectation?

    private(set) var requestCount = 0
    private(set) var saveCount = 0
    private(set) var discardCount = 0
    private(set) var cancelCount = 0

    func requestWindowClose() -> DatabaseViewModel.WindowCloseDecision {
        requestCount += 1
        return decision
    }

    func saveAndCloseWindow() async {
        saveCount += 1
        resolved?.fulfill()
    }

    func discardAndCloseWindow() {
        discardCount += 1
        resolved?.fulfill()
    }

    func cancelWindowClose() {
        onWindowCloseGranted = nil
        cancelCount += 1
        resolved?.fulfill()
    }

    /// Stands in for the lock a resolution ends in.
    func grantClose() {
        onWindowCloseGranted?()
    }
}
#endif
