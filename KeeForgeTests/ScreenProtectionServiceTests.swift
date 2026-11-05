#if os(iOS)
import UIKit
import XCTest
@testable import KeeForge

@MainActor
final class ScreenProtectionServiceTests: XCTestCase {
    private final class CaptureState {
        var isCaptured = false
    }

    func testShieldShowsWhenTheSceneIsNotActiveOrTheScreenIsCaptured() {
        XCTAssertTrue(ScreenProtectionService.showsShield(sceneIsActive: false, isScreenCaptured: false))
        XCTAssertTrue(ScreenProtectionService.showsShield(sceneIsActive: false, isScreenCaptured: true))
        XCTAssertTrue(ScreenProtectionService.showsShield(sceneIsActive: true, isScreenCaptured: true))
        XCTAssertFalse(ScreenProtectionService.showsShield(sceneIsActive: true, isScreenCaptured: false))
    }

    /// Starting a recording from Control Center raises the shield, and closing
    /// Control Center makes the scene active again while recording goes on.
    func testBecomingActiveKeepsTheShieldWhileTheScreenIsRecorded() {
        let capture = CaptureState()
        let service = ScreenProtectionService(isScreenCaptured: { capture.isCaptured })

        capture.isCaptured = true
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        XCTAssertTrue(service.isShieldVisible, "Recording started without a shield")

        service.update(sceneIsActive: true)
        XCTAssertTrue(service.isShieldVisible, "Becoming active took the shield down during a recording")

        capture.isCaptured = false
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        XCTAssertFalse(service.isShieldVisible, "The shield stayed after the recording stopped")
    }

    func testARecordingRunningAtLaunchShowsTheShield() {
        let capture = CaptureState()
        capture.isCaptured = true
        let service = ScreenProtectionService(isScreenCaptured: { capture.isCaptured })

        service.update(sceneIsActive: true)
        XCTAssertTrue(service.isShieldVisible)
    }

    func testBackgroundShowsTheShieldAndActiveHidesItWithoutCapture() {
        let service = ScreenProtectionService(isScreenCaptured: { false })

        service.update(sceneIsActive: false)
        XCTAssertTrue(service.isShieldVisible)
        service.update(sceneIsActive: true)
        XCTAssertFalse(service.isShieldVisible)
    }
}
#endif
