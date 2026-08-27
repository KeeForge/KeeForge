import SwiftUI

struct PasswordGeneratorSheet: View {
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = SettingsService.passwordGeneratorOptions
    @State private var generatedPassword = PasswordGenerator.generate(
        options: SettingsService.passwordGeneratorOptions
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("Suggested Password") {
                    PasswordDisplayRow(revealedText: generatedPassword) {
                        HStack(spacing: 16) {
                            Button {
                                regenerate()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Regenerate")
                            .accessibilityIdentifier("password-generator.regenerate")
                            .macHelp(String(localized: "Regenerate"))

                            CopyButton(
                                text: generatedPassword,
                                accessibilityID: "password-generator.copy"
                            )
                        }
                    }
                }

                Section("Length") {
                    Slider(
                        value: Binding(
                            get: { Double(options.length) },
                            set: { options.length = Int($0.rounded()) }
                        ),
                        in: 8...64,
                        step: 1
                    )
                    .accessibilityIdentifier("password-generator.length-slider")

                    Text("\(options.length) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Character Sets") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Uppercase", isOn: charsetBinding(\.includeUppercase))
                            .accessibilityIdentifier("password-generator.charset-toggle.uppercase")
                        Toggle("Lowercase", isOn: charsetBinding(\.includeLowercase))
                            .accessibilityIdentifier("password-generator.charset-toggle.lowercase")
                        Toggle("Digits", isOn: charsetBinding(\.includeDigits))
                            .accessibilityIdentifier("password-generator.charset-toggle.digits")
                        Toggle("Symbols", isOn: charsetBinding(\.includeSymbols))
                            .accessibilityIdentifier("password-generator.charset-toggle.symbols")
                        Toggle("Exclude Ambiguous Characters", isOn: $options.excludeAmbiguous)
                            .accessibilityIdentifier("password-generator.charset-toggle.ambiguous")
                    }
                    .accessibilityIdentifier("password-generator.charset-toggle")
                }

            }
            .macGroupedForm()
            .navigationTitle("Password Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                // Confirmation lives in the toolbar so it is visible without
                // scrolling on 4.7" screens (iPhone SE), where the old bottom
                // Form section sat below the fold.
                ToolbarItem(placement: .confirmationAction) {
                    // "Use", not "Use Password": the longer label squeezes the
                    // inline title into "Password Genera…" on 375pt screens.
                    Button("Use") {
                        onUse(generatedPassword)
                        dismiss()
                    }
                    .accessibilityIdentifier("password-generator.use")
                }
            }
            .onAppear {
                regenerate()
            }
            .onChange(of: options) { _, newOptions in
                SettingsService.passwordGeneratorOptions = newOptions
                regenerate()
            }
        }
    }

    private func regenerate() {
        generatedPassword = PasswordGenerator.generate(options: options)
    }

    private var enabledCharsetCount: Int {
        [
            options.includeUppercase,
            options.includeLowercase,
            options.includeDigits,
            options.includeSymbols
        ]
        .filter { $0 }
        .count
    }

    /// Binding for a character-set toggle that refuses to disable the last
    /// enabled set. This keeps the UI in sync with `PasswordGenerator`, which
    /// silently re-enables lowercase when every set is off — otherwise the
    /// toggles would show all sets disabled while the password still contained
    /// lowercase characters.
    private func charsetBinding(
        _ keyPath: WritableKeyPath<PasswordGenerator.Options, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { newValue in
                if newValue == false && enabledCharsetCount <= 1 {
                    return
                }
                options[keyPath: keyPath] = newValue
            }
        )
    }
}
