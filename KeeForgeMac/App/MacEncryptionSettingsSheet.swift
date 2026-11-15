import AppKit
import SwiftUI

/// Change Encryption Settings, a sheet on Database Settings. No confirmation
/// or authentication, as before; ending the sheet cancels a benchmark but never
/// a re-encryption already writing.
@MainActor
final class MacEncryptionSettingsSheet {
    let model: EncryptionSettingsViewModel
    let shell: MacFormSheetController
    private let observation = MacObservation()
    private(set) var hasEnded = false

    convenience init(session: DatabaseViewModel, current: KDBXFileSummary) {
        self.init(name: session.databaseReference.displayName, model: EncryptionSettingsViewModel(current: current,
            changeOperation: { [weak session] cipher, keyDerivation, isCompressed in
                guard let session else { throw DatabaseViewModel.EncryptionSettingsError.sessionUnavailable }
                try await session.changeEncryptionSettings(cipher: cipher, keyDerivation: keyDerivation, isCompressed: isCompressed)
            }))
    }

    init(name: String, model: EncryptionSettingsViewModel) {
        self.model = model
        let host = NSHostingController(rootView: MacEncryptionSettingsForm(model: model).modifier(MacHostingAppearance()))
        host.sizingOptions = []
        shell = MacFormSheetController(title: String(localized: "\(name) — Encryption Settings"), content: host,
                                       size: NSSize(width: 610, height: 420))
        shell.window?.setAccessibilityIdentifier("encryption-settings.sheet")
        shell.cancelButton.setAccessibilityIdentifier("encryption-settings.cancel")
        shell.defaultButton.setAccessibilityIdentifier("encryption-settings.save")
        shell.onConfirm = { [weak self] in
            guard let self else { return }
            Task { await self.save() }
        }
        shell.cancellationScope.register { [weak self] in self?.discard() }
        observation.start(reading: { (model.isWorking, model.canSave) }, onChange: { [weak self] state in
            self?.shell.canConfirm = state.1
            self?.shell.setBusy(state.0, label: String(localized: "Re-encrypting Database"))
        })
    }

    func save() async {
        guard !hasEnded else { return }
        if await model.performChange(), !hasEnded { shell.end(confirmed: true) }
    }

    private func discard() {
        hasEnded = true
        observation.cancel()
        model.cancelBenchmark()
    }
}

private struct MacEncryptionSettingsForm: View {
    @Bindable var model: EncryptionSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.State.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Most databases never need this").font(.headline)
                        Text("Saving re-encrypts this database file. It still opens with the same master key, and backups made before the change keep the previous settings.")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.State.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)

                Form {
                    if let error = model.changeError {
                        LabeledContent("") {
                            Text(error).foregroundStyle(Theme.State.danger).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("encryption-settings.error")
                        }
                    }
                    Picker("Encryption:", selection: $model.cipher) {
                        if model.showsCurrentCipherOption {
                            Text(model.currentCipherOptionTitle).tag(DatabaseCreationCipher?.none)
                            Divider()
                        }
                        ForEach(DatabaseCreationCipher.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("encryption-settings.cipher-picker")
                    LabeledContent("Key Derivation:") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Picker("Key Derivation:", selection: $model.keyDerivation) {
                                    if model.showsCurrentKDFOption {
                                        Text(model.currentKDFOptionTitle).tag(EncryptionSettingsViewModel.KeyDerivationOption?.none)
                                        Divider()
                                    }
                                    ForEach(EncryptionSettingsViewModel.KeyDerivationOption.allCases) { Text($0.displayName).tag(Optional($0)) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .accessibilityIdentifier("encryption-settings.kdf-preset-picker")
                                Button("Benchmark") { model.benchmark() }
                                    .disabled(!model.canBenchmark)
                                    .accessibilityIdentifier("encryption-settings.benchmark")
                            }
                            if model.showsAESKDFRounds {
                                HStack {
                                    Text("Rounds")
                                    TextField("Rounds", text: $model.aesKDFRoundsText).labelsHidden().frame(width: 140)
                                        .accessibilityIdentifier("encryption-settings.aes-kdf-rounds-field")
                                }
                                if let message = model.aesKDFRoundsError {
                                    Text(message).font(.caption).foregroundStyle(Theme.State.danger)
                                        .accessibilityIdentifier("encryption-settings.aes-kdf-rounds-error")
                                }
                            }
                            caption(Self.description(model))
                            if model.isBenchmarking {
                                ProgressView().controlSize(.small)
                            } else if let seconds = model.benchmarkSeconds {
                                Label(String(localized: "Benchmark: about \(seconds.formatted(.number.precision(.fractionLength(1)))) seconds to unlock on this Mac"),
                                      systemImage: "clock")
                                    .font(.caption)
                                    .accessibilityIdentifier("encryption-settings.benchmark-result")
                            } else if let error = model.benchmarkError {
                                caption(error)
                            }
                        }
                    }
                    Divider()
                    LabeledContent("Compression:") {
                        Toggle("Compress the database (GZip)", isOn: $model.isCompressed)
                            .accessibilityIdentifier("encryption-settings.compression-toggle")
                    }
                }
                .formStyle(.columns)
            }
            .padding(.vertical, 4)
        }
        .disabled(model.isWorking)
    }

    private static func description(_ model: EncryptionSettingsViewModel) -> String {
        let warning = String(localized: "Stronger settings take longer to unlock.")
        guard model.showsAESKDFRounds else { return model.keyDerivationSummary + " " + warning }
        let cipherNote = String(localized: "AES-KDF only strengthens the master key. The Encryption setting above still chooses the cipher that encrypts the database.")
        let summary = model.aesKDFRoundsError == nil ? [model.keyDerivationSummary] : []
        return (summary + [cipherNote, warning]).joined(separator: " ")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
