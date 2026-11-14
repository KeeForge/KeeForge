#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI

// MARK: - Metrics and palette

/// The boards' detail grid: a 120 pt label column, 16 pt gaps, 36 pt rows; at the
/// window's minimum width the label column narrows to 88 and the strength loses its word.
struct MacDetailMetrics: Equatable {
    static let maximumContentWidth: CGFloat = 760
    static let headerIconSize: CGFloat = 72
    static let rowHeight: CGFloat = 36
    static let iconButtonSize: CGFloat = 28

    let labelWidth: CGFloat
    let columnGap: CGFloat
    let rowPadding: CGFloat
    let contentInsets: EdgeInsets
    let sectionGap: CGFloat
    let headerGap: CGFloat
    let showsStrengthWord: Bool

    static let regular = MacDetailMetrics(
        labelWidth: 120, columnGap: 16, rowPadding: 16,
        contentInsets: EdgeInsets(top: 12, leading: 48, bottom: 32, trailing: 48),
        sectionGap: 20, headerGap: 18, showsStrengthWord: true
    )
    static let compact = MacDetailMetrics(
        labelWidth: 88, columnGap: 12, rowPadding: 12,
        contentInsets: EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20),
        sectionGap: 14, headerGap: 14, showsStrengthWord: false
    )

    static func forWidth(_ width: CGFloat) -> MacDetailMetrics {
        width < 520 ? .compact : .regular
    }

    /// The footer lines up with the value column.
    var footerInset: CGFloat { rowPadding + labelWidth + columnGap }
}

extension EnvironmentValues {
    @Entry var macDetailMetrics = MacDetailMetrics.regular
}

enum MacDetailPalette {
    static let column = Color(nsColor: .textBackgroundColor)
    /// White on the white column in light mode; a step above the column in dark mode, where the
    /// system has no card colour.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : .textBackgroundColor
    })
}

extension MacEntryField.Kind {
    var isWebsite: Bool {
        if case .website = self { return true }
        return false
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

// MARK: - Card and row

struct MacDetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(MacDetailPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// One label/value row: the label right-aligned in its column, the value, then the row's buttons.
struct MacDetailRow<Value: View, Trailing: View>: View {
    let label: String
    var isFirst = false
    var minHeight: CGFloat = MacDetailMetrics.rowHeight
    var alignsTop = false
    @ViewBuilder let value: Value
    @ViewBuilder let trailing: Trailing
    @Environment(\.macDetailMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            if isFirst == false {
                Divider()
            }
            HStack(alignment: alignsTop ? .top : .center, spacing: metrics.columnGap) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(width: metrics.labelWidth, alignment: .trailing)
                    .padding(.top, alignsTop ? 1 : 0)
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    trailing
                }
            }
            .padding(.horizontal, metrics.rowPadding)
            .padding(.vertical, alignsTop ? 9 : 4)
            .frame(minHeight: minHeight)
        }
    }
}

// MARK: - Buttons

/// A 28 pt borderless icon button with a hover background, labelled and with the same help tag.
struct MacDetailIconButton: View {
    let systemImage: String
    let label: String
    var isOn = false
    /// Overrides the glyph's colour (the copy tick's green).
    var tone: Color?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(glyphStyle)
                .frame(width: MacDetailMetrics.iconButtonSize, height: MacDetailMetrics.iconButtonSize)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isOn ? AnyShapeStyle(.tint.opacity(0.16))
                              : isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .macHelp(label)
    }

    private var glyphStyle: AnyShapeStyle {
        if let tone { return AnyShapeStyle(tone) }
        return isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }
}

/// The row's copy button; for 1.5 seconds after any copy of this field (row, menu, shortcut,
/// list row menu) it shows the green tick and says what was copied.
struct MacCopyButton: View {
    let kind: MacEntryField.Kind
    let label: String
    let identifier: String
    let model: MacEntryDetailModel

    var body: some View {
        let copied = model.isShowingCopied(kind)
        MacDetailIconButton(systemImage: copied ? "checkmark" : "doc.on.doc",
                            label: copied ? copiedLabel : label, tone: copied ? Theme.State.success : nil) {
            model.copy(kind)
        }
        .disabled(model.isAuthenticating)
        .accessibilityIdentifier(identifier)
    }

    private var copiedLabel: String {
        MacCopyFeedback.Field.label(for: kind)
    }
}

/// The tick for a field whose row has no copy button (Website: Copy URL is in the Edit menu).
struct MacCopiedTick: View {
    let kind: MacEntryField.Kind
    let model: MacEntryDetailModel

    var body: some View {
        if model.isShowingCopied(kind) {
            Image(systemName: "checkmark")
                .font(.system(size: 14))
                .foregroundStyle(Theme.State.success)
                .frame(width: MacDetailMetrics.iconButtonSize, height: MacDetailMetrics.iconButtonSize)
                .accessibilityLabel(MacCopyFeedback.Field.label(for: kind))
        }
    }
}

extension MacCopyFeedback.Field {
    static func label(for kind: MacEntryField.Kind) -> String {
        switch kind {
        case .username: Self.username.copiedLabel
        case .password: Self.password.copiedLabel
        case .website(0): Self.url.copiedLabel
        case .website(let index): Self.additionalURL(index).copiedLabel
        case .verificationCode: Self.verificationCode.copiedLabel
        case .passkeyRelyingParty: Self.passkeyRelyingParty.copiedLabel
        case .passkeyUsername: Self.passkeyUsername.copiedLabel
        case .custom(let name): Self.customField(name).copiedLabel
        case .notes: ""
        }
    }
}

// MARK: - Field row

/// A field from `MacEntryDetailModel.fields`: plain text, a concealed mask, a revealed value,
/// a website link or the verification code, with the buttons the field allows.
struct MacEntryFieldRow: View {
    let field: MacEntryField
    let model: MacEntryDetailModel
    let isFirst: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch field.display {
        case .verificationCode:
            MacDetailRow(label: field.label, isFirst: isFirst, minHeight: 52) {
                if let config = model.verificationCodeConfig, let key = model.session.sessionKey {
                    MacVerificationCode(config: config, sessionKey: key) { model.copy(.verificationCode) }
                }
            } trailing: {
                copyButton
            }
        default:
            MacDetailRow(label: field.label, isFirst: isFirst) {
                value
            } trailing: {
                trailingButtons
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        switch field.display {
        case .plain(let text):
            if field.kind.isWebsite {
                websiteLink(text)
            } else {
                Text(text)
                    .font(field.kind.isCustom ? .body.monospaced() : .body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        case .concealed:
            Text(PasswordVisualStyle.concealedText)
                .font(.system(size: 14, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(field.kind == .password ? String(localized: "Hidden password")
                                    : String(localized: "Hidden protected field"))
        case .revealed(let text):
            // Never selectable: the copy button is the only copy path for a secret.
            HStack(spacing: 14) {
                if field.kind.isWebsite {
                    websiteLink(text)
                } else {
                    PasswordDisplayText(text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if field.kind == .password, let strength = model.passwordStrength {
                    MacStrengthMeter(estimate: strength)
                }
            }
        case .verificationCode:
            EmptyView()
        }
    }

    private func websiteLink(_ url: String) -> some View {
        Button {
            if let link = field.openableURL { openURL(link) }
        } label: {
            Text(MacEntryFormatting.website(url))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .disabled(field.openableURL == nil)
        .macHelp(url)
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if field.canReveal {
            let revealed = model.isRevealed(field.kind)
            MacDetailIconButton(
                systemImage: revealed ? "eye.slash" : "eye",
                label: revealed ? String(localized: "Hide \(field.label)") : String(localized: "Show \(field.label)"),
                isOn: revealed
            ) {
                model.toggleReveal(field.kind)
            }
            .disabled(model.isAuthenticating)
            .accessibilityIdentifier(revealIdentifier)
        }
        if field.kind.isWebsite {
            MacCopiedTick(kind: field.kind, model: model)
            if let link = field.openableURL {
                MacDetailIconButton(systemImage: "arrow.up.right.square", label: String(localized: "Open Website")) {
                    openURL(link)
                }
                .accessibilityIdentifier(openIdentifier)
            }
        } else if field.canCopy {
            copyButton
        }
    }

    private var copyButton: some View {
        MacCopyButton(kind: field.kind, label: copyLabel, identifier: copyIdentifier, model: model)
    }

    private var normalizedLabel: String {
        field.label.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private var revealIdentifier: String {
        field.kind == .password ? "entry.password.reveal" : "entry.protected-field.\(normalizedLabel).reveal"
    }

    private var openIdentifier: String {
        if case .website(let index) = field.kind, index > 0 { return "entry.url.open.\(index)" }
        return "entry.url.open"
    }

    private var copyIdentifier: String {
        switch field.kind {
        case .username: "entry.copy.username"
        case .password: "entry.copy.password"
        case .verificationCode: "entry.copy.totp"
        case .passkeyRelyingParty: "entry.copy.relying_party"
        case .passkeyUsername: "entry.copy.passkey_username"
        case .website, .custom, .notes: "entry.copy.\(normalizedLabel)"
        }
    }

    private var copyLabel: String {
        switch field.kind {
        case .username: String(localized: "Copy Username")
        case .password: String(localized: "Copy Password")
        case .verificationCode: String(localized: "Copy Verification Code")
        case .passkeyRelyingParty: String(localized: "Copy Relying Party")
        case .passkeyUsername: String(localized: "Copy Passkey Username")
        case .website, .custom, .notes: String(localized: "Copy \(field.label)")
        }
    }
}

/// Four bars and the rating, shown only beside a revealed password.
struct MacStrengthMeter: View {
    let estimate: PasswordStrengthEstimate
    @Environment(\.macDetailMetrics) private var metrics

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<PasswordVisualStyle.segmentCount, id: \.self) { index in
                    Capsule()
                        .fill(index < estimate.level.filledSegments ? color : Color.secondary.opacity(0.2))
                        .frame(width: metrics.showsStrengthWord ? 16 : 9, height: 4)
                }
            }
            if metrics.showsStrengthWord {
                Text(estimate.level.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(estimate.level.title)")
    }

    private var color: Color {
        switch estimate.level {
        case .veryWeak: Theme.State.danger
        case .weak: Theme.State.warning
        case .good, .veryGood: Theme.State.success
        }
    }
}

// MARK: - Verification code

/// The live code, grouped ("482 913"); clicking it copies, like the list's code.
struct MacVerificationCode: View {
    let config: TOTPConfig
    let sessionKey: SymmetricKey
    let onCopy: () -> Void
    @State private var totp: TOTPViewModel

    init(config: TOTPConfig, sessionKey: SymmetricKey, onCopy: @escaping () -> Void) {
        self.config = config
        self.sessionKey = sessionKey
        self.onCopy = onCopy
        _totp = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onCopy) {
                Text(totp.groupedCode)
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry.totp.code")
            .macHelp(String(localized: "Copy Verification Code"))
            MacCountdownRing(seconds: totp.secondsRemaining, progress: totp.progress)
                .frame(width: 24, height: 24)
        }
        .onAppear {
            totp.update(config: config, sessionKey: sessionKey)
            totp.start()
        }
        .onDisappear { totp.stop() }
        .onChange(of: config.secret) { refresh() }
        .onChange(of: config.decodedSecret) { refresh() }
        .onChange(of: config.period) { refresh() }
        .onChange(of: config.digits) { refresh() }
        .onChange(of: config.algorithm) { refresh() }
        .onChange(of: sessionKey) { refresh() }
    }

    private func refresh() {
        totp.update(config: config, sessionKey: sessionKey)
    }
}

/// The detail's ring: the tint, orange in a code's last seconds as in the list, with the seconds inside.
struct MacCountdownRing: View {
    let seconds: Int
    let progress: Double

    var body: some View {
        let isExpiring = seconds <= MacVerificationCodeClock.Display.expiringSeconds
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(isExpiring ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(seconds)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(1.2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(seconds) seconds remaining"))
    }
}

// MARK: - Passkey

struct MacPasskeyHeaderRow: View {
    let relyingParty: String

    var body: some View {
        MacDetailRow(label: String(localized: "Passkey"), isFirst: true, minHeight: 52) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.purple)
                    .frame(width: 26, height: 26)
                    .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved for \(relyingParty)")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("AutoFill offers this passkey when you sign in on that website.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("entry-detail.passkey")
        } trailing: {
            EmptyView()
        }
    }
}

// MARK: - Notes

/// Notes up to six lines, then Show More, which expands the row in place.
struct MacNotesRow: View {
    static let collapsedLineCount = 6

    let field: MacEntryField
    let model: MacEntryDetailModel
    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        MacDetailRow(label: field.label, isFirst: true, alignsTop: true) {
            VStack(alignment: .leading, spacing: 4) {
                switch field.display {
                case .plain(let text):
                    SelectableNotesText(text, maximumNumberOfLines: isExpanded ? 0 : Self.collapsedLineCount) {
                        isTruncated = $0
                    }
                    .accessibilityIdentifier("entry.notes")
                case .revealed(let text):
                    // A revealed secret is never selectable.
                    Text(text)
                        .lineLimit(isExpanded ? nil : Self.collapsedLineCount)
                        .accessibilityIdentifier("entry.notes")
                case .concealed, .verificationCode:
                    Text(PasswordVisualStyle.concealedText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "Hidden protected field"))
                }
                if isExpanded || isTruncated || revealedIsLong {
                    Button(isExpanded ? String(localized: "Show Less") : String(localized: "Show More")) {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("entry.notes.show-more")
                }
            }
        } trailing: {
            if field.canReveal {
                let revealed = model.isRevealed(field.kind)
                MacDetailIconButton(
                    systemImage: revealed ? "eye.slash" : "eye",
                    label: revealed ? String(localized: "Hide \(field.label)") : String(localized: "Show \(field.label)"),
                    isOn: revealed
                ) {
                    model.toggleReveal(field.kind)
                }
                .disabled(model.isAuthenticating)
                .accessibilityIdentifier("entry.protected-field.notes.reveal")
            }
        }
    }

    /// A revealed note is plain `Text`, which reports no truncation; count its lines instead.
    private var revealedIsLong: Bool {
        guard case .revealed(let text) = field.display else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLineCount
    }
}

// MARK: - Attachments

/// One attachment: click, the eye or Space opens Quick Look; Share opens the share picker.
/// A file the database no longer holds reads Unavailable and offers nothing.
struct MacAttachmentRow: View {
    let attachment: MacEntryDetailModel.Attachment
    let entryID: UUID
    let label: String
    let controller: MacAttachmentPreviewController
    let isFirst: Bool
    @State private var anchor = MacViewAnchor()
    @FocusState private var isFocused: Bool

    private var name: String { attachment.name.isEmpty ? "?" : attachment.name }
    private var isPreviewing: Bool { controller.isPreviewing(entryID: entryID, attachmentIndex: attachment.index) }
    private var isLoading: Bool {
        controller.previews.isLoading(entryID: entryID, attachmentIndex: attachment.index)
    }

    var body: some View {
        MacDetailRow(label: label, isFirst: isFirst) {
            Button(action: preview) {
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(name)
                        .fontWeight(isPreviewing ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "· \(sizeText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .foregroundStyle(attachment.isDangling ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(attachment.isDangling)
            .accessibilityIdentifier("entry.attachment.\(attachment.index)")
        } trailing: {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: MacDetailMetrics.iconButtonSize, height: MacDetailMetrics.iconButtonSize)
            }
            if attachment.isDangling == false {
                MacDetailIconButton(systemImage: "eye", label: String(localized: "Quick Look \(name)"),
                                    isOn: isPreviewing, action: preview)
                    .accessibilityIdentifier("entry.attachment.quick-look.\(attachment.index)")
                MacDetailIconButton(systemImage: "square.and.arrow.up", label: String(localized: "Share \(name)"),
                                    action: share)
                    .background(MacViewAnchorView(anchor: anchor))
                    .accessibilityIdentifier("entry.attachment.share.\(attachment.index)")
            }
        }
        .background(isPreviewing ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        .focusable(attachment.isDangling == false)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            controller.togglePreview(attachmentAt: attachment.index, ofEntry: entryID)
            return .handled
        }
        .contextMenu {
            if attachment.isDangling == false {
                Button("Quick Look", action: preview)
                Divider()
                Button("Share…", action: share)
            }
        }
    }

    private var sizeText: String {
        guard let byteCount = attachment.byteCount else { return String(localized: "Unavailable") }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// A click focuses the row, so Space then toggles Quick Look for it.
    private func preview() {
        isFocused = true
        controller.preview(attachmentAt: attachment.index, ofEntry: entryID)
    }

    private func share() {
        controller.share(attachmentAt: attachment.index, ofEntry: entryID, from: anchor.view)
    }
}

/// The AppKit view a share picker opens from.
@MainActor
final class MacViewAnchor {
    weak var view: NSView?
}

struct MacViewAnchorView: NSViewRepresentable {
    let anchor: MacViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

// MARK: - Tags

/// The entry's own tags, then the ones it gets from its groups, "shared (from Work)". Each
/// selects its tag in the sidebar.
struct MacTagsRow: View {
    let tags: MacEntryDetailModel.Tags
    let isFirst: Bool
    let onSelect: (String) -> Void

    var body: some View {
        MacDetailRow(label: String(localized: "Tags"), isFirst: isFirst) {
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.own.enumerated()), id: \.offset) { index, tag in
                    chip(Text(tag), tag: tag, isInherited: false)
                        .accessibilityIdentifier(
                            "entry-detail.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))"
                        )
                }
                ForEach(Array(tags.inherited.enumerated()), id: \.offset) { index, source in
                    chip(Text("\(source.tag) (from \(source.groupName))"), tag: source.tag, isInherited: true)
                        .accessibilityLabel(Text("\(source.tag), from a group"))
                        .accessibilityIdentifier(
                            "entry-detail.inherited-tag.\(TagAccessibility.identifierSuffix(for: source.tag, fallbackIndex: index))"
                        )
                }
            }
            .padding(.vertical, 5)
        } trailing: {
            EmptyView()
        }
    }

    private func chip(_ title: Text, tag: String, isInherited: Bool) -> some View {
        Button {
            onSelect(tag)
        } label: {
            title
                .font(.callout)
                .foregroundStyle(isInherited ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
    }
}
#endif
