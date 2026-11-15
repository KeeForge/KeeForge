import AppKit
import SwiftUI

/// Change Master Key, a sheet on Database Settings. Save asks for confirmation,
/// then the model authenticates the device owner, then it rekeys; ending the
/// sheet (Cancel, lock, close) clears the typed secrets but never cancels a
/// rekey already writing.
@MainActor
final class MacMasterKeySheet {
    let model: MasterKeyChangeViewModel
    let shell: MacFormSheetController
    let panels: MacFilePanels
    private let observation = MacObservation()
    private let layoutObservation = MacObservation()
    private var fittedLayout: LayoutState?
    private let databaseFilename: String
    private(set) var hasEnded = false
    var confirm: @MainActor (NSAlert, NSWindow) async -> Bool = { alert, window in
        await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
    var performChange: @MainActor (MasterKeyChangeViewModel) async -> Bool

    convenience init(session: DatabaseViewModel) {
        let reference = session.databaseReference
        let model = MasterKeyChangeViewModel(
            currentKeyFileFilename: reference.keyFileFilename,
            currentKeyFileBookmarkData: reference.keyFileBookmarkData,
            sessionKeyFileData: session.sessionKeyFileData,
            loadCurrentKeyFile: { [weak session] in await session?.loadAssociatedKeyFile() },
            changeOperation: { [weak session] password, keyFileData, bookmarkData, filename in
                guard let session else { throw DatabaseViewModel.RekeyError.sessionUnavailable }
                try await session.changeMasterKey(newPassword: password, newKeyFileData: keyFileData,
                                                  newKeyFileBookmarkData: bookmarkData, newKeyFileFilename: filename)
            })
        self.init(name: reference.displayName, databaseFilename: reference.filename, model: model,
                  performChange: { [weak session] model in
                      guard let session else { return false }
                      return await model.performConfirmedChange(session: session)
                  })
    }

    init(name: String, databaseFilename: String, model: MasterKeyChangeViewModel, panels: MacFilePanels = MacFilePanels(),
         canAuthenticateDeviceOwner: Bool = BiometricService.canAuthenticateDeviceOwner,
         performChange: @escaping @MainActor (MasterKeyChangeViewModel) async -> Bool) {
        self.model = model
        self.panels = panels
        self.databaseFilename = databaseFilename
        self.performChange = performChange
        let actions = MacMasterKeyActions()
        let footer = NSTextField(wrappingLabelWithString: Self.footerText(canAuthenticateDeviceOwner: canAuthenticateDeviceOwner))
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let host = NSHostingController(rootView: MacMasterKeyForm(model: model, actions: actions, scrolls: true).modifier(MacHostingAppearance()))
        host.sizingOptions = []
        shell = MacFormSheetController(title: String(localized: "\(name) — Master Key"), content: host,
                                       size: NSSize(width: 610, height: MacSheetMetrics.maxHeight), accessory: footer)
        shell.window?.setAccessibilityIdentifier("master-key.sheet")
        shell.cancelButton.setAccessibilityIdentifier("master-key.cancel")
        shell.defaultButton.setAccessibilityIdentifier("master-key.save")
        panels.window = shell.window
        actions.select = { [weak self] in self?.chooseKeyFile() }
        actions.create = { [weak self] in self?.createKeyFile() }
        shell.onConfirm = { [weak self] in
            guard let self else { return }
            Task { await self.save() }
        }
        shell.cancellationScope.register { [weak self] in self?.discard() }
        observation.start(reading: { (model.isAuthenticating || model.isWorking, model.canSave) }, onChange: { [weak self] busy, canSave in
            self?.shell.canConfirm = canSave
            self?.shell.setBusy(busy, label: String(localized: "Changing Master Key"))
        })
        layoutObservation.start(reading: { LayoutState(model: model) }, onChange: { [weak self] state in
            self?.fitToContent(state)
        })
    }

    /// The form parts that change the sheet's height.
    private struct LayoutState: Equatable {
        let message: String?
        let showsStrength: Bool
        let showsWeakWarning: Bool
        let hasKeyFile: Bool
        let keyFileSummary: String

        @MainActor init(model: MasterKeyChangeViewModel) {
            message = model.validationError ?? model.changeError
            showsStrength = !model.newPassword.isEmpty
            showsWeakWarning = model.passwordStrengthWarning != nil
            hasKeyFile = model.hasEffectiveKeyFile
            keyFileSummary = model.keyFileSummary
        }
    }

    private func fitToContent(_ state: LayoutState) {
        guard !hasEnded, state != fittedLayout, let window = shell.window, let content = window.contentView else { return }
        fittedLayout = state
        content.layoutSubtreeIfNeeded()
        let body = shell.bodyController.view.frame
        let probe = NSHostingController(rootView: MacMasterKeyForm(model: model, actions: MacMasterKeyActions(), scrolls: false)
            .modifier(MacHostingAppearance()))
        let form = probe.sizeThatFits(in: NSSize(width: body.width, height: .greatestFiniteMagnitude)).height
        let height = min((content.bounds.height - body.height + form).rounded(.up), MacSheetMetrics.maxHeight)
        guard abs(height - content.bounds.height) >= 1 else { return }
        window.setContentSize(NSSize(width: content.bounds.width, height: height))
    }

    func save() async {
        guard !hasEnded, !model.isWorking, !model.isAuthenticating, model.validate(), let window = shell.window else { return }
        let confirmed = await confirm(Self.confirmation(removingPassword: model.newPassword.isEmpty), window)
        guard confirmed, !hasEnded else { return }
        if await performChange(model), !hasEnded { shell.end(confirmed: true) }
    }

    /// Without device-owner authentication the change goes ahead after the confirmation alone, as on iOS.
    static func footerText(canAuthenticateDeviceOwner: Bool) -> String {
        canAuthenticateDeviceOwner
            ? String(localized: "You confirm with Touch ID or your Mac password before anything changes.")
            : String(localized: "Nothing changes until you confirm.")
    }

    static func confirmation(removingPassword: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let warning = String(localized: "This permanently re-encrypts the database file. It will open only with the new master key — if the new master password or key file is lost, the data in it cannot be recovered.")
        if removingPassword {
            alert.messageText = String(localized: "Save Without a Master Password?")
            alert.informativeText = warning + " " + String(localized: "The database will require only the key file to unlock. Anyone with the key file can open it.")
        } else {
            alert.messageText = String(localized: "Change Master Key?")
            alert.informativeText = warning
        }
        let change = alert.addButton(withTitle: removingPassword ? String(localized: "Save Without Password") : String(localized: "Change Master Key"))
        change.hasDestructiveAction = true
        change.setAccessibilityIdentifier("master-key.confirm-change")
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("master-key.cancel-change")
        return alert
    }

    private func discard() {
        hasEnded = true
        observation.cancel()
        layoutObservation.cancel()
        panels.cancel()
        model.cancelPendingChange()
    }

    func chooseKeyFile() {
        guard !hasEnded, !shell.isBusy else { return }
        Task { [weak self] in
            guard let self, let url = await panels.chooseKeyFile(), !hasEnded else { return }
            do { try model.selectKeyFile(url: url) } catch { model.changeError = error.localizedDescription }
        }
    }

    func createKeyFile() {
        guard !hasEnded, !shell.isBusy else { return }
        let name = KeyFileExportDocument.defaultFilename(forDatabaseFilename: databaseFilename)
        Task { [weak self] in
            guard let self, let url = await panels.saveKeyFile(suggestedName: name), !hasEnded else { return }
            do { try await model.createKeyFile(at: url) } catch {
                if !hasEnded { model.changeError = error.localizedDescription }
            }
        }
    }
}

@MainActor
private final class MacMasterKeyActions {
    var select: () -> Void = {}
    var create: () -> Void = {}
}

private struct MacMasterKeyForm: View {
    @Bindable var model: MasterKeyChangeViewModel
    let actions: MacMasterKeyActions
    let scrolls: Bool
    @State private var passwordVisible = false
    @State private var confirmationVisible = false

    var body: some View {
        if scrolls { ScrollView { form } } else { form }
    }

    private var form: some View {
        Form {
            if let error = model.validationError ?? model.changeError {
                LabeledContent("") {
                    Text(error).foregroundStyle(Theme.State.danger).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("master-key.error")
                }
            }
            LabeledContent("Master password:") {
                VStack(alignment: .leading, spacing: 6) {
                    PasswordInputRow(title: String(localized: "Master password"), text: $model.newPassword, isVisible: $passwordVisible,
                                     fieldAccessibilityIdentifier: "master-key.new-password-field",
                                     visibilityAccessibilityIdentifier: "master-key.new-password-visibility-button",
                                     usesPasswordAutoFill: false).labelsHidden()
                    if !model.newPassword.isEmpty {
                        PasswordStrengthIndicator(password: model.newPassword, caption: .passwordStrength)
                    }
                    if let warning = model.passwordStrengthWarning {
                        Text(warning).font(.caption).foregroundStyle(Theme.State.warning).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LabeledContent("Confirm password:") {
                VStack(alignment: .leading, spacing: 6) {
                    PasswordInputRow(title: String(localized: "Confirm password"), text: $model.confirmPassword, isVisible: $confirmationVisible,
                                     fieldAccessibilityIdentifier: "master-key.confirm-password-field",
                                     visibilityAccessibilityIdentifier: "master-key.confirm-password-visibility-button",
                                     usesPasswordAutoFill: false).labelsHidden()
                    caption(String(localized: "The new master key protects this database file from now on. Backups and copies made before the change still open with the previous master key."))
                }
            }
            Divider()
            LabeledContent("Key file:") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.keyFileSummary)
                    HStack {
                        Button("Select Key File…", action: actions.select).accessibilityIdentifier("master-key.keyfile.select")
                        Button("Create Key File…", action: actions.create).accessibilityIdentifier("master-key.keyfile.create")
                        if model.hasEffectiveKeyFile {
                            Button("Clear Key File") { model.clearKeyFile() }.accessibilityIdentifier("master-key.keyfile.clear")
                        }
                    }
                    caption(model.hasEffectiveKeyFile
                        ? String(localized: "The database requires this key file after the change. Clear it to unlock with the master password only.")
                        : String(localized: "No key file will be required after the change. The master password alone will unlock the database."))
                    caption(String(localized: "Create Key File saves a new key file where you choose. Keep a copy somewhere safe: without the key file, the database can’t be opened."))
                }
            }
        }
        .formStyle(.columns)
        .padding(.vertical, 4)
        .disabled(model.isAuthenticating || model.isWorking)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
