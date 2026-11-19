#if os(macOS)
import Observation
import XCTest
@testable import KeeForge

@MainActor
final class MacBrowserBridgeSettingsModelTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var keychain: FakeBrowserBridgeKeychain!
    private var store: BrowserPairingStore!
    private var controller: MacBrowserBridgeController!
    private var installer: FakeBrowserHostInstaller!

    override func setUp() async throws {
        suite = "BrowserBridgeSettings.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        keychain = FakeBrowserBridgeKeychain()
        store = BrowserPairingStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain)
        controller = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: nil)
        installer = FakeBrowserHostInstaller()
    }

    override func tearDown() async throws {
        controller?.stop()
        defaults.removePersistentDomain(forName: suite)
        controller = nil
    }

    private func makeModel(now: Date = Date(), locale: Locale = Locale(identifier: "en_US")) -> MacBrowserBridgeSettingsModel {
        MacBrowserBridgeSettingsModel(controller: controller, installer: installer, now: { now }, locale: locale)
    }

    private func waitFor(_ predicate: @escaping @MainActor () -> Bool) async {
        let done = expectation(description: "Observed settings state")
        Self.observe(predicate, done: done)
        await fulfillment(of: [done], timeout: 5)
    }

    private static func observe(_ predicate: @escaping @MainActor () -> Bool, done: XCTestExpectation) {
        if predicate() { done.fulfill(); return }
        withObservationTracking { _ = predicate() } onChange: {
            Task { @MainActor in Self.observe(predicate, done: done) }
        }
    }

    private func browser(_ name: String, byte: UInt8, lastUsed: Date? = nil) -> PairedBrowser {
        let key = Data(repeating: byte, count: 32)
        return PairedBrowser(clientID: BrowserBridgeCrypto.clientID(key), publicKey: key, name: name,
                             pairedAt: Date(timeIntervalSince1970: 1_700_000_000), lastUsedAt: lastUsed)
    }

    /// Seeds the store and lets the stopped-but-started controller load it, as at launch with the bridge off.
    private func seed(_ browsers: [PairedBrowser]) async throws {
        for browser in browsers { try await store.addOrReplace(browser) }
        controller.start()
        await waitFor { self.controller.pairedBrowsers.count == browsers.count }
    }

    func testRowsFollowInstallerStatesAndHideMissingBrowsers() {
        installer.states = [.chrome: .notSetUp, .brave: .ready, .edge: .needsRepair,
                            .arc: .accessLost, .firefox: .extensionIDNotConfigured, .vivaldi: .notInstalled]
        let model = makeModel()
        XCTAssertEqual(model.hostRows.map(\.browser), [.chrome, .brave, .edge, .arc, .firefox])
        XCTAssertEqual(model.hostRows.map(\.state), [.notSetUp, .ready, .needsRepair, .accessLost, .extensionIDNotConfigured])
        XCTAssertEqual(model.hostRows.first?.name, "Chrome")

        installer.states = [:]
        model.refreshHosts()
        XCTAssertTrue(model.hostRows.isEmpty)
    }

    func testSetUpCallsTheInstallerOnceAndMapsEachError() async {
        installer.states = [.chrome: .notSetUp]
        let model = makeModel()
        installer.duringSetUp = { [unowned model] in XCTAssertEqual(model.busyBrowser, .chrome) }
        await model.setUp(.chrome)
        XCTAssertEqual(installer.setUpCalls, [.chrome])
        XCTAssertNil(model.busyBrowser)
        XCTAssertEqual(model.hostRows.first?.state, .ready)
        XCTAssertNil(model.errorMessage(for: .chrome))
        installer.duringSetUp = nil

        installer.setUpError = BrowserHostInstallerError.grantCancelled
        await model.setUp(.chrome)
        XCTAssertNil(model.errorMessage(for: .chrome), "Cancelling the panel says nothing")

        let expected: [(BrowserHostInstallerError, String)] = [
            (.wrongFolder, String(localized: "Choose the folder KeeForge suggests, then click Grant Access.")),
            (.browserParentMissing, String(localized: "Open this browser once, then try again.")),
            (.accessLost, String(localized: "KeeForge couldn’t reach this browser’s folder. Try again.")),
            (.extensionIDNotConfigured, String(localized: "This version of KeeForge can’t set up this browser yet.")),
            (.foreignManifest, String(localized: "Another app’s file is in the way, so KeeForge left it unchanged.")),
            (.unsafeManifest, String(localized: "KeeForge left this browser’s folder unchanged because something in it isn’t safe to replace.")),
        ]
        for (error, message) in expected {
            installer.setUpError = error
            await model.setUp(.chrome)
            XCTAssertEqual(model.errorMessage(for: .chrome), message, "\(error)")
        }
        installer.setUpError = POSIXError(.EACCES)
        await model.setUp(.chrome)
        XCTAssertEqual(model.errorMessage(for: .chrome), String(localized: "KeeForge couldn’t reach this browser’s folder. Try again."))
        XCTAssertEqual(installer.setUpCalls.count, 2 + expected.count + 1)

        installer.setUpError = nil
        await model.setUp(.chrome)
        XCTAssertNil(model.errorMessage(for: .chrome), "A later success clears the line")
    }

    func testRepairRewritesThroughRepairAllWithoutAPanel() {
        installer.states = [.edge: .needsRepair]
        installer.statesAfterRepair = [.edge: .ready]
        let model = makeModel()
        model.repair(.edge)
        XCTAssertEqual(installer.repairCalls, 1)
        XCTAssertTrue(installer.setUpCalls.isEmpty)
        XCTAssertEqual(model.hostRows.first?.state, .ready)
        XCTAssertNil(model.errorMessage(for: .edge))

        installer.states = [.edge: .needsRepair]
        installer.statesAfterRepair = nil
        model.refreshHosts()
        model.repair(.edge)
        XCTAssertEqual(installer.repairCalls, 2)
        XCTAssertNotNil(model.errorMessage(for: .edge), "A repair that did not take says so")
    }

    func testRemoveHostCallsTheInstallerOnceWithTheBrowser() {
        installer.states = [.brave: .ready, .chrome: .ready]
        let model = makeModel()
        model.removeHost(.brave)
        XCTAssertEqual(installer.removeCalls, [.brave])
        XCTAssertEqual(model.hostRows.first { $0.browser == .brave }?.state, .notSetUp)

        installer.removeError = BrowserHostInstallerError.foreignManifest
        model.removeHost(.chrome)
        XCTAssertEqual(installer.removeCalls, [.brave, .chrome])
        XCTAssertEqual(model.errorMessage(for: .chrome), String(localized: "Another app’s file is in the way, so KeeForge left it unchanged."))
    }

    func testUnavailabilityText() async {
        let model = makeModel()
        XCTAssertNil(model.unavailabilityMessage)
        controller.isEnabled = true
        controller.start()
        await waitFor { self.controller.unavailability != nil }
        XCTAssertEqual(model.unavailabilityMessage,
                       String(localized: "This copy of KeeForge isn’t signed to let browser extensions connect."))
        model.isEnabled = false
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(model.unavailabilityMessage)
    }

    func testAuthenticationUnavailableTextFollowsTheDevice() {
        var available = true
        let model = MacBrowserBridgeSettingsModel(controller: controller, installer: installer,
                                                  canAuthenticateDeviceOwner: { available })
        XCTAssertNil(model.authenticationUnavailableMessage)
        available = false
        XCTAssertEqual(model.authenticationUnavailableMessage,
                       String(localized: "This Mac can’t ask for your login password or Touch ID, so browser extensions can fill only during the authentication grace period after you unlock a database."))
    }

    func testBridgeKeyUnavailabilityText() async throws {
        keychain.fails = true
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-\(UUID().uuidString.prefix(6))").path
        controller = MacBrowserBridgeController(defaults: defaults, store: store, socketPath: path)
        let model = makeModel()
        model.isEnabled = true
        controller.start()
        await waitFor { self.controller.unavailability != nil }
        XCTAssertEqual(model.unavailabilityMessage,
                       String(localized: "Browser extensions can’t connect because KeeForge couldn’t read its browser key from the Keychain."))
    }

    func testDatesUseTheInjectedClockAndLocale() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400)
        try await seed([browser("Brave", byte: 1, lastUsed: now.addingTimeInterval(-2 * 3_600)), browser("Arc", byte: 2)])
        let model = makeModel(now: now)
        let rows = model.pairedRows
        XCTAssertEqual(rows.map(\.name), ["Arc", "Brave"])
        XCTAssertEqual(rows.last?.lastUsed, String(localized: "Last used \("2 hours ago")"))
        XCTAssertEqual(rows.first?.lastUsed, String(localized: "Never used"))
        let paired = Date(timeIntervalSince1970: 1_700_000_000)
            .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "en_US")))
        XCTAssertEqual(rows.first?.pairedDate, paired)
        XCTAssertTrue(paired.contains("2023"))

        let german = makeModel(now: now, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(german.lastUsedText(now.addingTimeInterval(-2 * 3_600)), String(localized: "Last used \("vor 2 Stunden")"))
    }

    func testRemoveCallsTheControllerWithThatBrowser() async throws {
        let brave = browser("Brave", byte: 1), arc = browser("Arc", byte: 2)
        try await seed([brave, arc])
        let model = makeModel()
        await model.remove(clientID: brave.clientID)
        let remaining = try await store.list()
        XCTAssertEqual(remaining.map(\.clientID), [arc.clientID])
        XCTAssertEqual(model.pairedRows.map(\.id), [arc.clientID], "The list follows the controller")
        XCTAssertFalse(model.removalFailed)
    }

    func testRemoveAllReportsFailureAndClearsItOnSuccess() async throws {
        try await seed([browser("Brave", byte: 1), browser("Arc", byte: 2)])
        let model = makeModel()
        keychain.fails = true
        await model.removeAll()
        XCTAssertTrue(model.removalFailed)
        XCTAssertEqual(keychain.deletions, 0)

        keychain.fails = false
        await model.removeAll()
        XCTAssertFalse(model.removalFailed)
        XCTAssertEqual(keychain.deletions, 1)
        XCTAssertTrue(model.pairedRows.isEmpty)
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReloadClearsMessagesAndRereadsBrowsers() async {
        installer.states = [.chrome: .notSetUp]
        let model = makeModel()
        installer.setUpError = BrowserHostInstallerError.wrongFolder
        await model.setUp(.chrome)
        XCTAssertNotNil(model.errorMessage(for: .chrome))
        installer.states[.firefox] = .notSetUp
        model.reload()
        XCTAssertNil(model.errorMessage(for: .chrome))
        XCTAssertEqual(model.hostRows.map(\.browser), [.chrome, .firefox])
    }
}
#endif
