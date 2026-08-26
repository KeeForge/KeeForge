import CryptoKit
import SwiftUI

/// Browses an entry's stored `<History>` versions and restores one.
///
/// A sheet rather than a push: pushed levels inside the macOS sidebar column render
/// zero-height (see `README.md`).
struct EntryHistoryView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss

    private var versions: [DatabaseViewModel.EntryHistoryVersion] {
        viewModel.history(forEntryID: entryID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if versions.isEmpty {
                    ContentUnavailableView(
                        "No Earlier Versions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Earlier versions appear here after you edit this entry.")
                    )
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
                            Text("KeePass keeps a copy of this entry each time it changes. How many are kept is a database setting.")
                        }
                    }
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("entry-history.done")
                }
            }
        }
    }
}

/// One row in the version list: when the version was replaced, plus its title so a
/// renamed entry stays recognizable.
private struct VersionRow: View {
    let version: KPEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(version.lastModificationTime.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? String(localized: "Unknown date"))
            Text(version.title.isEmpty ? String(localized: "(untitled)") : version.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EntryHistoryVersionView: View {
    let entryID: UUID
    let historyIndex: Int
    @Bindable var viewModel: DatabaseViewModel
    let onRestored: () -> Void

    @State private var isConfirmingRestore = false

    /// `historyIndex` addresses storage order, not the sorted display order.
    private var version: KPEntry? {
        viewModel.history(forEntryID: entryID).first { $0.index == historyIndex }?.entry
    }

    var body: some View {
        Group {
            if let version, let sessionKey = viewModel.sessionKey {
                List {
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
                        // Plain capsules, not the detail screen's links: this sheet's
                        // NavigationStack does not resolve `TagDestination`.
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
                        LabeledContent(
                            "Last Modified",
                            value: version.lastModificationTime.map {
                                $0.formatted(date: .abbreviated, time: .shortened)
                            } ?? String(localized: "Unknown date")
                        )
                        .accessibilityIdentifier("entry-history.version-detail")
                        if let expiry = version.enabledExpiryTime {
                            LabeledContent(
                                "Expires",
                                value: expiry.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }

                    #if os(macOS)
                    // A `.primaryAction` toolbar item inside a sheet's pushed
                    // NavigationStack does not surface on macOS, so the Restore
                    // control lives in the content here instead of the toolbar.
                    if viewModel.isReadOnly == false {
                        Section {
                            restoreConfirmation(
                                Button("Restore") { isConfirmingRestore = true }
                                    .accessibilityIdentifier("entry-history.restore")
                            )
                        }
                    }
                    #endif
                }
            } else {
                ContentUnavailableView(
                    "Version Unavailable",
                    systemImage: "clock.badge.questionmark",
                    description: Text("This version is no longer part of the entry.")
                )
            }
        }
        .navigationTitle("Earlier Version")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isReadOnly == false, version != nil {
                ToolbarItem(placement: .primaryAction) {
                    restoreConfirmation(
                        Button("Restore") { isConfirmingRestore = true }
                            .accessibilityIdentifier("entry-history.restore")
                    )
                }
            }
        }
        #endif
    }

    /// The Restore confirmation, attached to the Restore button (not the
    /// screen) so iPad anchors the popover to the source view.
    private func restoreConfirmation(_ button: some View) -> some View {
        button.confirmationDialog(
            "Restore this version?",
            isPresented: $isConfirmingRestore,
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
