import XCTest
@testable import KeeForge
#if canImport(AppKit)
import AppKit
#endif

final class SettingsServiceTests: XCTestCase {
    private let autoLockKey = "KeeForge.autoLockTimeout"
    private let lockOnBackgroundKey = "KeeForge.lockOnBackground"
    private let clipboardKey = "KeeForge.clipboardTimeout"
    private let autoUnlockWithFaceIDKey = "KeeForge.autoUnlockWithFaceID"
    private let showDatabaseUsageStatsKey = "KeeForge.showDatabaseUsageStats"
    private let quickAutoFillEnabledKey = "KeeForge.quickAutoFillEnabled"
    private let appearanceModeKey = "KeeForge.appearanceMode"
    private let hasTippedKey = "KeeForge.hasTipped"
    private let macLockPolicyKey = "KeeForge.macLockPolicy"
    private let blockScreenCaptureKey = "KeeForge.blockScreenCapture"

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SharedVaultStore.appGroupID) ?? .standard
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: autoLockKey)
        UserDefaults.standard.removeObject(forKey: lockOnBackgroundKey)
        UserDefaults.standard.removeObject(forKey: clipboardKey)
        UserDefaults.standard.removeObject(forKey: autoUnlockWithFaceIDKey)
        UserDefaults.standard.removeObject(forKey: showDatabaseUsageStatsKey)
        UserDefaults.standard.removeObject(forKey: appearanceModeKey)
        UserDefaults.standard.removeObject(forKey: hasTippedKey)
        UserDefaults.standard.removeObject(forKey: macLockPolicyKey)
        UserDefaults.standard.removeObject(forKey: blockScreenCaptureKey)
        sharedDefaults.removeObject(forKey: autoUnlockWithFaceIDKey)
        sharedDefaults.removeObject(forKey: quickAutoFillEnabledKey)
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

    func testLockOnBackgroundDefaultsToOn() {
        UserDefaults.standard.removeObject(forKey: lockOnBackgroundKey)
        XCTAssertTrue(SettingsService.lockOnBackground)
    }

    func testAutoUnlockWithFaceIDDefaultsToOff() {
        sharedDefaults.removeObject(forKey: autoUnlockWithFaceIDKey)
        XCTAssertFalse(SettingsService.autoUnlockWithFaceID)
    }

    func testShowDatabaseUsageStatsDefaultsToOn() {
        UserDefaults.standard.removeObject(forKey: showDatabaseUsageStatsKey)
        XCTAssertTrue(SettingsService.showDatabaseUsageStats)
    }

    func testAppearanceModeDefaultsToSystem() {
        UserDefaults.standard.removeObject(forKey: appearanceModeKey)
        XCTAssertEqual(SettingsService.appearanceMode, .system)
    }

    func testHasTippedDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: hasTippedKey)
        XCTAssertFalse(SettingsService.hasTipped)
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

    func testLockOnBackgroundPersists() {
        SettingsService.lockOnBackground = true
        XCTAssertTrue(SettingsService.lockOnBackground)

        SettingsService.lockOnBackground = false
        XCTAssertFalse(SettingsService.lockOnBackground)
    }

    func testAutoUnlockWithFaceIDPersists() {
        SettingsService.autoUnlockWithFaceID = true
        XCTAssertTrue(SettingsService.autoUnlockWithFaceID)

        SettingsService.autoUnlockWithFaceID = false
        XCTAssertFalse(SettingsService.autoUnlockWithFaceID)
    }

    func testShowDatabaseUsageStatsPersists() {
        SettingsService.showDatabaseUsageStats = true
        XCTAssertTrue(SettingsService.showDatabaseUsageStats)

        SettingsService.showDatabaseUsageStats = false
        XCTAssertFalse(SettingsService.showDatabaseUsageStats)
    }

    func testAppearanceModePersists() {
        for value in SettingsService.AppearanceMode.allCases {
            SettingsService.appearanceMode = value
            XCTAssertEqual(SettingsService.appearanceMode, value, "Failed for \(value.rawValue)")
        }
    }

    func testHasTippedPersists() {
        SettingsService.hasTipped = true
        XCTAssertTrue(SettingsService.hasTipped)

        SettingsService.hasTipped = false
        XCTAssertFalse(SettingsService.hasTipped)
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

    func testAppearanceModeFallsBackOnInvalidValue() {
        UserDefaults.standard.set("bogus", forKey: appearanceModeKey)
        XCTAssertEqual(SettingsService.appearanceMode, .system)
    }

    // MARK: - macOS Lock Policy

    func testMacLockPolicyDefaultsToScreenLockOrSleep() {
        UserDefaults.standard.removeObject(forKey: macLockPolicyKey)
        XCTAssertEqual(SettingsService.macLockPolicy, .screenLockOrSleep)
    }

    func testMacLockPolicyPersists() {
        for value in SettingsService.MacLockPolicy.allCases {
            SettingsService.macLockPolicy = value
            XCTAssertEqual(SettingsService.macLockPolicy, value, "Failed for \(value.rawValue)")
        }
    }

    func testMacLockPolicyFallsBackOnInvalidValue() {
        UserDefaults.standard.set("bogus", forKey: macLockPolicyKey)
        XCTAssertEqual(SettingsService.macLockPolicy, .screenLockOrSleep)
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

    // MARK: - Block Screen Capture

    func testBlockScreenCaptureDefaultsToOn() {
        UserDefaults.standard.removeObject(forKey: blockScreenCaptureKey)
        XCTAssertTrue(SettingsService.blockScreenCapture)
    }

    func testBlockScreenCapturePersists() {
        SettingsService.blockScreenCapture = false
        XCTAssertFalse(SettingsService.blockScreenCapture)

        SettingsService.blockScreenCapture = true
        XCTAssertTrue(SettingsService.blockScreenCapture)
    }

    func testBlockScreenCaptureUsesStandardDefaults() {
        // App-local (per-device UI preference), not App Group-shared.
        SettingsService.blockScreenCapture = false
        XCTAssertNil(sharedDefaults.object(forKey: blockScreenCaptureKey))
    }

    // MARK: - Screen Protection Policy (macOS)

    #if os(macOS)
    func testWindowSharingTypeMapsToBlockCapture() {
        XCTAssertEqual(ScreenProtectionService.windowSharingType(blockCapture: true), .none)
        XCTAssertEqual(ScreenProtectionService.windowSharingType(blockCapture: false), .readOnly)
    }

    func testPrivacyCoverExcludesSettingsWindow() {
        // The Settings window shows no secrets and must not get the blur cover.
        XCTAssertFalse(ScreenProtectionService.shouldPrivacyCover(windowIdentifier: "com_apple_SwiftUI_Settings_window"))
        XCTAssertFalse(ScreenProtectionService.shouldPrivacyCover(windowIdentifier: "SettingsWindow"))
    }

    func testPrivacyCoverAppliesToVaultAndUnknownWindows() {
        XCTAssertTrue(ScreenProtectionService.shouldPrivacyCover(windowIdentifier: nil))
        XCTAssertTrue(ScreenProtectionService.shouldPrivacyCover(windowIdentifier: "com_apple_SwiftUI_Window-1"))
    }
    #endif

}
