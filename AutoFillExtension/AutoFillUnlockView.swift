#if os(iOS)
import SwiftUI

/// The iOS AutoFill unlock: names the database it opens, then asks for its
/// master password or offers biometrics. It only collects input; the
/// coordinator decides what each answer does.
struct AutoFillUnlockView: View {
    let databaseName: String
    let filename: String
    /// Nil when this database has no biometric key to offer.
    let biometricOptionTitle: String?
    let onSubmitPassword: (String) -> Void
    let onChooseBiometrics: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: Theme.Spacing.textLine) {
                        Image(systemName: "lock.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                            .padding(.bottom, Theme.Spacing.cardGap)
                            .accessibilityHidden(true)
                        Text(databaseName)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("autofill-unlock.database-name")
                        if filename != databaseName {
                            Text(filename)
                                .font(Theme.Font.subhead)
                                .foregroundStyle(Theme.labelSecondary)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("autofill-unlock.filename")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear)
                }

                Section {
                    passwordField
                }

                Section {
                    Button(action: submit) {
                        Text("Unlock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("autofill-unlock.unlock")

                    if let biometricOptionTitle {
                        Button(biometricOptionTitle, action: onChooseBiometrics)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("autofill-unlock.biometrics")
                    }
                }
            }
            .navigationTitle("Unlock Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("autofill-unlock.cancel")
                }
            }
        }
    }

    /// Secure-only, as the alert it replaced was: no reveal inside another
    /// app's AutoFill request.
    private var passwordField: some View {
        SecureField("Master Password", text: $password)
            .passwordInputStyle()
            .focused($isPasswordFocused)
            // On the field, not the stack: the form builds its rows after the
            // stack appears, and focus set before then is dropped.
            .task { isPasswordFocused = true }
            .submitLabel(.go)
            .onSubmit(submit)
            .accessibilityIdentifier("autofill-unlock.password-field")
    }

    private func submit() {
        guard password.isEmpty == false else { return }
        let submitted = password
        password = ""
        onSubmitPassword(submitted)
    }
}
#endif
