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
                changeOperation: { [weak sessionViewModel] cipher, kdfPreset, isCompressed in
                    guard let sessionViewModel else {
                        throw DatabaseViewModel.EncryptionSettingsError.sessionUnavailable
                    }
                    try await sessionViewModel.changeEncryptionSettings(
                        cipher: cipher,
                        kdfPreset: kdfPreset,
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
                .disabled(viewModel.isWorking || viewModel.hasChanges == false)
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

            Picker("Key Derivation", selection: $viewModel.kdfPreset) {
                if viewModel.showsCurrentKDFOption {
                    Text(viewModel.currentKDFOptionTitle).tag(DatabaseCreationKDFPreset?.none)
                }
                ForEach(DatabaseCreationKDFPreset.allCases) { preset in
                    Text(preset.displayName).tag(Optional(preset))
                }
            }
            .accessibilityIdentifier("encryption-settings.kdf-preset-picker")
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
        return viewModel.keyDerivationSummary + " " + warning
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
