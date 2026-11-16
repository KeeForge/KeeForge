import AppKit
import SwiftUI

@MainActor
final class MacDatabasesSheets: NSObject {
    private weak var window: NSWindow?
    private let launcher: MacDatabasesLauncherViewModel
    private let list: DatabaseListViewModel
    private let panels = MacFilePanels()
    private let observation = MacObservation()
    private let busyObservation = MacObservation()
    private(set) var shell: MacFormSheetController?
    private(set) var connect: MacConnectServerModel?
    private(set) var creation: DatabaseCreationViewModel?
    private var browser: MacRemoteBrowserViewController?
    private var generation = UUID()
    private var activeRequest: MacDatabasesLauncherViewModel.Sheet?

    private let presentSheet: @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void

    init(window: NSWindow, launcher: MacDatabasesLauncherViewModel, list: DatabaseListViewModel,
         present: @escaping @MainActor (MacFormSheetController, NSWindow, @escaping @MainActor (Bool) -> Void) -> Void = {
             $0.begin(on: $1, completion: $2)
         }) {
        presentSheet = present
        self.window = window; self.launcher = launcher; self.list = list
        super.init()
        panels.window = window
        launcher.isSheetBusy = { [weak self] in self?.shell?.isBusy == true }
        observation.start(reading: { launcher.sheet }, onChange: { [weak self] request in self?.reconcile(request) })
    }
    func end() {
        generation = UUID()
        panels.cancel()
        busyObservation.cancel()
        connect?.clearSecrets(); connect = nil
        creation?.cancelPendingCreation(); creation = nil
        browser?.end(); browser = nil
        let old = shell; shell = nil
        old?.end()
        activeRequest = nil
    }
    private func reconcile(_ request: MacDatabasesLauncherViewModel.Sheet?) {
        guard request != activeRequest else { return }
        if request != nil, shell?.isBusy == true {
            launcher.sheet = activeRequest
            return
        }
        end()
        guard let request else { return }
        activeRequest = request
        switch request {
        case .newDatabase: showCreation()
        case .connect(let kind): showConnect(kind: kind, forCreation: false)
        case .details: break
        }
    }
    private func present(_ sheet: MacFormSheetController, completed: (@MainActor () -> Void)? = nil) {
        guard let window else { return }
        shell = sheet
        presentSheet(sheet, window.attachedSheet.map(MacWorkspaceAlerts.topmostSheet) ?? window) { [weak self, weak sheet] _ in
            guard let self, self.shell === sheet else { return }
            self.end()
            self.launcher.sheet = nil
            completed?()
        }
    }
    private func replaceSheet() {
        let previous = shell; shell = nil
        previous?.end()
        busyObservation.cancel()
    }
    private func showConnect(kind: CloudProviderKind, forCreation: Bool) {
        let model = MacConnectServerModel(serverType: kind)
        connect = model
        let sheet = MacFormSheetController(title: String(localized: "Connect to Server"),
            content: MacConnectServerSheet(model: model, showsTypePicker: !forCreation), size: NSSize(width: 560, height: 404))
        sheet.defaultButton.title = String(localized: "Connect")
        sheet.window?.setAccessibilityIdentifier("connect-server.sheet")
        let token = generation
        sheet.onConfirm = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            sheet.setBusy(true, label: String(localized: "Connect"))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let account = await model.connect()
                guard self.generation == token else { return }
                sheet.setBusy(false, label: "")
                if let account {
                    model.clearSecrets()
                    self.connect = nil
                    self.replaceSheet()
                    self.showBrowser(account: account, forCreation: forCreation)
                }
            }
        }
        present(sheet)
        busyObservation.start(reading: { (model.isConnecting, model.serverType) }, onChange: { [weak sheet] busy, kind in
            sheet?.setBusy(busy, label: String(localized: "Connect"))
            let prefix = kind == .webDAV ? "webdav.connect" : "ftp.connect"
            sheet?.cancelButton.setAccessibilityIdentifier(prefix + ".cancel")
            sheet?.defaultButton.setAccessibilityIdentifier(prefix + ".submit")
        })
    }
    private func showBrowser(account: CloudAccount, forCreation: Bool) {
        guard let provider = CloudProviderRegistry.provider(for: account.provider) else { return }
        let model = MacRemoteBrowserModel(account: account, mode: forCreation ? .chooseFolder : .chooseDatabase)
        let controller = MacRemoteBrowserViewController(model: model, provider: provider)
        browser = controller
        let allFiles = NSButton(checkboxWithTitle: String(localized: "Show All Files"), target: nil, action: nil)
        allFiles.target = self; allFiles.action = #selector(toggleAllFiles(_:))
        allFiles.setAccessibilityIdentifier("cloud.browser.show-all-files.toggle")
        let sheet = MacFormSheetController(title: provider.displayName, content: controller,
            size: NSSize(width: 640, height: 560),
            defaultTitle: forCreation ? String(localized: "Create Here") : String(localized: "Open"),
            accessory: forCreation ? nil : allFiles)
        sheet.defaultButton.setAccessibilityIdentifier(forCreation ? "cloud.folder.create-here" : "remote-browser.open")
        sheet.canConfirm = false
        controller.didChange = { [weak sheet, weak allFiles] in
            sheet?.canConfirm = model.canOpen
            allFiles?.state = model.showsAllFiles ? .on : .off
        }
        controller.didOpen = { [weak sheet] in sheet?.performDefault() }
        let token = generation
        sheet.onConfirm = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            if forCreation, let creation = self.creation {
                sheet.setBusy(true, label: String(localized: "Creating Database"))
                Task { @MainActor [weak self] in
                    let created = await creation.createInCloud(provider: account.provider, accountID: account.id, folderPath: model.path)
                    guard let self, self.generation == token else { return }
                    if let created { self.finishCreation(created) }
                    else {
                        sheet.setBusy(false, label: "")
                        self.showError(creation.creationError ?? creation.validationError ?? "")
                    }
                }
            } else if let selection = model.databaseSelection() {
                let reference = self.list.addCloudDatabase(selection: selection)
                self.end(); self.launcher.sheet = nil
                self.launcher.open(reference)
            }
        }
        present(sheet)
    }
    @objc private func toggleAllFiles(_ sender: NSButton) {
        browser?.model.showsAllFiles = sender.state == .on
    }
    private func showCreation() {
        let model = DatabaseCreationViewModel()
        creation = model
        let content = MacNewDatabaseSheet(model: model,
            selectKeyFile: { [weak self] in self?.selectKeyFile(create: false) },
            createKeyFile: { [weak self] in self?.selectKeyFile(create: true) })
        // Tall enough for Advanced Options to open without scrolling (NewDatabase board: 716 pt).
        let sheet = MacFormSheetController(title: String(localized: "New Database"), content: content,
                                          size: NSSize(width: 560, height: 660), maxHeight: 660)
        sheet.defaultButton.title = String(localized: "Create")
        sheet.defaultButton.setAccessibilityIdentifier("database-create.create-button")
        sheet.cancelButton.setAccessibilityIdentifier("database-create.cancel-button")
        let token = generation
        sheet.onConfirm = { [weak self] in
            guard let self else { return }
            guard model.validateForDestinationSelection() else { return }
            if let kind = model.destinationChoice.cloudProviderKind {
                self.replaceSheet()
                self.showConnect(kind: kind, forCreation: true)
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let created = await model.createLocal { [weak self] name in await self?.panels.saveNewDatabase(suggestedName: name) }
                    guard self.generation == token else { return }
                    if let created { self.finishCreation(created) }
                }
            }
        }
        present(sheet)
        busyObservation.start(reading: { model.isCreating }, onChange: { [weak sheet] busy in
            sheet?.setBusy(busy, label: String(localized: "Creating Database"))
        })
    }
    private func finishCreation(_ created: CreatedDatabase) {
        end(); launcher.sheet = nil; list.reload(); launcher.didCreate(created)
    }
    private func selectKeyFile(create: Bool) {
        guard let model = creation else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url: URL?
                if create {
                    url = await self.panels.saveKeyFile(suggestedName: KeyFileExportDocument.defaultFilename(forDatabaseFilename: model.suggestedFilename))
                    guard self.generation == token, let url else { return }
                    try await Task.detached {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try KeyFileOverwriteGuard.check(url)
                        var document = try KeyFileExportDocument.generate().data
                        defer { document.resetBytes(in: 0..<document.count) }
                        try document.write(to: url)
                    }.value
                } else { url = await self.panels.chooseKeyFile() }
                guard self.generation == token, let url else { return }
                try model.selectKeyFile(url: url)
            } catch { if self.generation == token { model.creationError = error.localizedDescription } }
        }
    }
    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Couldn’t Create Database")
        alert.informativeText = message
        alert.beginSheetModal(for: MacWorkspaceAlerts.topmostSheet(of: window))
    }
}
