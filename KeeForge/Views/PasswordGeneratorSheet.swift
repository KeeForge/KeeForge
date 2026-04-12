import SwiftUI

struct PasswordGeneratorSheet: View {
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = PasswordGenerator.Options()
    @State private var generatedPassword = PasswordGenerator.generate()

    var body: some View {
        NavigationStack {
            Form {
                Section("Suggested Password") {
                    PasswordDisplayRow(revealedText: generatedPassword) {
                        CopyButton(
                            text: generatedPassword,
                            accessibilityID: "password-generator.copy"
                        )
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
                        Toggle("Uppercase", isOn: $options.includeUppercase)
                            .accessibilityIdentifier("password-generator.charset-toggle.uppercase")
                        Toggle("Lowercase", isOn: $options.includeLowercase)
                            .accessibilityIdentifier("password-generator.charset-toggle.lowercase")
                        Toggle("Digits", isOn: $options.includeDigits)
                            .accessibilityIdentifier("password-generator.charset-toggle.digits")
                        Toggle("Symbols", isOn: $options.includeSymbols)
                            .accessibilityIdentifier("password-generator.charset-toggle.symbols")
                        Toggle("Exclude Ambiguous Characters", isOn: $options.excludeAmbiguous)
                            .accessibilityIdentifier("password-generator.charset-toggle.ambiguous")
                    }
                    .accessibilityIdentifier("password-generator.charset-toggle")
                }

                Section {
                    Button("Regenerate") {
                        regenerate()
                    }
                    .accessibilityIdentifier("password-generator.regenerate")

                    Button("Use Password") {
                        onUse(generatedPassword)
                        dismiss()
                    }
                    .accessibilityIdentifier("password-generator.use")
                }
            }
            .navigationTitle("Password Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                regenerate()
            }
            .onChange(of: options) { _, _ in
                regenerate()
            }
        }
    }

    private func regenerate() {
        generatedPassword = PasswordGenerator.generate(options: options)
    }
}
