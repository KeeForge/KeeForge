import AppKit

/// The in-app Light/Dark/System setting, applied once to the whole app so every
/// window, sheet, panel, alert and open or save panel follows it. The AutoFill
/// extension is another process and keeps the system's appearance.
@MainActor
final class MacAppAppearance {
    private let notificationCenter: NotificationCenter
    private let readMode: @MainActor () -> SettingsService.AppearanceMode
    private let setAppearance: @MainActor (NSAppearance?) -> Void
    private var observer: NSObjectProtocol?
    private var appliedMode: SettingsService.AppearanceMode?

    init(
        notificationCenter: NotificationCenter = .default,
        readMode: @escaping @MainActor () -> SettingsService.AppearanceMode = { SettingsService.appearanceMode },
        setAppearance: @escaping @MainActor (NSAppearance?) -> Void = { NSApp.appearance = $0 }
    ) {
        self.notificationCenter = notificationCenter
        self.readMode = readMode
        self.setAppearance = setAppearance
    }

    isolated deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }

    func start() {
        guard observer == nil else { return }
        apply()
        // The setting is a plain defaults value; a write may come from any thread.
        observer = notificationCenter.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                  queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.apply() }
        }
    }

    private func apply() {
        let mode = readMode()
        guard mode != appliedMode else { return }
        appliedMode = mode
        setAppearance(mode.appAppearance)
    }
}

extension SettingsService.AppearanceMode {
    var appAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
