#if os(iOS)
import SwiftUI

/// The iOS generator sheet. The Mac editor uses `MacPasswordGeneratorPopover`.
struct PasswordGeneratorSheet: View {
    private var secondaryLabel: Color { Theme.labelSecondary }

    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = PasswordGeneratorModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Suggested Password") {
                    // Deliberately not selectable: the system copy path would bypass ClipboardService.
                    PasswordDisplayText(model.suggestion, isProminent: true)
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
                    Picker("Generation Mode", selection: $model.options.mode) {
                        Text("Password").tag(PasswordGenerator.Mode.characters)
                        Text("Passphrase").tag(PasswordGenerator.Mode.passphrase)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("password-generator.mode")
                }

                if model.options.mode == .passphrase {
                    Section("Passphrase Options") {
                        Stepper("Words: \(model.options.wordCount)", value: $model.options.wordCount,
                                in: PasswordGenerator.wordCountRange)
                            .accessibilityIdentifier("password-generator.word-count")
                        LabeledContent("Separator") {
                            TextField("Separator", text: $model.options.separator)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("password-generator.separator")
                        }
                    }
                } else {
                    Section("Length") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(model.options.length) characters")
                                    .font(.headline)
                                Spacer(minLength: 8)
                                Text(verbatim: "\(PasswordGenerator.lengthRange.lowerBound) – \(PasswordGenerator.lengthRange.upperBound)")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(secondaryLabel)
                                    .accessibilityHidden(true)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(model.options.length) },
                                    set: { model.options.length = Int($0.rounded()) }
                                ),
                                in: Double(PasswordGenerator.lengthRange.lowerBound)...Double(PasswordGenerator.lengthRange.upperBound),
                                step: 1
                            )
                            .accessibilityLabel(Text("Length"))
                            .accessibilityValue(Text("\(model.options.length) characters"))
                            .accessibilityIdentifier("password-generator.length-slider")
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Character Sets") {
                        charsetToggle("Uppercase", sample: "A–Z", sampleColor: secondaryLabel,
                                      isOn: charsetBinding(\.includeUppercase), id: "uppercase")
                        charsetToggle("Lowercase", sample: "a–z", sampleColor: secondaryLabel,
                                      isOn: charsetBinding(\.includeLowercase), id: "lowercase")
                        charsetToggle("Digits", sample: "0–9", sampleColor: Theme.digit,
                                      isOn: charsetBinding(\.includeDigits), id: "digits")
                        charsetToggle("Symbols", sample: "!#$&", sampleColor: Theme.symbol,
                                      isOn: charsetBinding(\.includeSymbols), id: "symbols")
                        Toggle("Exclude Ambiguous Characters", isOn: $model.options.excludeAmbiguous)
                            .accessibilityIdentifier("password-generator.charset-toggle.ambiguous")
                    }
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

                // Confirmation lives in the toolbar so it is visible without
                // scrolling on 4.7" screens (iPhone SE), where the old bottom
                // Form section sat below the fold.
                ToolbarItem(placement: .confirmationAction) {
                    // "Use", not "Use Password": the longer label squeezes the
                    // inline title into "Password Genera…" on 375pt screens.
                    Button("Use") {
                        onUse(model.suggestion)
                        dismiss()
                    }
                    .accessibilityIdentifier("password-generator.use")
                }
            }
            .onAppear {
                model.regenerate()
            }
            .onDisappear {
                model.close()
            }
        }
    }

    private var strengthIndicator: some View {
        PasswordStrengthIndicator(
            password: model.suggestion,
            maximumEntropyBits: model.maximumEntropyBits,
            caption: .rating
        )
    }

    private var suggestionActions: some View {
        HStack(spacing: 16) {
            Button {
                model.regenerate()
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

    private func charsetBinding(_ keyPath: PasswordGeneratorModel.Charset) -> Binding<Bool> {
        Binding(
            get: { model.isEnabled(keyPath) },
            set: { model.setEnabled(keyPath, $0) }
        )
    }
}
#endif
