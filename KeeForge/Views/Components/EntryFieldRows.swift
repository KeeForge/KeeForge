import CryptoKit
import SwiftUI

// MARK: - Field Rows

/// Gathers an entry's fields into one card of label/value rows.
struct EntryFieldsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        }
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    // Locale-independent copy-button ID; defaults to the normalized label so
    // user-defined custom field keys keep their existing identifiers.
    var accessibilityKey: String?
    /// Identifier namespace for the copy control, matching `PasswordFieldRow`.
    var accessibilityPrefix: String = "entry"

    var body: some View {
        LabeledContent {
            HStack(spacing: 0) {
                Text(value)
                    .foregroundStyle(Theme.labelSecondary)
                    .textSelection(.enabled)
                CopyButton(text: value, accessibilityID: "\(accessibilityPrefix).copy.\(normalizedLabel)")
            }
        } label: {
            Text(label)
        }
    }

    private var normalizedLabel: String {
        accessibilityKey ?? label.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

/// A field that is not protected itself shows and copies as a protected one
/// when its `{REF:…}` reaches a password or protected field: concealed, and
/// revealed or copied only behind the device-owner gate.
struct ReferenceAwareFieldRow<Plain: View>: View {
    let label: String
    let raw: String
    let viewModel: DatabaseViewModel
    var accessibilityPrefix: String = "entry"
    let isCurrent: @MainActor () -> Bool
    @ViewBuilder let plain: (String) -> Plain

    var body: some View {
        switch viewModel.fieldReferenceResolution(of: raw) {
        case .resolved(let value):
            plain(value)
        case .needsProtectedValue:
            ProtectedFieldRow(
                label: label,
                value: raw,
                secretAccess: viewModel.secretAccess,
                resolveReferences: viewModel.resolvingFieldReferencesIncludingProtectedValues,
                accessibilityPrefix: accessibilityPrefix,
                isCurrent: isCurrent
            )
        }
    }
}

struct ProtectedFieldRow: View {
    let label: String
    let value: String
    let secretAccess: SecretAccessGate
    /// Applied when the value is revealed or copied, behind the gate, so a
    /// `{REF:…}` shows and copies as what it points at.
    var resolveReferences: (String) -> String = { $0 }
    var accessibilityPrefix: String = "entry"
    var isCurrent: @MainActor () -> Bool
    @State private var revealed = false
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        cardRow
        .onChange(of: value) { invalidateReveal() }
        .onDisappear { invalidateReveal() }
    }

    /// Concealed beside its label, revealed below it. One container for both,
    /// so a reveal does not make the `List` swap rows (see `PasswordFieldRow`).
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
            if revealed {
                Text(label)
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                HStack(spacing: 0) {
                    Text(resolveReferences(value))
                        .font(.body.monospaced())
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.iconText)
                    controls
                }
            } else {
                LabeledContent {
                    HStack(spacing: 0) {
                        PasswordConcealedText(accessibilityLabel: String(localized: "Hidden protected field"))
                        controls
                    }
                } label: {
                    Text(label)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        Button(action: toggleReveal) {
            Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                .font(.body)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .disabled(secretAction.isAuthenticating)
        .accessibilityIdentifier("\(accessibilityPrefix).protected-field.\(normalizedLabel).reveal")
        .macHelp(revealed ? String(localized: "Hide \(label)") : String(localized: "Show \(label)"))

        CopyButton(
            resolveText: { resolveReferences(value) },
            secretAccess: secretAccess,
            authenticationReason: String(localized: "Copy protected field"),
            accessibilityID: "\(accessibilityPrefix).copy.\(normalizedLabel)",
            secretAction: secretAction,
            isCurrent: isCurrent
        )
    }

    private var normalizedLabel: String {
        label.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private func toggleReveal() {
        if revealed {
            HapticService.tap()
            revealed = false
            return
        }

        guard !secretAction.isAuthenticating, isCurrent() else { return }
        if secretAccess.requiresAuthentication {
            secretAction.perform(
                authenticate: {
                    try await secretAccess.authenticate(reason: String(localized: "View protected field"))
                },
                isCurrent: isCurrent,
                disclose: {
                    HapticService.success()
                    revealed = true
                }
            )
        } else {
            HapticService.tap()
            revealed = true
        }
    }

    private func invalidateReveal() {
        secretAction.invalidate()
        revealed = false
    }
}

struct PasswordFieldRow: View {
    let password: EncryptedValue
    let sessionKey: SymmetricKey
    let secretAccess: SecretAccessGate
    /// Applied to the decrypted plaintext before it is shown or copied, so a
    /// `{REF:…}` password reads and copies as the value it points at.
    var resolveReferences: (String) -> String = { $0 }
    /// Identifier namespace for the reveal and copy controls. Defaults to the live
    /// entry detail's long-standing `entry.*` ids; the history viewer passes its own
    /// so the two screens never contribute the same identifier to one hierarchy.
    var accessibilityPrefix: String = "entry"
    var isCurrent: @MainActor () -> Bool
    @State private var revealed = false
    @State private var revealedText: String?
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        cardRow
        .onChange(of: password) {
            secretAction.invalidate()
            refreshRevealedPassword()
        }
        .onChange(of: sessionKey) { invalidateReveal() }
        .onAppear { refreshRevealedPassword() }
        .onDisappear {
            secretAction.invalidate()
            revealedText = nil
        }
    }

    /// Concealed, the dots sit beside the label; revealed, the password takes
    /// the full width below it, with its strength underneath. One container
    /// for both: in a `List` a changed top-level view is a new row, whose
    /// `onDisappear`/`onAppear` would clear and reload the reveal forever.
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.iconText) {
            if revealed, let revealedText {
                Text("Password")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                HStack(spacing: 0) {
                    // No `.textSelection(.enabled)`: CopyButton is the only copy path.
                    PasswordDisplayText(revealedText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.iconText)
                    actions
                }
                PasswordStrengthIndicator(password: revealedText)
            } else {
                LabeledContent {
                    HStack(spacing: 0) {
                        PasswordConcealedText()
                        actions
                    }
                } label: {
                    Text("Password")
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: toggleReveal) {
            Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                .font(.body)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        #if os(iOS)
        .buttonStyle(.borderless)
        #endif
        .disabled(secretAction.isAuthenticating)
        .accessibilityLabel(revealTooltip)
        .accessibilityIdentifier("\(accessibilityPrefix).password.reveal")
        .macHelp(revealTooltip)

        CopyButton(
            resolveText: { plaintext(of: password) },
            secretAccess: secretAccess,
            accessibilityID: "\(accessibilityPrefix).copy.password",
            secretAction: secretAction,
            isCurrent: isCurrent
        )
    }

    /// Reuses the parameterized Show/Hide strings the password input row uses.
    private var revealTooltip: String {
        let field = String(localized: "Password")
        return revealed ? String(localized: "Hide \(field)") : String(localized: "Show \(field)")
    }

    private func plaintext(of value: EncryptedValue) -> String {
        resolveReferences((try? value.decrypt(using: sessionKey)) ?? "")
    }

    private func toggleReveal() {
        if revealed {
            HapticService.tap()
            revealed = false
            revealedText = nil
        } else {
            authenticateAndReveal()
        }
    }

    private func authenticateAndReveal() {
        guard !secretAction.isAuthenticating, isCurrent() else { return }
        // Gate on device-owner authentication (biometrics OR passcode/login
        // password/Apple Watch), not on biometrics availability: a Mac
        // without Touch ID or an iPhone without enrolled Face ID must still
        // prompt for the login password/passcode instead of revealing with a
        // single unauthenticated click. Auth is skipped only inside the
        // authentication grace period, or when the device has no protection
        // configured at all.
        if secretAccess.requiresAuthentication {
            secretAction.perform(
                authenticate: {
                    try await secretAccess.authenticate(reason: String(localized: "View password"))
                },
                isCurrent: isCurrent,
                disclose: {
                    HapticService.success()
                    revealedText = plaintext(of: password)
                    revealed = true
                }
            )
        } else {
            HapticService.tap()
            revealedText = plaintext(of: password)
            revealed = true
        }
    }

    private func invalidateReveal() {
        secretAction.invalidate()
        revealed = false
        revealedText = nil
    }

    private func refreshRevealedPassword() {
        guard revealed, isCurrent() else {
            revealedText = nil
            return
        }
        revealedText = plaintext(of: password)
    }
}

struct CopyButton: View {
    private let resolveText: () -> String
    /// Set for a protected value: the copy then waits on this gate.
    var secretAccess: SecretAccessGate?
    var authenticationReason: String = String(localized: "Copy password")
    let accessibilityID: String
    private let sharedSecretAction: EntrySecretAction?
    private let isCurrent: @MainActor () -> Bool
    @State private var localSecretAction = EntrySecretAction()
    @State private var copied = false
    @State private var copyFeedbackID = UUID()

    private var secretAction: EntrySecretAction { sharedSecretAction ?? localSecretAction }

    init(
        text: String,
        secretAccess: SecretAccessGate? = nil,
        authenticationReason: String = String(localized: "Copy password"),
        accessibilityID: String,
        secretAction: EntrySecretAction? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.init(
            resolveText: { text },
            secretAccess: secretAccess,
            authenticationReason: authenticationReason,
            accessibilityID: accessibilityID,
            secretAction: secretAction,
            isCurrent: isCurrent
        )
    }

    init(
        resolveText: @escaping () -> String,
        secretAccess: SecretAccessGate? = nil,
        authenticationReason: String = String(localized: "Copy password"),
        accessibilityID: String,
        secretAction: EntrySecretAction? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.resolveText = resolveText
        self.secretAccess = secretAccess
        self.authenticationReason = authenticationReason
        self.accessibilityID = accessibilityID
        self.sharedSecretAction = secretAction
        self.isCurrent = isCurrent
    }

    var body: some View {
        Button {
            // Same device-owner gate as password reveal: biometrics when
            // available, passcode/login password/Apple Watch fallback
            // otherwise. Skipped only inside the authentication grace period,
            // or when the device has no protection.
            guard isCurrent() else { return }
            if let secretAccess, secretAccess.requiresAuthentication {
                secretAction.perform(
                    authenticate: {
                        try await secretAccess.authenticate(reason: authenticationReason)
                    },
                    isCurrent: isCurrent,
                    disclose: performCopy
                )
            } else {
                performCopy()
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.body)
                .foregroundStyle(copied ? Theme.State.success : Color.accentColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
        .disabled(secretAction.isAuthenticating)
        .accessibilityIdentifier(accessibilityID)
        .macHelp(String(localized: "Copy"))
        .onDisappear {
            secretAction.invalidate()
            copied = false
        }
        .task(id: copyFeedbackID) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }

    private func performCopy() {
        ClipboardService.copy(resolveText())
        copied = true
        copyFeedbackID = UUID()
        HapticService.success()
    }
}

// MARK: - TOTP Section

struct TOTPSection: View {
    let config: TOTPConfig
    let sessionKey: SymmetricKey
    /// Identifier namespace, matching `FieldRow` / `PasswordFieldRow`.
    var accessibilityPrefix: String = "entry"
    @State private var totpVM: TOTPViewModel
    @ScaledMetric(relativeTo: .title3) private var cardRingSize = Theme.Size.badge

    init(config: TOTPConfig, sessionKey: SymmetricKey, accessibilityPrefix: String = "entry") {
        self.config = config
        self.sessionKey = sessionKey
        self.accessibilityPrefix = accessibilityPrefix
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.tileGap) {
                CountdownRing(progress: totpVM.progress, seconds: totpVM.secondsRemaining, showsSeconds: false)
                    .frame(width: cardRingSize, height: cardRingSize)
                    .accessibilityLabel(Text("\(totpVM.secondsRemaining) seconds remaining"))
                Text(totpVM.code)
                    .font(Theme.Font.codeRow)
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("\(accessibilityPrefix).totp.code")
                CopyButton(text: totpVM.code, accessibilityID: "\(accessibilityPrefix).copy.totp")
            }
        } label: {
            Text("One-Time Password")
        }
        .onAppear {
            updateTOTP()
            totpVM.start()
        }
        .onChange(of: config.secret) { updateTOTP() }
        .onChange(of: config.decodedSecret) { updateTOTP() }
        .onChange(of: config.period) { updateTOTP() }
        .onChange(of: config.digits) { updateTOTP() }
        .onChange(of: config.algorithm) { updateTOTP() }
        .onChange(of: sessionKey) { updateTOTP() }
        .onDisappear { totpVM.stop() }
    }

    private func updateTOTP() {
        totpVM.update(config: config, sessionKey: sessionKey)
    }
}

struct CountdownRing: View {
    let progress: Double
    let seconds: Int
    /// Off where the ring is too small to hold the number and the caller
    /// prints it beside the ring instead.
    var showsSeconds = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 3)
                .foregroundStyle(.quaternary)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .foregroundStyle(progress > 0.3 ? Theme.State.success : Theme.State.warning)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)

            if showsSeconds {
                Text("\(seconds)")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}
