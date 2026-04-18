import CryptoKit
import SwiftUI

struct EntryDetailView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var activeEditor: EntryEditViewModel?

    private var entry: KPEntry? {
        viewModel.entry(withID: entryID)
    }

    private var sessionKey: SymmetricKey? {
        viewModel.sessionKey
    }

    var body: some View {
        Group {
            if let entry, let sessionKey {
                List {
                    Section {
                        HStack {
                            FaviconView(url: entry.url, iconID: entry.iconID, size: 40)
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                                .font(.title2.bold())
                        }
                    }

                    if !entry.username.isEmpty {
                        FieldRow(label: "Username", value: entry.username, icon: "person.fill")
                    }

                    if entry.hasPassword {
                        PasswordFieldRow(password: entry.password, sessionKey: sessionKey)
                    }

                    if !entry.url.isEmpty {
                        URLFieldRow(url: entry.url)
                    }

                    ForEach(Array(entry.additionalURLs.enumerated()), id: \.offset) { index, url in
                        URLFieldRow(url: url, label: "URL \(index + 2)")
                    }

                    if let totpConfig = entry.totpConfig {
                        TOTPSection(config: totpConfig, sessionKey: sessionKey)
                    }

                    if !entry.notes.isEmpty {
                        Section("Notes") {
                            Text(entry.notes)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }

                    if SettingsService.passkeyEnabled, let passkey = entry.passkeyCredential {
                        Section("Passkey") {
                            FieldRow(label: "Relying Party", value: passkey.relyingParty, icon: "person.badge.key.fill")
                            FieldRow(label: "Username", value: passkey.username, icon: "person.fill")
                        }
                    }

                    if !entry.displayCustomFields.isEmpty {
                        Section("Custom Fields") {
                            ForEach(entry.displayCustomFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                FieldRow(label: key, value: value, icon: "text.justify.left")
                            }
                        }
                    }

                    if !entry.tags.isEmpty {
                        Section("Tags") {
                            FlowLayout(spacing: 6) {
                                ForEach(entry.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.fill, in: .capsule)
                                }
                            }
                        }
                    }
                    if entry.creationTime != nil || entry.lastModificationTime != nil {
                        Section("Details") {
                            if let created = entry.creationTime {
                                LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let modified = entry.lastModificationTime {
                                LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if viewModel.isReadOnly {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Read-only database")
                                    .accessibilityIdentifier("database.read-only-indicator")
                            } else {
                                Button("Edit") {
                                    Task {
                                        let result = await viewModel.acknowledgeEditingIfNeeded()
                                        guard result == .acknowledged,
                                              let currentEntry = viewModel.entry(withID: entryID),
                                              let currentSessionKey = viewModel.sessionKey else { return }
                                        activeEditor = EntryEditViewModel(editing: currentEntry, sessionKey: currentSessionKey)
                                    }
                                }
                                .accessibilityIdentifier("entry-detail.edit")
                            }
                        }
                    }
                }
                .navigationDestination(item: $activeEditor) { formViewModel in
                    EntryEditView(
                        formViewModel: formViewModel,
                        databaseViewModel: viewModel
                    ) { completion in
                        activeEditor = nil
                        if completion == .deleted {
                            onClose()
                            dismiss()
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Entry Unavailable",
                    systemImage: "doc.badge.questionmark",
                    description: Text("This entry no longer exists in the current draft.")
                )
                .onAppear {
                    onClose()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Field Rows

struct FieldRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        Section(label) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(value)
                    .textSelection(.enabled)
                Spacer()
                CopyButton(text: value, accessibilityID: "entry.copy.\(normalizedLabel)")
            }
        }
    }

    private var normalizedLabel: String {
        label.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

struct PasswordFieldRow: View {
    let password: EncryptedValue
    let sessionKey: SymmetricKey
    @State private var revealed = false
    @State private var revealedText: String?
    @State private var authenticating = false

    var body: some View {
        Section("Password") {
            PasswordDisplayRow(revealedText: revealed ? revealedText : nil) {
                Button(action: toggleReveal) {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                        .font(.body)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .disabled(authenticating)
                .accessibilityIdentifier("entry.password.reveal")

                CopyButton(
                    resolveText: { (try? password.decrypt(using: sessionKey)) ?? "" },
                    requireAuth: true,
                    accessibilityID: "entry.copy.password"
                )
            }
        }
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
        guard !authenticating else { return }
        if BiometricService.isAvailable {
            authenticating = true
            Task {
                await MainActor.run {
                    BiometricService.isBiometricAuthInProgress = true
                }
                do {
                    _ = try await BiometricService.authenticate(reason: "View password")
                    await MainActor.run {
                        HapticService.success()
                        revealedText = (try? password.decrypt(using: sessionKey)) ?? ""
                        revealed = true
                    }
                } catch {
                    // Intentionally no-op on failed biometric auth.
                }
                await MainActor.run {
                    BiometricService.isBiometricAuthInProgress = false
                    authenticating = false
                }
            }
        } else {
            HapticService.tap()
            revealedText = (try? password.decrypt(using: sessionKey)) ?? ""
            revealed = true
        }
    }
}

struct PasswordDisplayRow<Actions: View>: View {
    let revealedText: String?
    private let actions: Actions

    init(
        revealedText: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.revealedText = revealedText
        self.actions = actions()
    }

    var body: some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            if let revealedText {
                PasswordDisplayText(revealedText)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(repeating: "\u{2022}", count: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            actions
        }
    }
}

struct PasswordDisplayText: View {
    let password: String

    init(_ password: String) {
        self.password = password
    }

    var body: some View {
        password.reduce(Text("")) { result, char in
            result + Text(String(char))
                .foregroundColor(color(for: char))
        }
        .font(.body.monospaced())
    }

    private func color(for char: Character) -> Color {
        if char.isLetter {
            return .primary
        } else if char.isNumber {
            return .blue
        } else {
            return .orange
        }
    }
}

struct URLFieldRow: View {
    let url: String
    var label: String = "URL"
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section(label) {
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(url)
                    .textSelection(.enabled)
                Spacer()
                if let link = URL(string: url) {
                    Button {
                        HapticService.tap()
                        openURL(link)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.body)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("entry.url.open")
                }
                CopyButton(text: url, accessibilityID: "entry.copy.url")
            }
        }
    }
}

struct CopyButton: View {
    private let resolveText: () -> String
    var requireAuth: Bool = false
    let accessibilityID: String
    @State private var copied = false

    /// Copy a plaintext value.
    init(text: String, requireAuth: Bool = false, accessibilityID: String) {
        self.resolveText = { text }
        self.requireAuth = requireAuth
        self.accessibilityID = accessibilityID
    }

    /// Copy a value that is decrypted lazily on demand.
    init(resolveText: @escaping () -> String, requireAuth: Bool = false, accessibilityID: String) {
        self.resolveText = resolveText
        self.requireAuth = requireAuth
        self.accessibilityID = accessibilityID
    }

    var body: some View {
        Button {
            if requireAuth && BiometricService.isAvailable {
                Task {
                    await MainActor.run {
                        BiometricService.isBiometricAuthInProgress = true
                    }
                    do {
                        _ = try await BiometricService.authenticate(reason: "Copy password")
                        await MainActor.run {
                            performCopy()
                        }
                    } catch {
                        // Intentionally no-op on failed biometric auth.
                    }
                    await MainActor.run {
                        BiometricService.isBiometricAuthInProgress = false
                    }
                }
            } else {
                performCopy()
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.body)
                .foregroundStyle(copied ? Color.green : Color.accentColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
        .accessibilityIdentifier(accessibilityID)
    }

    private func performCopy() {
        ClipboardService.copy(resolveText())
        copied = true
        HapticService.success()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - TOTP Section

struct TOTPSection: View {
    let config: TOTPConfig
    @State private var totpVM: TOTPViewModel

    init(config: TOTPConfig, sessionKey: SymmetricKey) {
        self.config = config
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        Section("One-Time Password") {
            HStack {
                CountdownRing(progress: totpVM.progress, seconds: totpVM.secondsRemaining)
                    .frame(width: 40, height: 40)

                Text(totpVM.code)
                    .font(.title.monospaced().bold())
                    .contentTransition(.numericText())

                Spacer()

                CopyButton(text: totpVM.code, accessibilityID: "entry.copy.totp")
            }
        }
        .onAppear { totpVM.start() }
        .onDisappear { totpVM.stop() }
    }
}

struct CountdownRing: View {
    let progress: Double
    let seconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 3)
                .foregroundStyle(.quaternary)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .foregroundStyle(progress > 0.3 ? .green : .orange)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)

            Text("\(seconds)")
                .font(.caption2.monospacedDigit())
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (offsets, CGSize(width: maxX, height: currentY + rowHeight))
    }
}
