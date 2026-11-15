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
            Form {
                TextField("Database name", text: $model.databaseName)
                    .accessibilityIdentifier("database-create.name-field")
                if let filename = model.filenamePreview {
                    caption(Text("Filename: \(filename)"))
                        .accessibilityIdentifier("database-create.filename")
                }
                if model.showsFilenameReplacementExplanation {
                    caption(Text("Unsupported filename characters are replaced with _."))
                        .accessibilityIdentifier("database-create.filename-explanation")
                }
                Picker("Save To", selection: $model.destinationChoice) {
                    ForEach(DatabaseCreationDestinationChoice.availableChoices) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("database-create.destination-picker")
                caption(Text("After you click Create, KeeForge asks where to save the encrypted .kdbx database. Other choices: WebDAV, FTP."))
                Divider()
                LabeledContent("Master password") { PasswordInputRow(title: String(localized: "Master password"), text: $model.password, isVisible: $passwordVisible,
                                 fieldAccessibilityIdentifier: "database-create.password-field",
                                 visibilityAccessibilityIdentifier: "database-create.password-visibility-button", usesPasswordAutoFill: false).labelsHidden() }
                LabeledContent("Confirm password") { PasswordInputRow(title: String(localized: "Confirm password"), text: $model.confirmPassword, isVisible: $confirmationVisible,
                                 fieldAccessibilityIdentifier: "database-create.confirm-password-field",
                                 visibilityAccessibilityIdentifier: "database-create.confirm-password-visibility-button", usesPasswordAutoFill: false).labelsHidden() }
                if !model.password.isEmpty {
                    LabeledContent("") { PasswordStrengthIndicator(password: model.password, caption: .passwordStrength) }
                }
                if let warning = model.passwordStrengthWarning { caption(Text(warning)) }
                caption(Text("Choose a long, unique master password: it protects the entire database and cannot be recovered if forgotten."))
                Divider()
                LabeledContent("Key File") {
                    VStack(alignment: .leading) {
                        Text(model.keyFileSummary)
                        HStack {
                            Button("Select Key File…", action: selectKeyFile).accessibilityIdentifier("database-create.keyfile.select")
                            Button("Create Key File…", action: createKeyFile).accessibilityIdentifier("database-create.keyfile.create")
                        }
                        if model.keyFileFilename != nil {
                            Button("Clear Key File") { model.clearKeyFile() }.accessibilityIdentifier("database-create.keyfile.clear")
                        }
                    }
                }
                caption(Text("Create Key File saves a new key file where you choose. Keep a copy somewhere safe: without the key file, the database can’t be opened."))
                Divider()
                LabeledContent("") {
                    DisclosureGroup("Advanced Options", isExpanded: $advanced) {
                        Picker("Encryption", selection: $model.cipher) {
                            ForEach(DatabaseCreationCipher.allCases) { Text($0.displayName).tag($0) }
                        }.accessibilityIdentifier("database-create.cipher-picker")
                        Picker("Key Derivation", selection: $model.kdfPreset) {
                            ForEach(DatabaseCreationKDFPreset.allCases) { Text($0.displayName).tag($0) }
                        }.accessibilityIdentifier("database-create.kdf-preset-picker")
                    }
                }
                caption(Text("\(model.cipher.displayName) with Argon2id key derivation (\(Int(model.kdfPreset.memoryBytes >> 20)) MB, \(Int(model.kdfPreset.iterations)) iterations). Most databases never need different settings."))
                if let error = model.validationError ?? model.creationError {
                    caption(Text(error).foregroundStyle(.red)).accessibilityIdentifier("database-create.error")
                }
            }
            .formStyle(.columns)
            .padding(.vertical, 4)
        }
    }
    private func caption(_ text: Text) -> some View {
        LabeledContent("") { text.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
