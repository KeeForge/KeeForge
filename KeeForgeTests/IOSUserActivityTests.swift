#if os(iOS)
import XCTest
import UIKit
@testable import KeeForge

@MainActor
final class IOSUserActivityTests: XCTestCase {
    func testTypingInFieldsAndNotesIncludingPresentedContentReportsActivity() {
        let center = NotificationCenter()
        let window = UIWindow()
        var now = Date(timeIntervalSince1970: 1_000)
        var activityCount = 0
        let observer = IOSUserActivityView(
            onActivity: { activityCount += 1 }, notificationCenter: center,
            now: { now }, isActive: { true }
        )
        window.addSubview(observer)
        let presentedContent = UIView()
        window.addSubview(presentedContent)
        let field = UITextField()
        let notes = UITextView()
        presentedContent.addSubview(field)
        presentedContent.addSubview(notes)

        center.post(name: UITextField.textDidChangeNotification, object: field)
        XCTAssertEqual(activityCount, 1)
        now = now.addingTimeInterval(2)
        center.post(name: UITextView.textDidChangeNotification, object: notes)
        XCTAssertEqual(activityCount, 2)

        let unrelatedField = UITextField()
        now = now.addingTimeInterval(2)
        center.post(name: UITextField.textDidChangeNotification, object: unrelatedField)
        XCTAssertEqual(activityCount, 2, "Only input in the observed window counts")
        observer.removeFromSuperview()
        center.post(name: UITextView.textDidChangeNotification, object: notes)
        XCTAssertEqual(activityCount, 2, "Detached observers must stop forwarding")
        XCTAssertFalse(window.gestureRecognizers?.contains { $0 is IOSActivityGestureRecognizer } ?? false)
    }

    func testActivityBurstIsThrottledAndInactiveTypingIsIgnored() {
        let center = NotificationCenter()
        let window = UIWindow()
        let field = UITextField()
        var now = Date(timeIntervalSince1970: 1_000)
        var active = true
        var activityCount = 0
        let observer = IOSUserActivityView(
            onActivity: { activityCount += 1 }, notificationCenter: center,
            now: { now }, isActive: { active }
        )
        window.addSubview(observer)
        window.addSubview(field)

        center.post(name: UITextField.textDidChangeNotification, object: field)
        now = now.addingTimeInterval(0.5)
        center.post(name: UITextField.textDidChangeNotification, object: field)
        XCTAssertEqual(activityCount, 1)
        now = now.addingTimeInterval(1)
        center.post(name: UITextField.textDidChangeNotification, object: field)
        XCTAssertEqual(activityCount, 2)

        active = false
        now = now.addingTimeInterval(10)
        center.post(name: UITextField.textDidChangeNotification, object: field)
        XCTAssertEqual(activityCount, 2)
        active = true
        center.post(name: UITextField.textDidChangeNotification, object: field)
        XCTAssertEqual(activityCount, 3, "Inactive events must not consume the throttle window")
        observer.removeFromSuperview()
    }

    func testTouchObserverReportsTapAndDragWithoutInterferingWithControls() throws {
        let window = UIWindow()
        var now = Date(timeIntervalSince1970: 1_000)
        var activityCount = 0
        let observer = IOSUserActivityView(
            onActivity: { activityCount += 1 }, now: { now }, isActive: { true }
        )
        window.addSubview(observer)
        defer { observer.removeFromSuperview() }
        let gesture = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? IOSActivityGestureRecognizer }.first)
        let scroll = UIPanGestureRecognizer()
        XCTAssertFalse(gesture.cancelsTouchesInView)
        XCTAssertFalse(gesture.delaysTouchesBegan)
        XCTAssertFalse(gesture.delaysTouchesEnded)
        XCTAssertFalse(gesture.canPrevent(scroll))
        XCTAssertFalse(gesture.canBePrevented(by: scroll))

        let event = UIEvent()
        gesture.touchesBegan([], with: event)
        XCTAssertEqual(activityCount, 1)
        now = now.addingTimeInterval(2)
        gesture.touchesMoved([], with: event)
        XCTAssertEqual(activityCount, 2)
        now = now.addingTimeInterval(2)
        gesture.touchesEnded([], with: event)
        XCTAssertEqual(activityCount, 3)
    }
}
#endif
