import XCTest
@testable import KeeForge

@MainActor
final class AutoLockTests: XCTestCase {
    private let fixturePassword = "testpassword123"
    private var savedAutoLockTimeout: SettingsService.AutoLockTimeout!
    private var savedLockOnBackground: Bool!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        savedAutoLockTimeout = SettingsService.autoLockTimeout
        savedLockOnBackground = SettingsService.lockOnBackground
    }

    override func tearDown() async throws {
        SettingsService.autoLockTimeout = savedAutoLockTimeout
        SettingsService.lockOnBackground = savedLockOnBackground
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    func testLockClearsRootGroup() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.rootGroup)

        vm.lock()

        XCTAssertNil(vm.rootGroup)
    }

    func testLockClearsCompositeKey() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.compositeKey)

        vm.lock()

        XCTAssertNil(vm.compositeKey)
    }

    func testLockSetsStateLocked() async throws {
        let vm = try await makeUnlockedViewModel()
        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked before lock()")
            return
        }

        vm.lock()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after lock()")
            return
        }
    }

    func testLockPreservesSelectedDatabaseReference() async throws {
        let vm = try await makeUnlockedViewModel()
        XCTAssertTrue(vm.hasSavedFile)

        vm.lock()

        XCTAssertTrue(vm.hasSavedFile)
    }

    func testLockClearsSearchText() async throws {
        let vm = try await makeUnlockedViewModel()
        vm.searchText = "test"

        vm.lock()

        XCTAssertEqual(vm.searchText, "")
    }

    func testLockClearsNavigationPath() async throws {
        let vm = try await makeUnlockedViewModel()
        vm.navigationPath.append("something")

        vm.lock()

        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    func testInactivityTimerCreatedWithCorrectInterval() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()

        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 300, accuracy: 0.001)
    }

    func testInactivityTimerThirtySecondsInterval() async throws {
        SettingsService.autoLockTimeout = .thirtySeconds
        let vm = try await makeUnlockedViewModel()

        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 30, accuracy: 0.001)
    }

    func testInactivityTimerCancelledOnLock() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try await makeUnlockedViewModel()
        XCTAssertNotNil(vm.inactivityTimer)

        vm.lock()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testNeverSettingMeansNoTimer() async throws {
        SettingsService.autoLockTimeout = .never
        let vm = try await makeUnlockedViewModel()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testImmediatelySettingMeansNoForegroundTimer() async throws {
        SettingsService.autoLockTimeout = .immediately
        let vm = try await makeUnlockedViewModel()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testResetInactivityTimerDoesNothingWhenLocked() throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let vm = try makeViewModel()

        vm.resetInactivityTimer()

        XCTAssertNil(vm.inactivityTimer)
    }

    func testBackgroundLockEnabledLocksImmediatelyOnBackground() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = true
        let vm = try await makeUnlockedViewModel()

        vm.handleSceneDidEnterBackground()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after backgrounding with background lock enabled")
            return
        }
    }

    func testBackgroundLockDisabledPreservesVaultAndResumesRemainingTime() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        XCTAssertEqual(vm.inactivityDeadline, clock.now.addingTimeInterval(300))

        vm.handleSceneDidEnterBackground()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked while backgrounded with background lock disabled")
            return
        }
        XCTAssertNil(vm.inactivityTimer)

        clock.advance(by: 120)
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked after returning before deadline")
            return
        }
        XCTAssertNotNil(vm.inactivityTimer)
        XCTAssertEqual(vm.inactivityDeadline, Date(timeIntervalSince1970: 1_300))
        XCTAssertEqual(vm.inactivityTimerInterval ?? 0, 180, accuracy: 0.001)
    }

    func testBackgroundLockDisabledLocksAfterDeadlineOnForegroundReturn() async throws {
        SettingsService.autoLockTimeout = .thirtySeconds
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 31)
        vm.handleSceneDidBecomeActive()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked after returning after the inactivity deadline")
            return
        }
    }

    func testBackgroundLockDisabledNeverKeepsVaultUnlocked() async throws {
        SettingsService.autoLockTimeout = .never
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 600)
        vm.handleSceneDidBecomeActive()

        guard case .unlocked = vm.state else {
            XCTFail("Expected .unlocked with Never timeout and background lock disabled")
            return
        }
        XCTAssertNil(vm.inactivityTimer)
    }

    func testBackgroundLockDisabledImmediatelyLocksOnForegroundReturn() async throws {
        SettingsService.autoLockTimeout = .immediately
        SettingsService.lockOnBackground = false
        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try await makeUnlockedViewModel(nowProvider: { clock.now })

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 1)
        vm.handleSceneDidBecomeActive()

        guard case .locked = vm.state else {
            XCTFail("Expected .locked with Immediate timeout after background return")
            return
        }
    }

    private func makeUnlockedViewModel() async throws -> DatabaseViewModel {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)
        return vm
    }

    private func makeUnlockedViewModel(
        nowProvider: @escaping @Sendable () -> Date
    ) async throws -> DatabaseViewModel {
        let vm = try makeViewModel(nowProvider: nowProvider)
        await vm.unlock(password: fixturePassword)
        return vm
    }

    private func makeViewModel(
        nowProvider: @escaping @Sendable () -> Date = { .now }
    ) throws -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: fixtureURL()),
            nowProvider: nowProvider
        )
    }

    private func fixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: AutoLockTests.self))
    }
}

private final class MutableNowProvider: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}
