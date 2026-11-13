import XCTest
@testable import KeeForge

@MainActor
final class BiometricServiceTests: XCTestCase {
    func testOverlappingRequestsStayInProgressUntilTheLastEnds() {
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
        let first = BiometricService.beginAuthenticationRequest()
        let second = BiometricService.beginAuthenticationRequest()
        defer {
            BiometricService.endAuthenticationRequest(first)
            BiometricService.endAuthenticationRequest(second)
        }

        XCTAssertTrue(BiometricService.isBiometricAuthInProgress)
        BiometricService.endAuthenticationRequest(first)
        XCTAssertTrue(BiometricService.isBiometricAuthInProgress)
        BiometricService.endAuthenticationRequest(second)
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
    }

    func testRepeatedEndCannotUnderflowOrEndAnotherRequest() {
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
        let first = BiometricService.beginAuthenticationRequest()
        BiometricService.endAuthenticationRequest(first)
        BiometricService.endAuthenticationRequest(first)
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)

        let second = BiometricService.beginAuthenticationRequest()
        let third = BiometricService.beginAuthenticationRequest()
        defer {
            BiometricService.endAuthenticationRequest(first)
            BiometricService.endAuthenticationRequest(second)
            BiometricService.endAuthenticationRequest(third)
        }
        BiometricService.endAuthenticationRequest(first)
        XCTAssertTrue(BiometricService.isBiometricAuthInProgress)
        BiometricService.endAuthenticationRequest(third)
        BiometricService.endAuthenticationRequest(third)
        XCTAssertTrue(BiometricService.isBiometricAuthInProgress)
        BiometricService.endAuthenticationRequest(second)
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
    }

    func testNotificationsPostOnlyWhenInProgressChanges() {
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
        let recorder = TransitionRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: BiometricService.authenticationInProgressDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                recorder.states.append(BiometricService.isBiometricAuthInProgress)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = BiometricService.beginAuthenticationRequest()
        let second = BiometricService.beginAuthenticationRequest()
        defer {
            BiometricService.endAuthenticationRequest(first)
            BiometricService.endAuthenticationRequest(second)
        }
        XCTAssertEqual(recorder.states, [true])
        BiometricService.endAuthenticationRequest(second)
        BiometricService.endAuthenticationRequest(second)
        XCTAssertEqual(recorder.states, [true])
        BiometricService.endAuthenticationRequest(first)
        BiometricService.endAuthenticationRequest(first)
        XCTAssertEqual(recorder.states, [true, false])
        XCTAssertFalse(BiometricService.isBiometricAuthInProgress)
    }

    @MainActor
    private final class TransitionRecorder {
        var states: [Bool] = []
    }
}
