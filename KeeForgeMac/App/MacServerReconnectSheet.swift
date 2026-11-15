import AppKit

@MainActor
final class MacServerReconnectSheet {
    private let prompt: MacServerCredentialPrompt
    private let window: @MainActor () -> NSWindow?
    private let observation = MacObservation()
    private let busyObservation = MacObservation()
    private(set) var sheet: MacFormSheetController?
    private var model: MacConnectServerModel?
    private var requestID: UUID?

    init(prompt: MacServerCredentialPrompt, window: @escaping @MainActor () -> NSWindow?) {
        self.prompt = prompt
        self.window = window
    }

    var present: @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void = {
        $0.begin(on: $1, completion: $2)
    }

    func start() {
        observation.start(reading: { [weak self] in self?.prompt.request?.id }, onChange: { [weak self] _ in self?.reconcile() })
    }

    func invalidate() {
        observation.cancel()
        prompt.finish(connected: false)
        end()
    }

    private func end() {
        requestID = nil
        busyObservation.cancel()
        model?.clearSecrets()
        model = nil
        let old = sheet
        sheet = nil
        old?.end()
    }

    private func reconcile() {
        guard prompt.request?.id != requestID else { return }
        end()
        guard let request = prompt.request, let window = window() else { return }
        requestID = request.id
        let model = MacConnectServerModel(form: request.form)
        self.model = model
        let sheet = MacFormSheetController(title: String(localized: "Connect to Server"),
            content: MacConnectServerSheet(model: model, showsTypePicker: false), size: NSSize(width: 560, height: 404))
        self.sheet = sheet
        sheet.defaultButton.title = String(localized: "Connect")
        let prefix = model.serverType == .webDAV ? "webdav.connect" : "ftp.connect"
        sheet.cancelButton.setAccessibilityIdentifier(prefix + ".cancel")
        sheet.defaultButton.setAccessibilityIdentifier(prefix + ".submit")
        sheet.onConfirm = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            sheet.setBusy(true, label: String(localized: "Connect"))
            Task { @MainActor [weak self] in
                let account = await model.connect()
                guard let self, self.prompt.request?.id == request.id else { return }
                sheet.setBusy(false, label: "")
                if account != nil { self.prompt.finish(connected: true); self.end() }
            }
        }
        present(sheet, MacWorkspaceAlerts.topmostSheet(of: window)) { [weak self] _ in
            guard let self, self.prompt.request?.id == request.id else { return }
            self.prompt.finish(connected: false)
            self.end()
        }
        busyObservation.start(reading: { model.isConnecting }, onChange: { [weak sheet] busy in
            sheet?.setBusy(busy, label: String(localized: "Connect"))
        })
    }
}
