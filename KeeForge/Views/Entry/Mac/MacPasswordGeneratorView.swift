#if os(macOS)
import SwiftUI

/// The editor's Generate popover (EditEntry board): its own `PasswordGeneratorModel`, whose
/// suggestion is dropped when the popover closes.
struct MacPasswordGeneratorPopover: View {
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = PasswordGeneratorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Password Generator")
                    .font(.headline)
                Spacer()
                regenerateButton
            }
            .padding(.bottom, 10)
            MacPasswordGeneratorControls(model: model)
            Button {
                onUse(model.suggestion)
                dismiss()
            } label: {
                Text("Use Password")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.suggestion.isEmpty)
            .accessibilityIdentifier("password-generator.use")
        }
        .padding(16)
        .frame(width: 320)
        .onDisappear { model.close() }
    }

    private var regenerateButton: some View {
        MacDetailIconButton(systemImage: "arrow.clockwise", label: String(localized: "Generate Another")) {
            model.regenerate()
        }
        .accessibilityIdentifier("password-generator.regenerate")
    }
}

/// The suggestion, kind, length or words, character sets and strength, shared by the generator
/// surfaces. The suggestion is not selectable: a system copy would bypass `ClipboardService`.
struct MacPasswordGeneratorControls: View {
    @Bindable var model: PasswordGeneratorModel

    private var isPassphrase: Bool { model.options.mode == .passphrase }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PasswordDisplayText(model.suggestion,
                                font: .system(size: isPassphrase ? 17 : 20, weight: .medium, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Text("Suggested Password"))
                .accessibilityValue(Text(verbatim: model.suggestion))
                .accessibilityIdentifier("password-generator.password")
            Picker("Generation Mode", selection: $model.options.mode) {
                Text("Password").tag(PasswordGenerator.Mode.characters)
                Text("Passphrase").tag(PasswordGenerator.Mode.passphrase)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("password-generator.mode")
            if isPassphrase {
                passphraseOptions
            } else {
                passwordOptions
            }
            Divider()
            if let strength = model.strength {
                HStack(spacing: 6) {
                    MacStrengthMeter(estimate: strength)
                    Text("· ~\(strength.roundedEntropyBits) bits")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.bottom, 12)
    }

    private var passwordOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Length")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(model.options.length) },
                        set: { model.options.length = Int($0.rounded()) }
                    ),
                    in: Double(PasswordGenerator.lengthRange.lowerBound)...Double(PasswordGenerator.lengthRange.upperBound),
                    step: 1
                )
                .labelsHidden()
                .accessibilityLabel(Text("Length"))
                .accessibilityValue(Text("\(model.options.length) characters"))
                .accessibilityIdentifier("password-generator.length-slider")
                TextField("Length", value: Binding(
                    get: { model.options.length },
                    set: { model.options.length = min(max($0, PasswordGenerator.lengthRange.lowerBound),
                                                      PasswordGenerator.lengthRange.upperBound) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .accessibilityIdentifier("password-generator.length-field")
            }
            HStack {
                charsetToggle("A–Z", label: "Uppercase", set: \.includeUppercase, id: "uppercase")
                Spacer()
                charsetToggle("a–z", label: "Lowercase", set: \.includeLowercase, id: "lowercase")
                Spacer()
                charsetToggle("0–9", label: "Digits", set: \.includeDigits, id: "digits")
                Spacer()
                charsetToggle("!@#", label: "Symbols", set: \.includeSymbols, id: "symbols")
            }
            Toggle("Exclude Look-Alike Characters", isOn: $model.options.excludeAmbiguous)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("password-generator.charset-toggle.ambiguous")
        }
    }

    private var passphraseOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Words")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("Words", value: Binding(
                    get: { model.options.wordCount },
                    set: { model.options.wordCount = min(max($0, PasswordGenerator.wordCountRange.lowerBound),
                                                         PasswordGenerator.wordCountRange.upperBound) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.center)
                .frame(width: 44)
                Stepper("Words", value: $model.options.wordCount, in: PasswordGenerator.wordCountRange)
                    .labelsHidden()
                    .accessibilityIdentifier("password-generator.word-count")
                Text("\(PasswordGenerator.wordCountRange.lowerBound) to \(PasswordGenerator.wordCountRange.upperBound)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Separator")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("Separator", text: $model.options.separator)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .frame(width: 44)
                    .accessibilityIdentifier("password-generator.separator")
            }
        }
    }

    private func charsetToggle(
        _ sample: String, label: LocalizedStringKey, set: PasswordGeneratorModel.Charset, id: String
    ) -> some View {
        Toggle(isOn: Binding(get: { model.isEnabled(set) }, set: { model.setEnabled(set, $0) })) {
            Text(verbatim: sample)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("password-generator.charset-toggle.\(id)")
    }
}
#endif
