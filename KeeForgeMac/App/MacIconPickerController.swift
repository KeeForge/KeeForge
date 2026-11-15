import AppKit
import SwiftUI

@MainActor
final class MacIconPickerController {
    let model: MacIconPickerModel
    let shell: MacFormSheetController
    private let observation = MacObservation()

    init(title: String, model: MacIconPickerModel, database: DatabaseViewModel? = nil,
         download: (@MainActor () async throws -> Void)? = nil) {
        self.model = model
        let action = MacIconDownloadAction()
        let startDownload: () -> Void = { action.perform?() }
        shell = MacFormSheetController(title: title,
            content: MacIconPickerView(model: model, database: database, download: startDownload),
            size: NSSize(width: 740, height: 540))
        shell.defaultButton.title = String(localized: "Use Icon")
        shell.defaultButton.setAccessibilityIdentifier("icon-picker.use")
        shell.cancelButton.setAccessibilityIdentifier("entry-icon-picker.cancel")
        shell.canConfirm = model.canUse
        action.perform = { [weak model, weak shell] in
            guard let model, let download else { return }
            model.download(download) { shell?.end() }
        }
        observation.start(reading: { _ = model.canUse }, onChange: { [weak self] _ in
            guard let self else { return }
            shell.canConfirm = model.canUse
        })
        shell.cancellationScope.register { [weak model] in model?.end() }
    }
    func end() { model.end(); shell.end(); observation.cancel() }
}

@MainActor private final class MacIconDownloadAction {
    var perform: (() -> Void)?
}
