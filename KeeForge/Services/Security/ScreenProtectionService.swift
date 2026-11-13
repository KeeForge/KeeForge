#if os(iOS)
import UIKit

@MainActor
final class ScreenProtectionService {
    enum ScenePhase {
        case active, inactive, background
    }

    enum ShieldAction: Equatable {
        case show, hide, keep
    }

    private var shieldWindow: UIWindow?
    private var observations: [NSObjectProtocol] = []
    private let isScreenCaptured: @MainActor () -> Bool
    private let captureEndDelay: Duration
    private var phase = ScenePhase.inactive
    private var hasSeenCapture = false
    private var pendingCaptureEnd: Task<Void, Never>?
    private var hideAnimator: UIViewPropertyAnimator?

    init(
        isScreenCaptured: @escaping @MainActor () -> Bool = ScreenProtectionService.isAnySceneScreenCaptured,
        captureEndDelay: Duration = .seconds(1)
    ) {
        self.isScreenCaptured = isScreenCaptured
        self.captureEndDelay = captureEndDelay
        observe(UIScreen.capturedDidChangeNotification) { $0.applyShieldPolicy() }
        observe(UIScene.willDeactivateNotification) { $0.sceneWillDeactivate() }
        observe(UIScene.didActivateNotification) { $0.update(phase: .active) }
        observe(UIScene.didEnterBackgroundNotification) { $0.update(phase: .background) }
        observe(UIResponder.keyboardWillShowNotification) { $0.dismissKeyboardDuringCapture() }
    }

    /// The screen each scene is on, not `UIScreen.main`: iPhone Duo moves the
    /// scene between its two displays as it opens and closes.
    static func isAnySceneScreenCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }

    /// A shield that is fading out, or only armed, already counts as down.
    var isShieldVisible: Bool {
        guard let window = shieldWindow else { return false }
        return window.isHidden == false && window.alpha > 0 && hideAnimator == nil
    }

    /// Up in the background and while the screen is recorded, mirrored or
    /// AirPlayed. An inactive scene keeps whatever it has: Face ID, Control
    /// Center and notifications must neither flash the cover nor take it down,
    /// and iOS reports a running capture as over while they cover the app.
    nonisolated static func shieldAction(phase: ScenePhase, isScreenCaptured: Bool) -> ShieldAction {
        if isScreenCaptured || phase == .background { return .show }
        return phase == .active ? .hide : .keep
    }

    func update(sceneIsActive: Bool) {
        update(phase: sceneIsActive ? .active : .background)
    }

    private func update(phase: ScenePhase) {
        self.phase = phase
        applyShieldPolicy()
    }

    private func sceneWillDeactivate() {
        guard phase != .background else { return }
        armShieldWindow()
        update(phase: .inactive)
    }

    private func applyShieldPolicy() {
        let captured = isScreenCaptured()
        if captured { hasSeenCapture = true }
        let action = Self.shieldAction(phase: phase, isScreenCaptured: captured)
        if action != .hide {
            pendingCaptureEnd?.cancel()
            pendingCaptureEnd = nil
        }
        switch action {
        case .show: showShield(isScreenCaptured: captured)
        case .keep: break
        case .hide where hasSeenCapture: confirmCaptureEnd()
        case .hide: hideShield()
        }
    }

    /// A capture reported over can be a system overlay or the scene returning
    /// before iOS reports it captured again, so the shield stays until the
    /// screen has read uncaptured for `captureEndDelay` while active.
    private func confirmCaptureEnd() {
        guard pendingCaptureEnd == nil else { return }
        pendingCaptureEnd = Task { [weak self, captureEndDelay] in
            try? await Task.sleep(for: captureEndDelay)
            guard let self, Task.isCancelled == false else { return }
            pendingCaptureEnd = nil
            if Self.shieldAction(phase: phase, isScreenCaptured: isScreenCaptured()) == .hide {
                hasSeenCapture = false
                hideShield()
            } else {
                applyShieldPolicy()
            }
        }
    }

    /// A window that only appears once the scene is in the background is
    /// missing from the app switcher snapshot, so deactivating puts it on
    /// screen transparent and entering the background only makes it opaque.
    private func armShieldWindow() {
        guard let window = attachedShieldWindow(), window.isHidden else { return }
        window.alpha = 0
        window.isUserInteractionEnabled = false
        window.isHidden = false
    }

    private func showShield(isScreenCaptured: Bool) {
        guard let window = attachedShieldWindow() else { return }
        (window.rootViewController as? ScreenProtectionViewController)?
            .showsCaptureNotice = isScreenCaptured

        // Instant, never faded in: the app switcher snapshot is taken right away.
        hideAnimator?.stopAnimation(true)
        hideAnimator = nil
        window.alpha = 1
        window.isHidden = false
        // Nothing behind the cover can be seen, so nothing behind it may be tapped.
        window.isUserInteractionEnabled = true
        dismissKeyboardDuringCapture()
    }

    /// The keyboard sits above every app window, so during a capture it would
    /// show suggestions and key previews of what is typed behind the cover.
    /// A field that focuses itself later brings it back, hence the observer.
    private func dismissKeyboardDuringCapture() {
        guard isShieldVisible, hasSeenCapture, let scene = shieldWindow?.windowScene else { return }
        for window in scene.windows where window !== shieldWindow {
            window.endEditing(true)
        }
    }

    /// The scene is already `.background` when the shield goes up for the app
    /// switcher, so any connected window scene qualifies.
    private func attachedShieldWindow() -> UIWindow? {
        if let window = shieldWindow, window.windowScene != nil { return window }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState != .unattached })
            // Foreground active, then inactive, then background.
            .min(by: { $0.activationState.rawValue < $1.activationState.rawValue }) else {
            return nil
        }
        if let window = shieldWindow {
            window.windowScene = scene
            return window
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        window.rootViewController = ScreenProtectionViewController()
        shieldWindow = window
        return window
    }

    /// Fades out so returning to the app does not cut straight from the
    /// cover to the content.
    private func hideShield() {
        guard let window = shieldWindow, window.isHidden == false else { return }
        hideAnimator?.stopAnimation(true)
        hideAnimator = nil
        window.isUserInteractionEnabled = false
        guard window.alpha > 0 else {
            window.isHidden = true
            return
        }
        let animator = UIViewPropertyAnimator(duration: Self.revealDuration, curve: .easeOut) {
            window.alpha = 0
        }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            window.isHidden = true
            self?.hideAnimator = nil
        }
        hideAnimator = animator
        animator.startAnimation()
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (ScreenProtectionService) -> Void
    ) {
        // Synchronous: deactivation must arm the window before the scene moves on.
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observations.append(token)
    }

    private static let revealDuration: TimeInterval = 0.3
}

private final class ScreenProtectionViewController: UIViewController {
    private let captureNotice = UIView()

    /// Recording, mirroring and AirPlay leave the app blank on the other
    /// screen; the notice says why. The app switcher shows the plain cover.
    var showsCaptureNotice = false {
        didSet { captureNotice.isHidden = showsCaptureNotice == false }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Opaque, like LaunchScreen.storyboard: nothing of the app shows through.
        view.backgroundColor = .systemGroupedBackground

        // The glyph carries its own rounded corners; the shadow lifts it off the ground.
        let icon = UIImageView(image: UIImage(named: "LaunchGlyph"))
        icon.contentMode = .scaleAspectFit
        icon.layer.shadowColor = UIColor.black.cgColor
        icon.layer.shadowOpacity = 0.25
        icon.layer.shadowRadius = 12
        icon.layer.shadowOffset = CGSize(width: 0, height: 6)
        icon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon)

        let title = UILabel()
        title.text = "KeeForge"
        title.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        buildCaptureNotice()

        // Matches LaunchScreen.storyboard, so launch and the cover look the same.
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            captureNotice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureNotice.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            captureNotice.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            captureNotice.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    private func buildCaptureNotice() {
        captureNotice.backgroundColor = .secondarySystemGroupedBackground
        captureNotice.layer.cornerRadius = 20
        captureNotice.layer.cornerCurve = .continuous
        captureNotice.isHidden = showsCaptureNotice == false
        captureNotice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureNotice)

        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = String(localized: "Hidden while recording or sharing")
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        captureNotice.addSubview(row)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            row.topAnchor.constraint(equalTo: captureNotice.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: captureNotice.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: captureNotice.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: captureNotice.trailingAnchor, constant: -16),
        ])
    }
}
#else
import AppKit

/// macOS screen-privacy service. `UIScreen.isCaptured` has no macOS analogue,
/// so the Mac protection is layered:
///
/// 1. **Deterministic blur cover on resign-active.** Whenever the app stops
///    being frontmost (`NSApplication.didResignActiveNotification`) a blur
///    overlay window is placed over every vault-content window and lifted again
///    on `didBecomeActiveNotification`. The overlay is a titled window with its
///    titlebar hidden, so the system gives it the same rounded shape. This is
///    unconditional — it does not depend on the capture-block toggle — so a
///    bystander glance, Mission Control, or a screenshot of the app while it
///    is backgrounded shows only frosted glass.
///
/// 2. **Best-effort capture blocking.** A single choke point applies
///    `NSWindow.sharingType = .none` to every window when the "Block screen
///    capture" setting is on (default). New windows inherit the current policy
///    through the key-window observer, so there are no per-window call sites.
///    This is best-effort: on macOS 15+ ScreenCaptureKit ignores `sharingType`.
///
/// The Settings window can show vault-derived SSH key titles and fingerprints,
/// so it receives the same synchronous resign-active cover as vault windows.
/// The SSH tab also removes those rows from its view while the app is inactive.
///
/// The policy decisions (`windowSharingType`, `shouldPrivacyCover`) and the
/// overlay's configuration (`makeCoverWindow(over:blockCapture:)`) are
/// unit-tested; how it looks is checked by hand (see `KeeForgeMac/SECURITY.md`).
@MainActor
final class ScreenProtectionService {
    /// Posted by Settings when the "Block screen capture" toggle changes so the
    /// live service re-applies the policy to already-open windows immediately.
    static let captureBlockingDidChangeNotification =
        Notification.Name("KeeForge.captureBlockingDidChange")

    /// The single source of truth for capture blocking. Every window inherits
    /// this; flipping it re-sweeps all open windows and future windows pick it
    /// up through `observeWindows()`.
    private var isCaptureBlocked: Bool

    /// Privacy blur overlays keyed by the window they shield.
    private var coverWindows: [ObjectIdentifier: NSWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isCovered = false

    init(isCaptureBlocked: Bool = SettingsService.blockScreenCapture) {
        self.isCaptureBlocked = isCaptureBlocked
        observeActivation()
        observeWindows()
        observeSettings()
        applyCapturePolicyToAllWindows()
    }

    // MARK: - Public API (initial state supplied by AppDelegate)

    func update(sceneIsActive: Bool) {
        if sceneIsActive { hideShield() } else { showShield() }
    }

    func showShield() { showCovers() }

    func hideShield() { hideCovers() }

    /// Applies a new capture-block setting immediately to every open window.
    func setCaptureBlocked(_ blocked: Bool) {
        isCaptureBlocked = blocked
        applyCapturePolicyToAllWindows()
        // A visible cover must adopt the new sharing type too.
        for cover in coverWindows.values {
            cover.sharingType = Self.windowSharingType(blockCapture: blocked)
        }
    }

    // MARK: - Pure policy (unit-tested)

    /// The sharing type a window should use for the given capture-block setting.
    nonisolated static func windowSharingType(blockCapture: Bool) -> NSWindow.SharingType {
        blockCapture ? .none : .readOnly
    }

    /// Every app window can show vault-derived content, including Settings.
    nonisolated static func shouldPrivacyCover(windowIdentifier _: String?) -> Bool {
        true
    }

    // MARK: - Observation

    private func observeActivation() {
        observe(NSApplication.didResignActiveNotification) { $0.showCovers() }
        observe(NSApplication.didBecomeActiveNotification) { $0.hideCovers() }
    }

    private func observeWindows() {
        // Choke point for windows created later: with the init sweep, this
        // covers every window without per-window call sites. Read
        // `NSApp.keyWindow` rather than the non-Sendable Notification.
        observe(NSWindow.didBecomeKeyNotification) { service in
            guard let window = NSApplication.shared.keyWindow else { return }
            service.applyCapturePolicy(to: window)
            // If the app is currently covered (resigned active) a freshly shown
            // window should also be covered.
            if service.isCovered { service.addCover(to: window) }
        }
    }

    private func observeSettings() {
        observe(Self.captureBlockingDidChangeNotification) { service in
            service.setCaptureBlocked(SettingsService.blockScreenCapture)
        }
    }

    // MARK: - Capture policy

    private func applyCapturePolicyToAllWindows() {
        for window in NSApplication.shared.windows {
            applyCapturePolicy(to: window)
        }
    }

    private func applyCapturePolicy(to window: NSWindow) {
        // Never retarget our own cover overlays through the generic sweep;
        // they track the policy via `setCaptureBlocked`.
        guard isCover(window) == false else { return }
        window.sharingType = Self.windowSharingType(blockCapture: isCaptureBlocked)
    }

    // MARK: - Blur cover

    private func showCovers() {
        isCovered = true
        for window in NSApplication.shared.windows where isVaultContentWindow(window) {
            addCover(to: window)
        }
    }

    private func hideCovers() {
        isCovered = false
        for cover in coverWindows.values {
            cover.parent?.removeChildWindow(cover)
            cover.orderOut(nil)
        }
        coverWindows.removeAll()
    }

    private func addCover(to window: NSWindow) {
        guard isVaultContentWindow(window) else { return }
        let key = ObjectIdentifier(window)
        guard coverWindows[key] == nil else { return }

        let cover = Self.makeCoverWindow(over: window, blockCapture: isCaptureBlocked)
        window.addChildWindow(cover, ordered: .above)
        cover.setFrame(window.frame, display: true)
        coverWindows[key] = cover
    }

    /// A borderless window has square corners, and AppKit does not expose a
    /// window's corner radius. A titled window with the same toolbar style gets
    /// the parent's shape from the system.
    static func makeCoverWindow(over window: NSWindow, blockCapture: Bool) -> NSWindow {
        let cover = PrivacyCoverWindow(
            contentRect: window.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        cover.isReleasedWhenClosed = false
        cover.isExcludedFromWindowsMenu = true
        cover.titleVisibility = .hidden
        cover.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            cover.standardWindowButton(button)?.isHidden = true
        }
        if window.toolbar != nil {
            cover.toolbar = NSToolbar(identifier: "PrivacyCover")
            cover.toolbarStyle = window.toolbarStyle
        }
        cover.backgroundColor = .clear
        cover.isOpaque = false
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.level = .floating
        cover.sharingType = windowSharingType(blockCapture: blockCapture)

        let effect = NSVisualEffectView()
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        cover.contentView = effect
        return cover
    }

    // MARK: - Window classification

    private func isVaultContentWindow(_ window: NSWindow) -> Bool {
        guard isCover(window) == false else { return false }
        guard window.isVisible else { return false }
        // Real content windows are titled; skip panels, tear-off menus, etc.
        guard window.styleMask.contains(.titled) else { return false }
        return Self.shouldPrivacyCover(windowIdentifier: window.identifier?.rawValue)
    }

    private func isCover(_ window: NSWindow) -> Bool {
        coverWindows.values.contains { $0 === window }
    }

    // MARK: - Helpers

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (ScreenProtectionService) -> Void
    ) {
        // queue: nil delivers synchronously on the posting thread, and every
        // observed notification is posted on the main thread, so
        // `assumeIsolated` re-asserts main-actor isolation without a hop. The
        // non-Sendable Notification is deliberately never captured.
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }
}

/// Titled windows can become key by default; the cover must never take focus.
private final class PrivacyCoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
