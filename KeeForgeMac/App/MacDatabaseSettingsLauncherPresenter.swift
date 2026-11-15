import AppKit

@MainActor
final class MacDatabaseSettingsLauncherPresenter {
    private let launcher: MacDatabasesLauncherViewModel
    private let list: DatabaseListViewModel
    private let window: @MainActor () -> NSWindow?
    private let observation = MacObservation()
    private var endObserver: NSObjectProtocol?
    var present: @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void = {
        $0.begin(on: $1, completion: $2)
    }
    private(set) var settings: MacDatabaseSettingsSheet?

    init(launcher: MacDatabasesLauncherViewModel, list: DatabaseListViewModel, window: @escaping @MainActor () -> NSWindow?) {
        self.launcher = launcher
        self.list = list
        self.window = window
    }
    isolated deinit {
        observation.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        settings?.shell.end()
    }
    func start() {
        endObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        observation.start(reading: { [weak self] in _ = self?.launcher.sheet }, onChange: { [weak self] _ in self?.reconcile() })
    }
    func endSettings() {
        settings?.model.commitNickname()
        settings?.shell.end()
        if case .details = launcher.sheet { launcher.sheet = nil }
    }
    private func reconcile() {
        guard case .details(let id) = launcher.sheet else { settings?.shell.end(); settings = nil; return }
        guard settings == nil, let parent = window(), parent.attachedSheet == nil,
              let reference = list.databases.first(where: { $0.id == id }) else { return }
        let settings = MacDatabaseSettingsSheet(model: MacDatabaseSettingsModel(reference: reference, list: list))
        self.settings = settings
        present(settings.shell, parent) { [weak self, weak settings] _ in
            guard let self, let settings, self.settings === settings else { return }
            settings.model.commitNickname()
            self.settings = nil
            if case .details(let currentID) = launcher.sheet, currentID == id { launcher.sheet = nil }
        }
    }
}
