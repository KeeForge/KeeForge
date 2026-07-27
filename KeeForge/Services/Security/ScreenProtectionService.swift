#if os(iOS)
import UIKit

@MainActor
final class ScreenProtectionService {
    private weak var windowScene: UIWindowScene?
    private var shieldWindow: UIWindow?
    private var capturedObservation: NSObjectProtocol?

    init(windowScene: UIWindowScene? = nil) {
        self.windowScene = windowScene
        startMonitoringScreenCapture()
    }

    func updateScene(_ scene: UIWindowScene?) {
        windowScene = scene
    }

    private func startMonitoringScreenCapture() {
        capturedObservation = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenCaptureChange()
            }
        }
    }

    private func handleScreenCaptureChange() {
        if UIScreen.main.isCaptured {
            showShield()
        } else {
            hideShield()
        }
    }

    func showShield() {
        guard let scene = windowScene ?? UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) as? UIWindowScene else {
            return
        }

        if shieldWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.isUserInteractionEnabled = false
            window.backgroundColor = .clear
            window.rootViewController = ScreenProtectionViewController()
            shieldWindow = window
        }

        shieldWindow?.isHidden = false
    }

    func hideShield() {
        shieldWindow?.isHidden = true
    }
}

private final class ScreenProtectionViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)

        let icon = UIImageView(image: UIImage(named: "LaunchGlyph"))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(icon)

        let title = UILabel()
        title.text = "KeeForge"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .secondaryLabel
        title.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(title)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            icon.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
        ])
    }
}
#else
import AppKit

/// macOS screen-privacy service. `UIScreen.isCaptured` has no macOS analogue,
/// so the Mac protection is layered:
///
/// 1. **Deterministic blur cover on resign-active.** Whenever the app stops
///    being frontmost (`NSApplication.didResignActiveNotification`) a borderless
///    blur overlay is placed over every vault-content window and lifted again
///    on `didBecomeActiveNotification`. This is unconditional — it does not
///    depend on the capture-block toggle — so a bystander glance, Mission
///    Control, or a screenshot of the app while it is backgrounded shows only
///    frosted glass.
///
/// 2. **Best-effort capture blocking.** A single choke point applies
///    `NSWindow.sharingType = .none` to every window when the "Block screen
///    capture" setting is on (default). New windows inherit the current policy
///    through the key-window observer, so there are no per-window call sites.
///    This is best-effort: on macOS 15+ ScreenCaptureKit ignores `sharingType`.
///
/// The **Settings window** shows no secrets. Capture blocking is applied to it
/// uniformly (harmless, and keeps the choke point a single unconditional
/// sweep), but the resign-active blur cover deliberately skips it — there is
/// nothing to hide, and covering a secret-free preferences window would only
/// be visual noise. `shouldPrivacyCover(windowIdentifier:)` encodes that split.
///
/// Window covering is exercised manually (see `docs/macos-security-notes.md`);
/// the pure policy decisions (`windowSharingType`, `shouldPrivacyCover`) are
/// unit-tested.
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

    // MARK: - Public API (called from the shared scenePhase hooks in KeeForgeApp)

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

    /// Whether a window with the given identifier should get the resign-active
    /// blur cover. The SwiftUI Settings window shows no secrets and is excluded;
    /// if Apple changes its identifier the fallback is to cover it, which is
    /// harmless.
    nonisolated static func shouldPrivacyCover(windowIdentifier: String?) -> Bool {
        guard let windowIdentifier else { return true }
        return windowIdentifier.range(of: "settings", options: .caseInsensitive) == nil
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

        let cover = NSWindow(
            contentRect: window.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .clear
        cover.isOpaque = false
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.level = .floating
        cover.sharingType = Self.windowSharingType(blockCapture: isCaptureBlocked)

        let effect = NSVisualEffectView()
        effect.material = .fullScreenUI
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        cover.contentView = effect

        window.addChildWindow(cover, ordered: .above)
        cover.setFrame(window.frame, display: true)
        coverWindows[key] = cover
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
#endif
