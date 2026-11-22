import SwiftUI

struct MacNewDatabaseSheet: View {
    @Bindable var model: DatabaseCreationViewModel
    let selectKeyFile: () -> Void
    let createKeyFile: () -> Void
    @State private var advanced = false
    @State private var passwordVisible = false
    @State private var confirmationVisible = false

    var body: some View {
        ScrollView {
            MacSettingsForm(rowSpacing: MacSheetFormMetrics.rowSpacing) {
                MacSettingsRow("Database name:") {
                    TextField("Database name:", text: $model.databaseName, prompt: Text(verbatim: "")).labelsHidden()
                        .accessibilityIdentifier("database-create.name-field")
                    if let filename = model.filenamePreview {
                        caption(Text("Filename: \(filename)"))
                            .accessibilityIdentifier("database-create.filename")
                    }
                    if model.showsFilenameReplacementExplanation {
                        caption(Text("Unsupported filename characters are replaced with _."))
                            .accessibilityIdentifier("database-create.filename-explanation")
                    }
                }
                MacSettingsRow("Save To:") {
                    Picker("Save To:", selection: $model.destinationChoice) {
                        ForEach(DatabaseCreationDestinationChoice.availableChoices) { Text($0.title).tag($0) }
                    }
                    .macSettingsPopUp()
                    .accessibilityIdentifier("database-create.destination-picker")
                    caption(Text("After you click Create, KeeForge asks where to save the encrypted .kdbx database. Other choices: WebDAV, FTP."))
                }
                MacSettingsSeparator()
                MacSettingsRow("Master password:") {
                    PasswordInputRow(title: String(localized: "Master password"), text: $model.password, isVisible: $passwordVisible,
                                     fieldAccessibilityIdentifier: "database-create.password-field",
                                     visibilityAccessibilityIdentifier: "database-create.password-visibility-button",
                                     usesPasswordAutoFill: false, prompt: Text(verbatim: "")).labelsHidden()
                }
                MacSettingsRow("Confirm password:") {
                    PasswordInputRow(title: String(localized: "Confirm password"), text: $model.confirmPassword, isVisible: $confirmationVisible,
                                     fieldAccessibilityIdentifier: "database-create.confirm-password-field",
                                     visibilityAccessibilityIdentifier: "database-create.confirm-password-visibility-button",
                                     usesPasswordAutoFill: false, prompt: Text(verbatim: "")).labelsHidden()
                    if !model.password.isEmpty {
                        PasswordStrengthIndicator(password: model.password, caption: .passwordStrength)
                    }
                    if let warning = model.passwordStrengthWarning { caption(Text(warning)) }
                    caption(Text("Choose a long, unique master password: it protects the entire database and cannot be recovered if forgotten."))
                }
                MacSettingsSeparator()
                MacSettingsRow("Key file:") {
                    Text(model.keyFileSummary)
                    HStack {
                        Button("Select Key File…", action: selectKeyFile).accessibilityIdentifier("database-create.keyfile.select")
                        Button("Create Key File…", action: createKeyFile).accessibilityIdentifier("database-create.keyfile.create")
                    }
                    if model.keyFileFilename != nil {
                        Button("Clear Key File") { model.clearKeyFile() }.accessibilityIdentifier("database-create.keyfile.clear")
                    }
                    caption(Text("Create Key File saves a new key file where you choose. Keep a copy somewhere safe: without the key file, the database can’t be opened."))
                }
                if model.hardwareKeyOptions.isEmpty == false {
                    MacSettingsSeparator()
                    MacSettingsRow("Hardware key:") {
                        Picker("Hardware key", selection: $model.hardwareKeyChoice) {
                            Text("None").tag(HardwareKeyConfiguration?.none)
                            ForEach(model.hardwareKeyOptions, id: \.self) { option in
                                Text(option.title).tag(Optional(option))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("database-create.hardware-key.picker")
                        caption(Text(model.isAwaitingHardwareKey
                            ? HardwareKeyService.prompt(for: .usb)
                            : String(localized: "The YubiKey's slot must be set up for HMAC-SHA1 challenge-response. Without the YubiKey, the database can't be opened.")))
                    }
                }
                MacSettingsSeparator()
                MacSettingsRow {
                    // A plain toggle rather than DisclosureGroup: the rows it reveals sit on the form's own grid,
                    // below it, so opening and closing moves nothing above them.
                    Button { advanced.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(advanced ? 90 : 0))
                                .frame(width: 10)
                            Text("Advanced Options")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("database-create.advanced-options")
                    caption(Text("\(model.cipher.displayName) with Argon2id key derivation (\(Int(model.kdfPreset.memoryBytes >> 20)) MB, \(Int(model.kdfPreset.iterations)) iterations). Most databases never need different settings."))
                }
                if advanced {
                    MacSettingsRow("Encryption:") {
                        Picker("Encryption:", selection: $model.cipher) {
                            ForEach(DatabaseCreationCipher.allCases) { Text($0.displayName).tag($0) }
                        }
                        .macSettingsPopUp()
                        .accessibilityIdentifier("database-create.cipher-picker")
                    }
                    MacSettingsRow("Key Derivation:") {
                        Picker("Key Derivation:", selection: $model.kdfPreset) {
                            ForEach(DatabaseCreationKDFPreset.allCases) { Text($0.displayName).tag($0) }
                        }
                        .macSettingsPopUp()
                        .accessibilityIdentifier("database-create.kdf-preset-picker")
                    }
                }
                if let error = model.validationError ?? model.creationError {
                    MacSettingsRow {
                        caption(Text(error).foregroundStyle(.red)).accessibilityIdentifier("database-create.error")
                    }
                }
            }
            .transaction { $0.animation = nil }
            .frame(width: MacSheetFormMetrics.gridWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func caption(_ text: Text) -> some View {
        text.macSettingsCaptionStyle()
    }
}
