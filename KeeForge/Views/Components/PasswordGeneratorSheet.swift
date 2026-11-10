import SwiftUI

struct PasswordGeneratorSheet: View {
    private var secondaryLabel: Color { PlatformDesign.followsIOSDesign ? Theme.labelSecondary : .secondary }

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
                    // Deliberately not selectable: the system copy path would bypass ClipboardService.
                    PasswordDisplayText(generatedPassword, isProminent: true)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("password-generator.password")

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            strengthIndicator
                            Spacer(minLength: 0)
                            suggestionActions
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            strengthIndicator
                            suggestionActions
                        }
                    }
                }

                Section {
                    Picker("Generation Mode", selection: $options.mode) {
                        Text("Password").tag(PasswordGenerator.Mode.characters)
                        Text("Passphrase").tag(PasswordGenerator.Mode.passphrase)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("password-generator.mode")
                }

                if options.mode == .passphrase {
                    Section("Passphrase Options") {
                        Stepper("Words: \(options.wordCount)", value: $options.wordCount,
                                in: PasswordGenerator.wordCountRange)
                            .accessibilityIdentifier("password-generator.word-count")
                        LabeledContent("Separator") {
                            TextField("Separator", text: $options.separator)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .macFormFieldStyle()
                                .macLabelsHidden()
                                .multilineTextAlignment(PlatformDesign.followsIOSDesign ? .trailing : .leading)
                                .accessibilityIdentifier("password-generator.separator")
                        }
                    }
                } else {
                    Section("Length") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(options.length) characters")
                                    .font(.headline)
                                Spacer(minLength: 8)
                                Text(verbatim: "\(PasswordGenerator.lengthRange.lowerBound) – \(PasswordGenerator.lengthRange.upperBound)")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(secondaryLabel)
                                    .accessibilityHidden(true)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(options.length) },
                                    set: { options.length = Int($0.rounded()) }
                                ),
                                in: Double(PasswordGenerator.lengthRange.lowerBound)...Double(PasswordGenerator.lengthRange.upperBound),
                                step: 1
                            )
                            .accessibilityLabel(Text("Length"))
                            .accessibilityValue(Text("\(options.length) characters"))
                            .accessibilityIdentifier("password-generator.length-slider")
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Character Sets") {
                        charsetToggle("Uppercase", sample: "A–Z", sampleColor: secondaryLabel,
                                      isOn: charsetBinding(\.includeUppercase), id: "uppercase")
                        charsetToggle("Lowercase", sample: "a–z", sampleColor: secondaryLabel,
                                      isOn: charsetBinding(\.includeLowercase), id: "lowercase")
                        charsetToggle("Digits", sample: "0–9", sampleColor: PlatformDesign.followsIOSDesign ? Theme.digit : .blue,
                                      isOn: charsetBinding(\.includeDigits), id: "digits")
                        charsetToggle("Symbols", sample: "!#$&", sampleColor: PlatformDesign.followsIOSDesign ? Theme.symbol : .orange,
                                      isOn: charsetBinding(\.includeSymbols), id: "symbols")
                        Toggle("Exclude Ambiguous Characters", isOn: $options.excludeAmbiguous)
                            .accessibilityIdentifier("password-generator.charset-toggle.ambiguous")
                    }
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

    private var strengthIndicator: some View {
        PasswordStrengthIndicator(
            password: generatedPassword,
            maximumEntropyBits: PasswordGenerator.minimumEntropyBits(options: options),
            caption: .rating
        )
    }

    private var suggestionActions: some View {
        HStack(spacing: 16) {
            Button {
                regenerate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Regenerate")
                }
                .font(Theme.Font.subhead)
                .lineLimit(1)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("password-generator.regenerate")
            .macHelp(String(localized: "Regenerate"))

            #if os(macOS)
            CopyButton(
                text: generatedPassword,
                accessibilityID: "password-generator.copy"
            )
            #endif
        }
    }

    /// A character-set switch with a sample of the set, colored like the password.
    private func charsetToggle(
        _ title: LocalizedStringKey,
        sample: String,
        sampleColor: Color,
        isOn: Binding<Bool>,
        id: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                Text(verbatim: sample)
                    .font(.footnote.monospaced())
                    .foregroundStyle(sampleColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("password-generator.charset-toggle.\(id)")
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
