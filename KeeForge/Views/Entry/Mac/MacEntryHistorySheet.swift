#if os(macOS)
import SwiftUI

/// The Mac History sheet (History board): the versions on the left with the current one above
/// them, the selected version compared with the current entry on the right, and Restore… and Done.
/// Values, reveals and copies come from the session's `MacEntryDetailModel(.history)`; a protected
/// value stays masked until the gated reveal, and only "differs" is said about it ungated.
struct MacEntryHistorySheet: View {
    let history: MacEntryHistorySession
    let onClose: () -> Void

    @State private var isConfirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.versions.isEmpty {
                ContentUnavailableView(
                    "No Earlier Versions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Earlier versions appear here after you edit this entry.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    versionList
                    Divider()
                    comparisonColumn
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640, maxHeight: MacSheetMetrics.maxHeight)
        .environment(\.macDetailMetrics, .regular)
        .onAppear { history.appeared() }
        .onDisappear {
            history.disappeared()
            onClose()
        }
        .onChange(of: history.copyFeedback.copied) { _, copied in
            guard let copied else { return }
            AccessibilityNotification.Announcement(copied.field.copiedLabel).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let current = history.current {
                FaviconView(url: current.url, iconID: current.iconID, size: 28,
                            customIconData: history.session.customIconData(for: current))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// "GitHub · 4 earlier versions".
    private var subtitle: String {
        let title = history.current?.title ?? ""
        return SettingsSummaryText.joined([
            title.isEmpty ? String(localized: "(untitled)") : title,
            String(localized: "\(history.versions.count) earlier versions"),
        ])
    }

    // MARK: - Version list

    private var versionList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { history.selectedIndex },
                set: { if let index = $0 { history.select(index) } }
            )) {
                if let current = history.current {
                    Section {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Current Version")
                                    .fontWeight(.semibold)
                                Text(Self.timestamp(current.lastModificationTime))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            StatusBadge(text: String(localized: "Current"), tone: .accent)
                        }
                        .selectionDisabled()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("entry-history.current-version")
                    }
                }
                Section("Earlier Versions") {
                    ForEach(Array(history.versions.enumerated()), id: \.element.id) { position, version in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.timestamp(version.entry.lastModificationTime))
                                .monospacedDigit()
                            Text(version.entry.title.isEmpty ? String(localized: "(untitled)") : version.entry.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(version.index)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("entry-history.version.\(position)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            Text("KeePass keeps a copy of this entry each time it changes. How many are kept is a database setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 240)
        .background(MacDetailPalette.column)
    }

    // MARK: - Comparison column

    @ViewBuilder
    private var comparisonColumn: some View {
        if let model = history.versionModel, let version = history.selectedVersion {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Earlier Version")
                            .font(.title3.bold())
                        Text(columnSubtitle(version))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    MacHistoryCard(history: history, model: model, version: version)
                    MacDetailCard {
                        MacHistoryRow(label: String(localized: "Modified"), isFirst: true, difference: nil) {
                            Text(Self.timestamp(version.lastModificationTime))
                                .accessibilityIdentifier("entry-history.version-detail")
                        }
                        MacHistoryRow(label: String(localized: "Expires"), isFirst: false,
                                      difference: history.comparison?.differences.first { $0.field == .expiry }) {
                            Text(version.enabledExpiryTime.map { Self.timestamp($0) } ?? String(localized: "Never"))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Version Unavailable",
                systemImage: "clock.badge.questionmark",
                description: Text("This version is no longer part of the entry.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "14 Jun 2026 at 17:40 · 3 fields differ from the current version".
    private func columnSubtitle(_ version: KPEntry) -> String {
        let count = history.comparison?.differingFieldCount ?? 0
        return SettingsSummaryText.joined([
            Self.timestamp(version.lastModificationTime),
            count == 0 ? String(localized: "Same as the current version")
                : String(localized: "\(count) fields differ from the current version"),
        ])
    }

    static func timestamp(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Unknown date")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if history.session.isReadOnly == false {
                Text(history.restoreKeepsReplacedState
                     ? String(localized: "Restoring keeps the entry's current contents as a new history version, so you can undo it.")
                     : String(localized: "This database keeps no earlier versions, so the entry's current contents will be lost. This cannot be undone."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if history.session.isReadOnly == false {
                Button("Restore…") { isConfirmingRestore = true }
                    .disabled(history.canRestore == false)
                    .accessibilityIdentifier("entry-history.restore")
                    .confirmationDialog("Restore this version?", isPresented: $isConfirmingRestore,
                                        titleVisibility: .visible) {
                        Button("Restore") { history.restore() }
                            .accessibilityIdentifier("entry-history.restore.confirm")
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        if history.restoreKeepsReplacedState {
                            Text("The entry's current contents are kept as a new history version, so you can undo this.")
                        } else {
                            Text("This database keeps no earlier versions, so the entry's current contents will be lost. This cannot be undone.")
                        }
                    }
            }
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("entry-history.done")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Rows

/// Title, the version's fields, any field only the current entry has, then Tags.
private struct MacHistoryCard: View {
    let history: MacEntryHistorySession
    let model: MacEntryDetailModel
    let version: KPEntry

    var body: some View {
        let comparison = history.comparison
        let missing = history.differencesWithoutVersionRow
        let tagsDifference = comparison?.differences.first { $0.field == .tags }
        let tags = TagNormalizer.tags(from: version.tags)
        MacDetailCard {
            MacHistoryRow(label: String(localized: "Title"), isFirst: true,
                          difference: comparison?.differences.first { $0.field == .title }) {
                Text(version.title.isEmpty ? String(localized: "(untitled)") : version.title)
                    .textSelection(.enabled)
            }
            ForEach(model.fields) { field in
                MacHistoryFieldRow(field: field, model: model, difference: history.difference(for: field.kind))
            }
            ForEach(missing, id: \.field) { difference in
                MacHistoryRow(label: MacEntryHistorySession.label(for: difference.field), isFirst: false,
                              difference: difference) {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
            if tags.isEmpty == false || tagsDifference != nil {
                MacHistoryRow(label: String(localized: "Tags"), isFirst: false, difference: tagsDifference) {
                    if tags.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                Text(tag)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One version field: its value (masked while protected and not revealed), the "Now:" line and
/// the Changed badge when it differs, and Show and Copy, which take the gate.
private struct MacHistoryFieldRow: View {
    let field: MacEntryField
    let model: MacEntryDetailModel
    let difference: EntryVersionComparison.Difference?

    var body: some View {
        MacHistoryRow(label: field.label, isFirst: false, difference: difference) {
            value
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
                .accessibilityIdentifier(field.kind == .password ? "entry-history.password.reveal"
                                         : "entry-history.protected-field.\(normalizedLabel).reveal")
            }
            if field.canCopy && field.kind != .verificationCode {
                MacCopyButton(kind: field.kind, label: String(localized: "Copy \(field.label)"),
                              identifier: "entry-history.copy.\(copyKey)", model: model)
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        switch field.display {
        case .plain(let text):
            Text(text)
                .font(field.kind.isCustom ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .revealed(let text):
            // Never selectable: the copy button is the only copy path for a secret.
            PasswordDisplayText(text)
                .fixedSize(horizontal: false, vertical: true)
        case .concealed, .verificationCode:
            Text(PasswordVisualStyle.concealedText)
                .font(.system(size: 14, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.secondary)
                .accessibilityLabel(field.kind == .password ? String(localized: "Hidden password")
                                    : String(localized: "Hidden protected field"))
        }
    }

    private var normalizedLabel: String {
        field.label.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private var copyKey: String {
        switch field.kind {
        case .username: "username"
        case .password: "password"
        case .website(0): "url"
        case .website(let index): "url.\(index)"
        case .passkeyRelyingParty: "relying_party"
        case .passkeyUsername: "passkey_username"
        case .custom, .notes, .verificationCode: normalizedLabel
        }
    }
}

/// A history row: the value, then the current value's line and the Changed badge when the field
/// differs, on a tinted background.
private struct MacHistoryRow<Value: View, Trailing: View>: View {
    let label: String
    let isFirst: Bool
    let difference: EntryVersionComparison.Difference?
    @ViewBuilder let value: Value
    @ViewBuilder let trailing: Trailing

    var body: some View {
        MacDetailRow(label: label, isFirst: isFirst, alignsTop: true) {
            VStack(alignment: .leading, spacing: 2) {
                value
                if let difference {
                    Text(MacEntryHistorySession.currentValueText(difference))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            trailing
            if let difference {
                StatusBadge(text: String(localized: "Changed"), tone: .warning)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("entry-history.difference.\(Self.identifier(for: difference.field))")
            }
        }
        .background(difference == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.warning.opacity(0.07)))
    }

    static func identifier(for field: EntryVersionComparison.Field) -> String {
        switch field {
        case .title: "title"
        case .username: "username"
        case .password: "password"
        case .website(0): "url"
        case .website(let index): "url.\(index)"
        case .verificationCode: "totp"
        case .custom(let key): key.lowercased().replacingOccurrences(of: " ", with: "_")
        case .notes: "notes"
        case .tags: "tags"
        case .expiry: "expiry"
        }
    }
}

private extension MacHistoryRow where Trailing == EmptyView {
    init(label: String, isFirst: Bool, difference: EntryVersionComparison.Difference?,
         @ViewBuilder value: () -> Value) {
        self.init(label: label, isFirst: isFirst, difference: difference, value: value, trailing: { EmptyView() })
    }
}
#endif
