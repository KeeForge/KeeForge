#if os(macOS)
import OneTimeCodes
import SwiftUI

/// Set Up Verification Code (CodeSetup board): one field for an `otpauth://` link or a setup key.
/// `onApply` fills the form and returns why a link cannot be used, which keeps the sheet open.
struct MacTOTPSetupSheet: View {
    let onApply: (String) -> OTPAuthURIError?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set Up Verification Code")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.top, 16)
            HStack(alignment: .top, spacing: 12) {
                Text("Setup link or key:")
                    .multilineTextAlignment(.trailing)
                    .frame(width: 118, alignment: .trailing)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        // Four lines: a typical otpauth:// link wraps to four at this width.
                        .frame(height: 74)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(verbatim: "otpauth://totp/…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .focused($isFieldFocused)
                        .accessibilityLabel(Text("Setup link or key:"))
                        .accessibilityIdentifier("entry-edit.totp.link-field")
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.State.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("entry-edit.totp.link-error")
                    }
                    Text("Paste the otpauth:// setup link, or the setup key the website shows beside its QR code. KeeForge for Mac does not scan QR codes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 28)
            .padding(.vertical, 18)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("entry-edit.totp.link-cancel")
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("entry-edit.totp.link-apply")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 480)
        .onAppear { isFieldFocused = true }
        .onChange(of: text) { errorMessage = nil }
    }

    private func apply() {
        if let error = onApply(text) {
            errorMessage = EntryEditViewModel.setupLinkMessage(for: error)
        } else {
            dismiss()
        }
    }
}
#endif
