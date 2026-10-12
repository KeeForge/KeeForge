#if os(iOS)
import SwiftUI
import UIKit

struct IOSUserActivityObserver: UIViewRepresentable {
    var onActivity: () -> Void

    func makeUIView(context: Context) -> IOSUserActivityView {
        IOSUserActivityView(onActivity: onActivity)
    }

    func updateUIView(_ view: IOSUserActivityView, context: Context) {
        view.onActivity = onActivity
    }
}

final class IOSUserActivityView: UIView {
    var onActivity: () -> Void
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private let isActive: () -> Bool
    private var lastActivityAt: Date?
    private lazy var activityGesture = IOSActivityGestureRecognizer { [weak self] in
        self?.recordActivity()
    }

    init(
        onActivity: @escaping () -> Void,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = { .now },
        isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.onActivity = onActivity
        self.notificationCenter = notificationCenter
        self.now = now
        self.isActive = isActive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        activityGesture.view?.removeGestureRecognizer(activityGesture)
        notificationCenter.removeObserver(self)
        lastActivityAt = nil
        guard let window else { return }
        window.addGestureRecognizer(activityGesture)
        for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            notificationCenter.addObserver(self, selector: #selector(textDidChange), name: name, object: nil)
        }
    }

    @objc private func textDidChange(_ notification: Notification) {
        guard let input = notification.object as? UIView, input.window === window else { return }
        recordActivity()
    }

    private func recordActivity() {
        guard window != nil, isActive() else { return }
        let timestamp = now()
        // A drag or key-repeat burst needs at most one timer reset per second.
        if let lastActivityAt, timestamp.timeIntervalSince(lastActivityAt) < 1 { return }
        lastActivityAt = timestamp
        onActivity()
    }
}

final class IOSActivityGestureRecognizer: UIGestureRecognizer {
    private let onActivity: () -> Void

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onActivity()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onActivity()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onActivity()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    // Observe the whole drag without claiming it or losing it to a scroll view.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
