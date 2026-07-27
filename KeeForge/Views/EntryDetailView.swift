import CryptoKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct EntryDetailView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onClose: () -> Void = {}
    /// Routes a tapped tag chip in shells that select instead of push (the iPad
    /// workspace, whose detail column has no browsing stack of its own, and
    /// macOS, which selects the tag in its sidebar). Left nil in the compact
    /// shell, where chips push `TagDestination.entries` like any other row.
    var onSelectTag: ((String) -> Void)? = nil
    /// False in the selection-driven shells (iPad detail column, macOS), where
    /// this screen is the detail root and closing means clearing the selection:
    /// their `dismiss` has nothing of this screen's to pop, so it bubbles out
    /// to the split view and pops the *sidebar's* navigation stack instead.
    var popsOnClose: Bool = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var activeEditor: EntryEditViewModel?
    /// Set when the editor completes a delete; the close then finishes in
    /// `onAppear`, a separate transaction from the editor pop (see `body`).
    @State private var closesAfterEditorDismissal = false
    /// Both `onAppear`s in `body` can fire on the same reveal, and each
    /// `dismiss()` would pop one navigation level.
    @State private var hasFinishedClosing = false

    /// Clears the regular shells' selection and pops this screen, at most once.
    private func finishClose() {
        guard hasFinishedClosing == false else { return }
        hasFinishedClosing = true
        onClose()
        if popsOnClose {
            dismiss()
        }
    }

    private var entry: KPEntry? {
        viewModel.entry(withID: entryID)
    }

    private var sessionKey: SymmetricKey? {
        viewModel.sessionKey
    }

    private var showsCompactLockButton: Bool {
        // `\.horizontalSizeClass` does not exist on macOS; the Mac app always
        // uses the regular layout.
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if let entry, let sessionKey {
                List {
                    Section {
                        HStack {
                            FaviconView(
                                url: entry.url,
                                iconID: entry.iconID,
                                size: 40,
                                customIconData: viewModel.customIconData(for: entry)
                            )
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                                .font(.title2.bold())
                        }
                    }

                    if entry.isExpired() {
                        Section {
                            Label("This entry has expired", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.vertical, 4)
                                .accessibilityIdentifier("entry-detail.expired-warning")
                        }
                    }

                    if !entry.username.isEmpty {
                        FieldRow(label: String(localized: "Username"), value: entry.username, icon: "person.fill", accessibilityKey: "username")
                    }

                    if entry.hasPassword {
                        PasswordFieldRow(password: entry.password, sessionKey: sessionKey)
                    }

                    if !entry.url.isEmpty {
                        URLFieldRow(url: entry.url)
                    }

                    ForEach(Array(entry.additionalURLs.enumerated()), id: \.offset) { index, url in
                        URLFieldRow(url: url, label: String(localized: "URL \(index + 2)"))
                    }

                    if let totpConfig = entry.totpConfig {
                        TOTPSection(config: totpConfig, sessionKey: sessionKey)
                    }

                    if !entry.notes.isEmpty {
                        Section("Notes") {
                            SelectableNotesText(entry.notes)
                                .accessibilityIdentifier("entry.notes")
                        }
                    }

                    if let passkey = entry.passkeyCredential {
                        Section("Passkey") {
                            FieldRow(label: String(localized: "Relying Party"), value: passkey.relyingParty, icon: "person.badge.key.fill", accessibilityKey: "relying_party")
                            FieldRow(label: String(localized: "Username"), value: passkey.username, icon: "person.fill", accessibilityKey: "username")
                        }
                    }

                    if !entry.displayCustomFields.isEmpty {
                        Section("Custom Fields") {
                            ForEach(entry.displayCustomFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                FieldRow(label: key, value: value, icon: "text.justify.left")
                            }
                        }
                    }

                    if !entry.attachments.isEmpty {
                        AttachmentsSection(attachments: entry.attachments, viewModel: viewModel)
                    }

                    if !entry.tags.isEmpty {
                        Section("Tags") {
                            FlowLayout(spacing: 6) {
                                // Enumerated rather than `id: \.self` so a
                                // foreign file repeating a tag still renders
                                // both chips with distinct identifiers.
                                ForEach(Array(entry.tags.enumerated()), id: \.offset) { index, tag in
                                    tagChip(tag, fallbackIndex: index)
                                }
                            }
                        }
                    }
                    if entry.creationTime != nil ||
                        entry.lastModificationTime != nil ||
                        entry.enabledExpiryTime != nil {
                        Section("Details") {
                            if let created = entry.creationTime {
                                LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let modified = entry.lastModificationTime {
                                LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let expiry = entry.enabledExpiryTime {
                                LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                                    .accessibilityIdentifier("entry-detail.expiry")
                            }
                        }
                    }
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsCompactLockButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Lock") {
                                viewModel.lockRequest(manuallyTriggered: true)
                            }
                            .accessibilityIdentifier("lock.button")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if let warningText = viewModel.cloudSyncBannerText {
                                CloudSyncWarningButton(message: warningText)
                            }

                            if viewModel.isReadOnly {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Read-only database")
                                    .accessibilityIdentifier("database.read-only-indicator")
                            } else {
                                Button("Edit") {
                                    guard let currentEntry = viewModel.entry(withID: entryID),
                                          let currentSessionKey = viewModel.sessionKey else { return }
                                    activeEditor = EntryEditViewModel(
                                        editing: currentEntry,
                                        sessionKey: currentSessionKey,
                                        knownTags: viewModel.tagsInDisplayOrder,
                                        inheritedTags: viewModel.inheritedTags(forEntryID: entryID)
                                    )
                                }
                                .accessibilityIdentifier("entry-detail.edit")
                            }
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
                    // Mid-editor the vanished entry is the editor's own doing
                    // (permanent delete): its completion drives the close, so
                    // the editor pops cleanly after the save instead of being
                    // torn down mid-flight. On the iPad detail root this
                    // onAppear fires even while the editor covers it.
                    guard activeEditor == nil else { return }
                    finishClose()
                }
            }
        }
        // Outside the entry branch: a permanent delete removes the entry while
        // the editor is the topmost pushed view, and a branch-scoped
        // `navigationDestination` would be torn down with no way to pop it.
        .modifier(EntryEditorPresentation(view: self))
        // Re-fires when the pushed editor pops back. The close must wait for
        // this later transaction — popping the editor and this screen together
        // drops the second pop on iOS 26. `entry == nil` catches an editor
        // dismissed any other way (e.g. cancelled) over a vanished entry.
        .onAppear {
            let editorJustPopped = closesAfterEditorDismissal
            closesAfterEditorDismissal = false
            if editorJustPopped || (activeEditor == nil && entry == nil) {
                finishClose()
            }
        }
    }

    /// One tag capsule, a shortcut into that tag's filtered entry list. Follows
    /// the link-or-callback shape the row helpers elsewhere use, so the compact
    /// stack pushes while the iPad and macOS shells route through their own
    /// browsing surface.
    @ViewBuilder
    private func tagChip(_ tag: String, fallbackIndex: Int) -> some View {
        let identifier = "entry-detail.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        if let onSelectTag {
            Button {
                onSelectTag(tag)
            } label: {
                TagCapsule(tag: tag)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        } else {
            NavigationLink(value: TagDestination.entries(tag: tag)) {
                TagCapsule(tag: tag)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }
    }

    /// Presents the entry editor. iOS pushes onto the navigation stack;
    /// macOS presents a sheet (navigation-stack pushes inside the split-view
    /// columns misrender on macOS).
    private struct EntryEditorPresentation: ViewModifier {
        let view: EntryDetailView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .sheet(item: view.$activeEditor) { formViewModel in
                    NavigationStack {
                        editor(formViewModel)
                    }
                    .frame(minWidth: 540, minHeight: 560)
                }
            #else
            content
                .navigationDestination(item: view.$activeEditor) { formViewModel in
                    editor(formViewModel)
                }
            #endif
        }

        private func editor(_ formViewModel: EntryEditViewModel) -> some View {
            EntryEditView(
                formViewModel: formViewModel,
                databaseViewModel: view.viewModel
            ) { completion in
                view.activeEditor = nil
                if completion == .deleted {
                    // iOS pops only the editor here; `onAppear` in `body`
                    // finishes the close once the pop lands. macOS sheets never
                    // re-fire the presenter's `onAppear`, so close directly.
                    #if os(macOS)
                    view.finishClose()
                    #else
                    view.closesAfterEditorDismissal = true
                    #endif
                }
            }
        }
    }
}

/// The capsule label shared by both chip shapes here and by the entry editor's
/// suggestion strip, so a tag looks the same wherever it is tappable.
/// `systemImage` is nil on this screen, where a chip navigates to the tag, and
/// `plus` in the editor, where it adds the tag to the field.
struct TagCapsule: View {
    let tag: String
    var systemImage: String? = nil
    /// Drawn after the name instead of before it. The editor's removable pills
    /// use it so the affordance reads as "tag, then remove" rather than
    /// "action, then tag" the way the leading `plus` suggestions do.
    var trailingSystemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }

            Text(tag)
                .lineLimit(1)
                .truncationMode(.tail)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill, in: .capsule)
    }
}

#if os(iOS)
private struct SelectableNotesText: UIViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }

        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(fittingSize)
        return CGSize(width: width, height: size.height)
    }
}
#else
/// Interim macOS notes rendering — plain `Text` with `.textSelection(.enabled)`
/// stands in for the UIKit `UITextView` wrapper until slice 02's view polish.
private struct SelectableNotesText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

// MARK: - Field Rows

struct FieldRow: View {
    let label: String
    let value: String
    let icon: String
    // Locale-independent copy-button ID; defaults to the normalized label so
    // user-defined custom field keys keep their existing identifiers.
    var accessibilityKey: String?

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
        accessibilityKey ?? label.lowercased().replacingOccurrences(of: " ", with: "_")
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
        .onChange(of: password) { _, updatedPassword in
            guard revealed else { return }
            revealedText = (try? updatedPassword.decrypt(using: sessionKey)) ?? ""
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
        // Gate on device-owner authentication (biometrics OR passcode/login
        // password/Apple Watch), not on biometrics availability: a Mac
        // without Touch ID or an iPhone without enrolled Face ID must still
        // prompt for the login password/passcode instead of revealing with a
        // single unauthenticated click. Auth is skipped only when the device
        // has no protection configured at all.
        if BiometricService.canAuthenticateDeviceOwner {
            authenticating = true
            Task {
                await MainActor.run {
                    BiometricService.isBiometricAuthInProgress = true
                }
                do {
                    _ = try await BiometricService.authenticateDeviceOwner(reason: "View password")
                    await MainActor.run {
                        HapticService.success()
                        revealedText = (try? password.decrypt(using: sessionKey)) ?? ""
                        revealed = true
                    }
                } catch {
                    // Intentionally no-op on failed authentication.
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

struct URLFieldRow: View {
    let url: String
    var label: String = String(localized: "URL")
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
            // Same device-owner gate as password reveal: biometrics when
            // available, passcode/login password/Apple Watch fallback
            // otherwise. Skipped only when the device has no protection.
            if requireAuth && BiometricService.canAuthenticateDeviceOwner {
                Task {
                    await MainActor.run {
                        BiometricService.isBiometricAuthInProgress = true
                    }
                    do {
                        _ = try await BiometricService.authenticateDeviceOwner(reason: "Copy password")
                        await MainActor.run {
                            performCopy()
                        }
                    } catch {
                        // Intentionally no-op on failed authentication.
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
                    .accessibilityIdentifier("entry.totp.code")

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
            // The measured size, not `.unspecified`: a subview clamped to the
            // row width has to be handed that width to render its truncation.
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    /// A subview wider than the row is clamped to the row rather than allowed
    /// to overhang: wrapping cannot save it (it is alone on its line), so
    /// without the clamp it reports a width past the proposal and drags the
    /// whole container — in a `Form`, the enclosing row and its label — wider
    /// than the layout it sits in. A long tag is the realistic case.
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            // `currentX` carries the trailing spacing for the next subview;
            // the row's own right edge is that spacing back.
            maxX = max(maxX, currentX - spacing)
        }

        return (offsets, sizes, CGSize(width: maxX, height: currentY + rowHeight))
    }
}
