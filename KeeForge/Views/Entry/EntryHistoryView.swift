import CryptoKit
import SwiftUI

/// Browses an entry's stored `<History>` versions and restores one.
///
/// A sheet rather than a push: pushed levels inside the macOS sidebar column render
/// zero-height (see `CLAUDE.md`). Two shells over one field list — iOS pushes the
/// version inside the sheet's own `NavigationStack`, macOS shows the versions and
/// the selected one side by side, because pushing inside a Mac sheet drops the
/// sheet's buttons and leaves the pushed list inset for a bar it never draws.
struct EntryHistoryView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        MacEntryHistoryBrowser(entryID: entryID, viewModel: viewModel) { dismiss() }
        #else
        NavigationStack {
            Group {
                let versions = viewModel.history(forEntryID: entryID)
                if versions.isEmpty {
                    EntryHistoryEmptyState()
                } else {
                    List {
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
                        } footer: {
                            Text(EntryHistoryStrings.retentionFootnote)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("entry-history.done")
                }
            }
        }
        #endif
    }
}

// MARK: - Shared pieces

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
        VStack(alignment: .leading, spacing: 2) {
            Text(version.historyTimestampText)
            Text(version.title.isEmpty ? String(localized: "(untitled)") : version.title)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    var body: some View {
        Group {
            if !version.title.isEmpty {
                FieldRow(
                    label: String(localized: "Title"),
                    value: version.title,
                    icon: "textformat",
                    accessibilityKey: "title",
                    accessibilityPrefix: "entry-history"
                )
            }
            if !version.username.isEmpty {
                FieldRow(
                    label: String(localized: "Username"),
                    value: viewModel.resolvingFieldReferences(version.username),
                    icon: "person",
                    accessibilityKey: "username",
                    accessibilityPrefix: "entry-history"
                )
            }
            if version.hasPassword {
                PasswordFieldRow(
                    password: version.password,
                    sessionKey: sessionKey,
                    resolveReferences: viewModel.resolvingFieldReferences,
                    accessibilityPrefix: "entry-history"
                )
            }
            if !version.url.isEmpty {
                FieldRow(
                    label: String(localized: "URL"),
                    value: viewModel.resolvingFieldReferences(version.url),
                    icon: "link",
                    accessibilityKey: "url",
                    accessibilityPrefix: "entry-history"
                )
            }
            if let totpConfig = version.totpConfig {
                TOTPSection(
                    config: totpConfig,
                    sessionKey: sessionKey,
                    accessibilityPrefix: "entry-history"
                )
            }
            if !version.notes.isEmpty {
                Section("Notes") {
                    SelectableNotesText(viewModel.resolvingFieldReferences(version.notes))
                }
            }
            if !version.displayCustomFields.isEmpty {
                Section("Custom Fields") {
                    ForEach(
                        version.displayCustomFields.sorted(by: { $0.key < $1.key }),
                        id: \.key
                    ) { key, value in
                        if version.protectedStringKeys.contains(key) {
                            ProtectedFieldRow(
                                label: key,
                                value: viewModel.resolvingFieldReferences(value),
                                accessibilityPrefix: "entry-history",
                                showsInlineLabel: true
                            )
                        } else {
                            FieldRow(
                                label: key,
                                value: viewModel.resolvingFieldReferences(value),
                                icon: "text.justify.left",
                                accessibilityPrefix: "entry-history",
                                showsInlineLabel: true
                            )
                        }
                    }
                }
            }
            if !version.tags.isEmpty {
                // Plain capsules, not the detail screen's links: neither shell
                // resolves `TagDestination`.
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

// MARK: - macOS shell

#if os(macOS)
/// Versions on the left, the selected one on the right, and one action bar
/// underneath both.
private struct MacEntryHistoryBrowser: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel
    let onDone: () -> Void

    /// Seeded here rather than in `onAppear`: selecting after the first layout
    /// pass swaps the detail pane's placeholder for the field list, and the
    /// list keeps a scroll offset from that swap which hides its first row.
    @State private var selection: Int?

    init(entryID: UUID, viewModel: DatabaseViewModel, onDone: @escaping () -> Void) {
        self.entryID = entryID
        self.viewModel = viewModel
        self.onDone = onDone
        _selection = State(initialValue: viewModel.history(forEntryID: entryID).first?.index)
    }

    private var versions: [DatabaseViewModel.EntryHistoryVersion] {
        viewModel.history(forEntryID: entryID)
    }

    /// `selection` addresses storage order, not the sorted display order.
    private var selectedVersion: KPEntry? {
        versions.first { $0.index == selection }?.entry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            actionBar
        }
    }

    private var header: some View {
        Text("History")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if versions.isEmpty {
            EntryHistoryEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                versionList
                Divider()
                versionDetail
            }
        }
    }

    private var versionList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(versions.enumerated()), id: \.element.id) { position, version in
                    VersionRow(version: version.entry)
                        .tag(version.index)
                        .accessibilityIdentifier("entry-history.version.\(position)")
                }
            }
            .listStyle(.inset)

            Divider()

            Text(EntryHistoryStrings.retentionFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private var versionDetail: some View {
        if let selectedVersion, let sessionKey = viewModel.sessionKey {
            List {
                EntryHistoryVersionFields(
                    version: selectedVersion,
                    sessionKey: sessionKey,
                    viewModel: viewModel
                )
            }
            // Rebuilt per version: a macOS `List` of static rows keeps the rows
            // it first laid out, so picking another version left the previous
            // one's fields on screen. Also drops the scroll offset, which is
            // what switching versions should do anyway.
            .id(selection)
        } else {
            EntryHistoryVersionUnavailable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            if viewModel.isReadOnly == false, let selection, selectedVersion != nil {
                RestoreButton(
                    entryID: entryID,
                    historyIndex: selection,
                    viewModel: viewModel,
                    onRestored: onDone
                )
            }
            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("entry-history.done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
#endif

// MARK: - iOS pushed version screen

#if os(iOS)
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
