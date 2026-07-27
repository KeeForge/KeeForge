import CryptoKit
import SwiftUI

/// Browses an entry's stored `<History>` versions, read-only.
///
/// A sheet rather than a push: pushed levels inside the macOS sidebar column render
/// zero-height (see `README.md`).
struct EntryHistoryView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel

    @Environment(\.dismiss) private var dismiss

    private var versions: [KPEntry] {
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
                            ForEach(Array(versions.enumerated()), id: \.offset) { position, version in
                                NavigationLink {
                                    EntryHistoryVersionView(
                                        entryID: entryID,
                                        displayIndex: position,
                                        viewModel: viewModel
                                    )
                                } label: {
                                    VersionRow(version: version)
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
    let displayIndex: Int
    @Bindable var viewModel: DatabaseViewModel

    private var version: KPEntry? {
        let versions = viewModel.history(forEntryID: entryID)
        return versions.indices.contains(displayIndex) ? versions[displayIndex] : nil
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
                            accessibilityKey: "entry-history.title"
                        )
                    }
                    if !version.username.isEmpty {
                        FieldRow(
                            label: String(localized: "Username"),
                            value: version.username,
                            icon: "person",
                            accessibilityKey: "entry-history.username"
                        )
                    }
                    if version.hasPassword {
                        PasswordFieldRow(
                            password: version.password,
                            sessionKey: sessionKey,
                            accessibilityPrefix: "entry-history"
                        )
                    }
                    if !version.url.isEmpty {
                        FieldRow(
                            label: String(localized: "URL"),
                            value: version.url,
                            icon: "link",
                            accessibilityKey: "entry-history.url"
                        )
                    }
                    if !version.notes.isEmpty {
                        Section("Notes") {
                            Text(version.notes)
                        }
                    }
                    if let modified = version.lastModificationTime {
                        Section("Details") {
                            LabeledContent(
                                "Replaced",
                                value: modified.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
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
        #endif
    }
}
