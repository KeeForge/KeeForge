#if os(macOS)
import Foundation
@testable import KeeForge

/// Records each installer call; states and failures are set by the test.
@MainActor
final class FakeBrowserHostInstaller: BrowserHostInstalling {
    var states: [HostBrowser: BrowserHostInstallerState] = [:]
    var setUpError: (any Error)?
    var removeError: (any Error)?
    /// Applied to `states` by `repairAll()`.
    var statesAfterRepair: [HostBrowser: BrowserHostInstallerState]?
    private(set) var setUpCalls: [HostBrowser] = []
    private(set) var removeCalls: [HostBrowser] = []
    private(set) var repairCalls = 0
    /// Runs inside `setUp` before it returns, so a test can look at the model mid-call.
    var duringSetUp: (@MainActor () -> Void)?

    func state(for browser: HostBrowser) -> BrowserHostInstallerState { states[browser] ?? .notInstalled }

    func setUp(_ browser: HostBrowser) async throws {
        setUpCalls.append(browser)
        duringSetUp?()
        if let setUpError { throw setUpError }
        states[browser] = .ready
    }

    func repairAll() {
        repairCalls += 1
        if let statesAfterRepair { states = statesAfterRepair }
    }

    func remove(_ browser: HostBrowser) throws {
        removeCalls.append(browser)
        if let removeError { throw removeError }
        states[browser] = .notSetUp
    }
}
#endif
