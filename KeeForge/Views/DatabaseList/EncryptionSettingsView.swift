import SwiftUI

/// Change the cipher, key derivation, and compression of the unlocked
/// database. Pushed from `DatabaseDetailsView` inside its `NavigationStack`,
/// like `MasterKeyChangeView`.
struct EncryptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: EncryptionSettingsViewModel

    init(sessionViewModel: DatabaseViewModel, current: KDBXFileSummary) {
        _viewModel = State(
            initialValue: EncryptionSettingsViewModel(
                current: current,
                changeOperation: { [weak sessionViewModel] cipher, keyDerivation, isCompressed in
                    guard let sessionViewModel else {
                        throw DatabaseViewModel.EncryptionSettingsError.sessionUnavailable
                    }
                    try await sessionViewModel.changeEncryptionSettings(
                        cipher: cipher,
                        keyDerivation: keyDerivation,
                        isCompressed: isCompressed
                    )
                }
            )
        )
    }

    var body: some View {
        Form {
            encryptionSection
            compressionSection
        }
        .macGroupedForm()
        .disabled(viewModel.isWorking)
        .navigationTitle("Encryption Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(viewModel.isWorking)
        .interactiveDismissDisabled(viewModel.isWorking)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let changeError = viewModel.changeError {
                errorBanner(changeError)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            if viewModel.isWorking {
                ProgressView("Re-encrypting Database")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        if await viewModel.performChange() {
                            HapticService.success()
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.isWorking || viewModel.canSave == false)
                .accessibilityIdentifier("encryption-settings.save")
            }
        }
    }

    private var encryptionSection: some View {
        Section {
            Picker("Encryption", selection: $viewModel.cipher) {
                if viewModel.showsCurrentCipherOption {
                    Text(viewModel.currentCipherOptionTitle).tag(DatabaseCreationCipher?.none)
                }
                ForEach(DatabaseCreationCipher.allCases) { cipher in
                    Text(cipher.displayName).tag(Optional(cipher))
                }
            }
            .accessibilityIdentifier("encryption-settings.cipher-picker")

            Picker("Key Derivation", selection: $viewModel.keyDerivation) {
                if viewModel.showsCurrentKDFOption {
                    Text(viewModel.currentKDFOptionTitle)
                        .tag(EncryptionSettingsViewModel.KeyDerivationOption?.none)
                }
                ForEach(EncryptionSettingsViewModel.KeyDerivationOption.allCases) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .accessibilityIdentifier("encryption-settings.kdf-preset-picker")

            if viewModel.showsAESKDFRounds {
                LabeledContent("Rounds") {
                    TextField("Rounds", text: $viewModel.aesKDFRoundsText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .macLabelsHidden()
                        .macFormFieldStyle()
                        .accessibilityIdentifier("encryption-settings.aes-kdf-rounds-field")
                }

                if let message = viewModel.aesKDFRoundsError {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("encryption-settings.aes-kdf-rounds-error")
                }
            }
        } footer: {
            Text(encryptionFooter)
        }
    }

    private var compressionSection: some View {
        Section {
            Toggle("Compression", isOn: $viewModel.isCompressed)
                .accessibilityIdentifier("encryption-settings.compression-toggle")
        } footer: {
            Text("Saving re-encrypts this database file. It still opens with the same master key, and backups made before the change keep the previous settings.")
        }
    }

    private var encryptionFooter: String {
        #if os(macOS)
        let warning = String(localized: "Stronger settings take longer to unlock.")
        #else
        let warning = String(localized: "Stronger settings take longer to unlock and may exceed AutoFill's memory limit on some devices.")
        #endif
        guard viewModel.showsAESKDFRounds else {
            return viewModel.keyDerivationSummary + " " + warning
        }
        let cipherNote = String(localized: "AES-KDF only strengthens the master key. The Encryption setting above still chooses the cipher that encrypts the database.")
        // AES-KDF uses no extra memory, so AutoFill's memory limit does not apply.
        let aesKDFWarning = String(localized: "Stronger settings take longer to unlock.")
        // Invalid rounds already show their own error under the field.
        let summary = viewModel.aesKDFRoundsError == nil ? [viewModel.keyDerivationSummary] : []
        return (summary + [cipherNote, aesKDFWarning]).joined(separator: " ")
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("encryption-settings.error")
    }
}
