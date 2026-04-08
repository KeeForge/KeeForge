import XCTest
@testable import KeeForge

final class SettingsServiceTests: XCTestCase {
    private let autoLockKey = "KeeForge.autoLockTimeout"
    private let clipboardKey = "KeeForge.clipboardTimeout"
    private let autoUnlockWithFaceIDKey = "KeeForge.autoUnlockWithFaceID"
    private let quickAutoFillEnabledKey = "KeeForge.quickAutoFillEnabled"
    private let dropboxWriteScopeBannerLastDismissedAtKey = "dropboxWriteScopeBannerLastDismissedAt"

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: autoLockKey)
        UserDefaults.standard.removeObject(forKey: clipboardKey)
        UserDefaults.standard.removeObject(forKey: autoUnlockWithFaceIDKey)
        sharedDefaults.removeObject(forKey: autoUnlockWithFaceIDKey)
        sharedDefaults.removeObject(forKey: quickAutoFillEnabledKey)
        sharedDefaults.removeObject(forKey: dropboxWriteScopeBannerLastDismissedAtKey)
        super.tearDown()
    }

    // MARK: - Defaults

    func testAutoLockTimeoutDefaultsToImmediately() {
        UserDefaults.standard.removeObject(forKey: autoLockKey)
        XCTAssertEqual(SettingsService.autoLockTimeout, .immediately)
    }

    func testClipboardTimeoutDefaultsToThirtySeconds() {
        UserDefaults.standard.removeObject(forKey: clipboardKey)
        XCTAssertEqual(SettingsService.clipboardTimeout, .thirtySeconds)
    }

    func testAutoUnlockWithFaceIDDefaultsToOff() {
        sharedDefaults.removeObject(forKey: autoUnlockWithFaceIDKey)
        XCTAssertFalse(SettingsService.autoUnlockWithFaceID)
    }

    // MARK: - Round-trip persistence

    func testAutoLockTimeoutPersists() {
        for value in SettingsService.AutoLockTimeout.allCases {
            SettingsService.autoLockTimeout = value
            XCTAssertEqual(SettingsService.autoLockTimeout, value, "Failed for \(value.rawValue)")
        }
    }

    func testClipboardTimeoutPersists() {
        for value in SettingsService.ClipboardTimeout.allCases {
            SettingsService.clipboardTimeout = value
            XCTAssertEqual(SettingsService.clipboardTimeout, value, "Failed for \(value.rawValue)")
        }
    }

    func testAutoUnlockWithFaceIDPersists() {
        SettingsService.autoUnlockWithFaceID = true
        XCTAssertTrue(SettingsService.autoUnlockWithFaceID)

        SettingsService.autoUnlockWithFaceID = false
        XCTAssertFalse(SettingsService.autoUnlockWithFaceID)
    }

    // MARK: - Seconds values

    func testAutoLockTimeoutSeconds() {
        XCTAssertEqual(SettingsService.AutoLockTimeout.immediately.seconds, 0)
        XCTAssertEqual(SettingsService.AutoLockTimeout.thirtySeconds.seconds, 30)
        XCTAssertEqual(SettingsService.AutoLockTimeout.oneMinute.seconds, 60)
        XCTAssertEqual(SettingsService.AutoLockTimeout.fiveMinutes.seconds, 300)
        XCTAssertNil(SettingsService.AutoLockTimeout.never.seconds)
    }

    func testClipboardTimeoutSeconds() {
        XCTAssertEqual(SettingsService.ClipboardTimeout.tenSeconds.seconds, 10)
        XCTAssertEqual(SettingsService.ClipboardTimeout.thirtySeconds.seconds, 30)
        XCTAssertEqual(SettingsService.ClipboardTimeout.oneMinute.seconds, 60)
    }

    // MARK: - Invalid raw value fallback

    func testAutoLockTimeoutFallsBackOnInvalidValue() {
        UserDefaults.standard.set("bogus", forKey: autoLockKey)
        XCTAssertEqual(SettingsService.autoLockTimeout, .immediately)
    }

    func testClipboardTimeoutFallsBackOnInvalidValue() {
        UserDefaults.standard.set("bogus", forKey: clipboardKey)
        XCTAssertEqual(SettingsService.clipboardTimeout, .thirtySeconds)
    }

    // MARK: - Quick AutoFill

    func testQuickAutoFillEnabledDefaultsToTrue() {
        sharedDefaults.removeObject(forKey: quickAutoFillEnabledKey)
        XCTAssertTrue(SettingsService.quickAutoFillEnabled)
    }

    func testQuickAutoFillEnabledPersists() {
        SettingsService.quickAutoFillEnabled = true
        XCTAssertTrue(SettingsService.quickAutoFillEnabled)

        SettingsService.quickAutoFillEnabled = false
        XCTAssertFalse(SettingsService.quickAutoFillEnabled)
    }

    func testQuickAutoFillEnabledUsesSharedDefaults() {
        SettingsService.quickAutoFillEnabled = true
        XCTAssertTrue(sharedDefaults.bool(forKey: quickAutoFillEnabledKey))

        SettingsService.quickAutoFillEnabled = false
        XCTAssertFalse(sharedDefaults.bool(forKey: quickAutoFillEnabledKey))
    }

    // MARK: - Dropbox write-scope banner

    func testDropboxWriteScopeBannerDefaultsToVisible() {
        SettingsService.dropboxWriteScopeBannerLastDismissedAt = nil

        XCTAssertTrue(SettingsService.shouldShowDropboxWriteScopeUpgradeBanner())
    }

    func testDropboxWriteScopeBannerSuppressesForSevenDays() {
        let dismissedAt = Date(timeIntervalSince1970: 1_000)
        SettingsService.dismissDropboxWriteScopeUpgradeBanner(at: dismissedAt)

        XCTAssertFalse(
            SettingsService.shouldShowDropboxWriteScopeUpgradeBanner(
                now: dismissedAt.addingTimeInterval((7 * 24 * 60 * 60) - 1)
            )
        )
        XCTAssertTrue(
            SettingsService.shouldShowDropboxWriteScopeUpgradeBanner(
                now: dismissedAt.addingTimeInterval(7 * 24 * 60 * 60)
            )
        )
    }
}
