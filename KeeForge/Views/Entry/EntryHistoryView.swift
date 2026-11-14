#if os(iOS)
import CryptoKit
import SwiftUI

/// Browses an entry's stored `<History>` versions on iPhone and iPad, pushing a version inside
/// the sheet, and restores one. The Mac sheet is `MacEntryHistorySheet`.
struct EntryHistoryView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let versions = viewModel.history(forEntryID: entryID)
                if versions.isEmpty {
                    EntryHistoryEmptyState()
                } else {
                    List {
                        if let current = viewModel.entry(withID: entryID) {
                            Section {
                                CurrentVersionRow(entry: current, customIconData: viewModel.customIconData(for: current))
                            }
                        }
                        Section {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { position, version in
                                NavigationLink {
                                    EntryHistoryVersionView(
                                        entryID: entryID,
                                        historyIndex: version.index,
                                        viewModel: viewModel,
                                        onRestored: { dismiss() }
                                    )
                                } label: {
                                    VersionRow(version: version.entry)
                                }
                                .accessibilityIdentifier("entry-history.version.\(position)")
                            }
                        } header: {
                            Text("Earlier Versions")
                        } footer: {
                            Text(EntryHistoryStrings.retentionFootnote)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .modifier(EntryHistoryTitleStyle(subtitle: historySubtitle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("entry-history.done")
                }
            }
        }
    }

    /// "GitHub · 4 earlier versions" under the large title.
    private var historySubtitle: String {
        let title = viewModel.entry(withID: entryID)?.title ?? ""
        return SettingsSummaryText.joined([
            title,
            String(localized: "\(viewModel.history(forEntryID: entryID).count) earlier versions"),
        ])
    }
}

/// iPhone and iPad: a large title with the entry and its version count
/// below it from iOS 26; the sheet's own inline title before.
private struct EntryHistoryTitleStyle: ViewModifier {
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationBarTitleDisplayMode(.large)
                .navigationSubtitle(Text(subtitle))
        } else {
            content
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The entry as it is now, above the versions it replaced.
private struct CurrentVersionRow: View {
    let entry: KPEntry
    let customIconData: Data?

    @ScaledMetric(relativeTo: .body) private var iconSize = Theme.Size.entryIcon

    var body: some View {
        HStack(spacing: Theme.Spacing.iconText) {
            FaviconEntryIconView(entry: entry, customIconData: customIconData, size: iconSize)
            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                Text("Current Version")
                    .font(Theme.Font.rowTitle)
                Text(entry.historyTimestampText)
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.labelSecondary)
            }
            Spacer(minLength: 0)
            StatusBadge(text: String(localized: "Current"), tone: .accent)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

private enum EntryHistoryStrings {
    static var retentionFootnote: String {
        String(localized: "KeePass keeps a copy of this entry each time it changes. How many are kept is a database setting.")
    }
}

private extension KPEntry {
    var historyTimestampText: String {
        lastModificationTime.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? String(localized: "Unknown date")
    }
}

private struct EntryHistoryEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No Earlier Versions",
            systemImage: "clock.arrow.circlepath",
            description: Text("Earlier versions appear here after you edit this entry.")
        )
    }
}

/// One row in the version list: when the version was replaced, plus its title so a
/// renamed entry stays recognizable.
private struct VersionRow: View {
    let version: KPEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                Text(version.historyTimestampText)
                Text(version.title.isEmpty ? String(localized: "(untitled)") : version.title)
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
            }
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.labelSecondary)
        }
    }
}

/// The Restore control and its confirmation, kept together so the dialog is
/// attached to the button (not the screen) — iPad anchors the popover to the
/// source view that way.
private struct RestoreButton: View {
    let entryID: UUID
    let historyIndex: Int
    @Bindable var viewModel: DatabaseViewModel
    let onRestored: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button("Restore") { isConfirming = true }
            .accessibilityIdentifier("entry-history.restore")
            .confirmationDialog(
                "Restore this version?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Restore") { restore() }
                    .accessibilityIdentifier("entry-history.restore.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                if viewModel.restoreKeepsReplacedState(entryID: entryID) {
                    Text("The entry's current contents are kept as a new history version, so you can undo this.")
                } else {
                    Text("This database keeps no earlier versions, so the entry's current contents will be lost. This cannot be undone.")
                }
            }
    }

    private func restore() {
        do {
            try viewModel.restoreEntryVersion(entryID: entryID, historyIndex: historyIndex)
            onRestored()
            Task { await viewModel.saveHandlingError() }
        } catch {
            viewModel.presentSaveError(error)
        }
    }
}

/// One version's fields, as the caller's `List` sections. Mirrors
/// `EntryDetailView`'s field set.
private struct EntryHistoryVersionFields: View {
    let version: KPEntry
    let sessionKey: SymmetricKey
    @Bindable var viewModel: DatabaseViewModel

    private var secretActionIsCurrent: @MainActor () -> Bool {
        EntrySecretAction.currentSession(viewModel)
    }

    var body: some View {
        Group {
            EntryFieldsCard {
                if !version.title.isEmpty {
                    FieldRow(
                        label: String(localized: "Title"),
                        value: version.title,
                        accessibilityKey: "title",
                        accessibilityPrefix: "entry-history"
                    )
                }
                if !version.username.isEmpty {
                    ReferenceAwareFieldRow(label: String(localized: "Username"), raw: version.username,
                                           viewModel: viewModel, accessibilityPrefix: "entry-history",
                                           isCurrent: secretActionIsCurrent) { username in
                        FieldRow(
                            label: String(localized: "Username"),
                            value: username,
                            accessibilityKey: "username",
                            accessibilityPrefix: "entry-history"
                        )
                    }
                }
                if version.hasPassword {
                    PasswordFieldRow(
                        password: version.password,
                        sessionKey: sessionKey,
                        secretAccess: viewModel.secretAccess,
                        resolveReferences: viewModel.resolvingFieldReferencesIncludingProtectedValues,
                        accessibilityPrefix: "entry-history",
                        isCurrent: secretActionIsCurrent
                    )
                }
                if !version.url.isEmpty {
                    ReferenceAwareFieldRow(label: String(localized: "URL"), raw: version.url,
                                           viewModel: viewModel, accessibilityPrefix: "entry-history",
                                           isCurrent: secretActionIsCurrent) { url in
                        FieldRow(
                            label: String(localized: "URL"),
                            value: url,
                            accessibilityKey: "url",
                            accessibilityPrefix: "entry-history"
                        )
                    }
                }
                if let totpConfig = version.totpConfig {
                    TOTPSection(
                        config: totpConfig,
                        sessionKey: sessionKey,
                        accessibilityPrefix: "entry-history"
                    )
                }
            }
            if !version.notes.isEmpty {
                ReferenceAwareFieldRow(label: String(localized: "Notes"), raw: version.notes,
                                       viewModel: viewModel, accessibilityPrefix: "entry-history",
                                       isCurrent: secretActionIsCurrent) { notes in
                    Section("Notes") {
                        SelectableNotesText(notes)
                    }
                }
            }
            let customFields = version.displayCustomFields
            if !customFields.isEmpty {
                Section("Custom Fields") {
                    ForEach(
                        version.orderedCustomFieldKeys(in: Set(customFields.keys)).map {
                            (key: $0, value: customFields[$0] ?? "")
                        },
                        id: \.key
                    ) { key, value in
                        if version.protectedStringKeys.contains(key) {
                            ProtectedFieldRow(
                                label: key,
                                value: value,
                                secretAccess: viewModel.secretAccess,
                                resolveReferences: viewModel.resolvingFieldReferencesIncludingProtectedValues,
                                accessibilityPrefix: "entry-history",
                                isCurrent: secretActionIsCurrent
                            )
                        } else {
                            ReferenceAwareFieldRow(label: key, raw: value, viewModel: viewModel,
                                                   accessibilityPrefix: "entry-history",
                                                   isCurrent: secretActionIsCurrent) { value in
                                FieldRow(
                                    label: key,
                                    value: value,
                                    accessibilityPrefix: "entry-history"
                                )
                            }
                        }
                    }
                }
            }
            if !version.tags.isEmpty {
                // Plain capsules, not the detail screen's links: neither shell
                // resolves `DatabaseRoute`.
                Section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(version.tags.enumerated()), id: \.offset) { _, tag in
                            TagCapsule(tag: tag)
                        }
                    }
                }
            }
            Section("Details") {
                if let created = version.creationTime {
                    LabeledContent(
                        "Created",
                        value: created.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                // `cloneForHistory` copies the entry untouched, so this is when
                // the version itself was written — it stopped being current at
                // the *next* version's timestamp.
                LabeledContent("Last Modified", value: version.historyTimestampText)
                    .accessibilityIdentifier("entry-history.version-detail")
                if let expiry = version.enabledExpiryTime {
                    LabeledContent(
                        "Expires",
                        value: expiry.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        }
    }
}

private struct EntryHistoryVersionUnavailable: View {
    var body: some View {
        ContentUnavailableView(
            "Version Unavailable",
            systemImage: "clock.badge.questionmark",
            description: Text("This version is no longer part of the entry.")
        )
    }
}

// MARK: - Pushed version screen

private struct EntryHistoryVersionView: View {
    let entryID: UUID
    let historyIndex: Int
    @Bindable var viewModel: DatabaseViewModel
    let onRestored: () -> Void

    /// `historyIndex` addresses storage order, not the sorted display order.
    private var version: KPEntry? {
        viewModel.history(forEntryID: entryID).first { $0.index == historyIndex }?.entry
    }

    var body: some View {
        Group {
            if let version, let sessionKey = viewModel.sessionKey {
                List {
                    EntryHistoryVersionFields(
                        version: version,
                        sessionKey: sessionKey,
                        viewModel: viewModel
                    )
                }
            } else {
                EntryHistoryVersionUnavailable()
            }
        }
        .navigationTitle("Earlier Version")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isReadOnly == false, version != nil {
                ToolbarItem(placement: .primaryAction) {
                    RestoreButton(
                        entryID: entryID,
                        historyIndex: historyIndex,
                        viewModel: viewModel,
                        onRestored: onRestored
                    )
                }
            }
        }
    }
}
#endif
