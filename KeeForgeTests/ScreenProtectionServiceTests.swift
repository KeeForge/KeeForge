#if os(iOS)
import UIKit
import XCTest
@testable import KeeForge

/// iOS reports a running capture as over while a system overlay (Face ID,
/// Control Center, Notification Center, an alert) covers the app, and as
/// running again once it is gone. These tests replay those sequences through
/// the capture notification and the scene lifecycle notifications.
@MainActor
final class ScreenProtectionServiceTests: XCTestCase {
    private final class CaptureState {
        var isCaptured = false
    }

    private let capture = CaptureState()
    private let captureEndDelay = Duration.milliseconds(100)

    private func makeService() -> ScreenProtectionService {
        let capture = capture
        let service = ScreenProtectionService(
            isScreenCaptured: { capture.isCaptured },
            captureEndDelay: captureEndDelay
        )
        service.update(sceneIsActive: true)
        return service
    }

    private func setCaptured(_ isCaptured: Bool) {
        capture.isCaptured = isCaptured
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Longer than `captureEndDelay`, so a confirmed capture end has landed.
    private func waitPastCaptureEnd() async throws {
        try await Task.sleep(for: captureEndDelay * 4)
    }

    func testShieldActionForEachPhaseAndCaptureState() {
        typealias Service = ScreenProtectionService
        XCTAssertEqual(Service.shieldAction(phase: .active, isScreenCaptured: false), .hide)
        XCTAssertEqual(Service.shieldAction(phase: .active, isScreenCaptured: true), .show)
        XCTAssertEqual(Service.shieldAction(phase: .inactive, isScreenCaptured: false), .keep)
        XCTAssertEqual(Service.shieldAction(phase: .inactive, isScreenCaptured: true), .show)
        XCTAssertEqual(Service.shieldAction(phase: .background, isScreenCaptured: false), .show)
        XCTAssertEqual(Service.shieldAction(phase: .background, isScreenCaptured: true), .show)
    }

    // MARK: - Without a capture

    func testBackgroundShowsTheShieldAndReturningHidesIt() {
        let service = makeService()

        post(UIScene.willDeactivateNotification)
        post(UIScene.didEnterBackgroundNotification)
        XCTAssertTrue(service.isShieldVisible)

        post(UIScene.didActivateNotification)
        XCTAssertFalse(service.isShieldVisible, "Returning without a capture kept the cover")
    }

    /// Face ID, Control Center and notifications deactivate the scene without
    /// backgrounding it; the cover must not flash for them.
    func testDeactivatingWithoutACaptureNeverShowsTheCover() {
        let service = makeService()

        post(UIScene.willDeactivateNotification)
        XCTAssertFalse(service.isShieldVisible, "Deactivating showed the cover")
        post(UIScene.didActivateNotification)
        XCTAssertFalse(service.isShieldVisible)
    }

    // MARK: - Starting and stopping a capture

    func testACaptureStartedInTheAppShowsTheShieldAtOnce() {
        let service = makeService()

        setCaptured(true)
        XCTAssertTrue(service.isShieldVisible)
    }

    func testARecordingRunningAtLaunchShowsTheShield() {
        capture.isCaptured = true
        let service = makeService()

        XCTAssertTrue(service.isShieldVisible)
    }

    /// Starting a recording from Control Center deactivates the app first;
    /// closing Control Center makes it active again while the recording runs.
    func testARecordingStartedFromControlCenterKeepsTheShieldAfterItCloses() async throws {
        let service = makeService()

        post(UIScene.willDeactivateNotification)
        setCaptured(true)
        XCTAssertTrue(service.isShieldVisible, "Recording started without a shield")

        post(UIScene.didActivateNotification)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible, "Closing Control Center took the shield down during a recording")
    }

    func testStoppingTheCaptureHidesTheShieldOnlyOnceItStaysStopped() async throws {
        let service = makeService()
        setCaptured(true)

        setCaptured(false)
        XCTAssertTrue(service.isShieldVisible, "The shield dropped on the first report that the capture ended")

        try await waitPastCaptureEnd()
        XCTAssertFalse(service.isShieldVisible, "The shield stayed after the recording stopped")
    }

    // MARK: - System overlays during a capture

    func testFaceIDDuringARecordingKeepsTheShield() async throws {
        let service = makeService()
        setCaptured(true)

        post(UIScene.willDeactivateNotification)
        setCaptured(false)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible, "The Face ID prompt took the shield down during a recording")

        setCaptured(true)
        post(UIScene.didActivateNotification)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible, "The shield dropped after Face ID during a recording")
    }

    /// The scene can become active before iOS reports the capture again.
    func testReturningBeforeTheCaptureIsReportedAgainKeepsTheShield() async throws {
        let service = makeService()
        setCaptured(true)

        post(UIScene.willDeactivateNotification)
        setCaptured(false)
        post(UIScene.didActivateNotification)
        XCTAssertTrue(service.isShieldVisible, "Activation took the shield down before the capture was reported again")

        setCaptured(true)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible, "A late capture report did not keep the shield")
    }

    func testControlCenterOrNotificationsDuringARecordingKeepTheShield() async throws {
        let service = makeService()
        setCaptured(true)

        for _ in 0..<3 {
            post(UIScene.willDeactivateNotification)
            setCaptured(false)
            try await waitPastCaptureEnd()
            XCTAssertTrue(service.isShieldVisible, "An overlay during a recording took the shield down")
            setCaptured(true)
            post(UIScene.didActivateNotification)
            XCTAssertTrue(service.isShieldVisible)
        }
    }

    /// An overlay that does not deactivate the app can still briefly report
    /// the capture as over.
    func testABriefCaptureDropoutWhileActiveKeepsTheShield() async throws {
        let service = makeService()
        setCaptured(true)

        setCaptured(false)
        setCaptured(true)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible, "A momentary capture dropout took the shield down")
    }

    func testBackgroundingDuringARecordingAndReturningKeepsTheShield() async throws {
        let service = makeService()
        setCaptured(true)

        post(UIScene.willDeactivateNotification)
        post(UIScene.didEnterBackgroundNotification)
        setCaptured(false)
        XCTAssertTrue(service.isShieldVisible)

        post(UIScene.didActivateNotification)
        XCTAssertTrue(service.isShieldVisible, "Returning took the shield down before the capture end was confirmed")
        setCaptured(true)
        try await waitPastCaptureEnd()
        XCTAssertTrue(service.isShieldVisible)
    }

    func testARecordingThatEndsWhileTheAppIsAwayClearsTheShieldOnReturn() async throws {
        let service = makeService()
        setCaptured(true)

        post(UIScene.willDeactivateNotification)
        post(UIScene.didEnterBackgroundNotification)
        setCaptured(false)
        post(UIScene.didActivateNotification)
        try await waitPastCaptureEnd()
        XCTAssertFalse(service.isShieldVisible, "The shield stayed after a recording that ended while the app was away")
    }
}
#endif
