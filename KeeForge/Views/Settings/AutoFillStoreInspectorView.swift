#if DEBUG
// Presented at the app root when launched with `-autofill-store-inspector`; the
// argument does nothing in Release builds. Reads only store metadata — never
// EncryptedValue or vault contents — so it needs no database unlocked.
@preconcurrency import AuthenticationServices
import SwiftUI

// MARK: - View model

@MainActor
@Observable
final class AutoFillStoreInspectorViewModel {
    private(set) var snapshot: InspectorStoreSnapshot?
    private(set) var isRefreshing = false
    private(set) var enumerationError: String?
    private(set) var capabilities: CredentialIdentityStoreCapabilities?

    private let store: any CredentialIdentityStoreProviding

    init(store: any CredentialIdentityStoreProviding = SystemCredentialIdentityStore()) {
        self.store = store
    }

    /// Re-enumerates the store off the main actor and republishes the snapshot.
    /// Spam-safe: a refresh requested while one is in flight is ignored.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshot = nil
        enumerationError = nil
        capabilities = nil

        // Resolve database display names on the main actor (DatabaseListStore
        // reads shared defaults) and capture the Sendable lookup for off-actor
        // snapshot building.
        let namesByID = Dictionary(
            DatabaseListStore.databases.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let store = self.store

        Task {
            let capabilities = await store.capabilities()
            self.capabilities = capabilities
            do {
                self.snapshot = try await Self.buildSnapshot(store: store, capabilities: capabilities) { namesByID[$0] }
                self.enumerationError = nil
            } catch {
                self.snapshot = nil
                self.enumerationError = "Credential store enumeration failed: \(String(describing: error))"
            }
            self.isRefreshing = false
        }
    }

    /// Runs entirely off the main actor: `nonisolated async` bodies execute on
    /// the generic executor, so both the enumeration and the parsing stay off
    /// main (repo rule), and only the Sendable `InspectorStoreSnapshot` crosses
    /// back to the caller.
    nonisolated static func buildSnapshot(
        store: any CredentialIdentityStoreProviding,
        capabilities: CredentialIdentityStoreCapabilities,
        databaseName: @Sendable (UUID) -> String?
    ) async throws -> InspectorStoreSnapshot {
        return AutoFillStoreInspectorGrouping.makeSnapshot(
            isEnabled: capabilities.isEnabled,
            supportsIncrementalUpdates: capabilities.supportsIncrementalUpdates,
            identities: try await store.credentialIdentities(),
            databaseName: databaseName
        )
    }
}

// MARK: - View

struct AutoFillStoreInspectorView: View {
    static let launchArgument = "-autofill-store-inspector"

    /// Whether the current launch requested the inspector at the app root.
    static var isPresentationRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    @State private var viewModel = AutoFillStoreInspectorViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: "AutoFill Store Inspector"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.refresh()
                        } label: {
                            Label {
                                Text(verbatim: "Refresh")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityIdentifier("autofill-inspector.refresh")
                    }
                }
        }
        .task {
            if viewModel.snapshot == nil {
                viewModel.refresh()
            }
        }
    }

    private var content: some View {
        List {
            Section {
                if let capabilities = viewModel.capabilities {
                    valueRow(
                        field: "Enabled",
                        value: capabilities.isEnabled ? "enabled" : "disabled",
                        identifier: "autofill-inspector.enabled-state"
                    )
                    valueRow(
                        field: "Incremental updates",
                        value: capabilities.supportsIncrementalUpdates ? "supported" : "unsupported",
                        identifier: "autofill-inspector.incremental-updates"
                    )
                }
                if let snapshot = viewModel.snapshot {
                    valueRow(
                        field: "Total identities",
                        value: "\(snapshot.totalCount)",
                        identifier: "autofill-inspector.total-count"
                    )
                }
                valueRow(
                    field: "Read status",
                    value: readStatus,
                    identifier: "autofill-inspector.read-status"
                )
            } header: {
                Text(verbatim: "Store State")
            }

            if let snapshot = viewModel.snapshot {
                ForEach(snapshot.databaseBuckets) { bucket in
                    databaseSection(bucket)
                }

                if !snapshot.legacyRows.isEmpty {
                    identitySection(
                        title: "Legacy (bare UUID)",
                        countIdentifier: "autofill-inspector.legacy.count",
                        rows: snapshot.legacyRows
                    )
                }

                if !snapshot.unrecognizedRows.isEmpty {
                    identitySection(
                        title: "Unrecognized",
                        countIdentifier: "autofill-inspector.unrecognized.count",
                        rows: snapshot.unrecognizedRows
                    )
                }
            } else if let error = viewModel.enumerationError {
                Text(verbatim: error)
                    .accessibilityIdentifier("autofill-inspector.enumeration-error")
                    .accessibilityValue(error)
            } else {
                ProgressView {
                    Text(verbatim: viewModel.capabilities == nil
                         ? "Reading provider state…" : "Reading credential identities…")
                }
            }
        }
    }

    private var readStatus: String {
        if viewModel.enumerationError != nil { return "failed" }
        if viewModel.snapshot != nil { return "complete" }
        return viewModel.capabilities == nil ? "reading-provider-state" : "reading-identities"
    }

    // MARK: Sections

    private func databaseSection(_ bucket: InspectorDatabaseBucket) -> some View {
        Section {
            valueRow(
                field: "Identities",
                value: "\(bucket.count)",
                identifier: "autofill-inspector.database.\(bucket.databaseID.uuidString).count"
            )
            Text(verbatim: "Identity metadata")
                .accessibilityIdentifier("autofill-inspector.database.\(bucket.databaseID.uuidString).identities")
                .accessibilityValue(bucket.rows.map(\.metadata).sorted().joined(separator: "\n"))
            ForEach(Array(bucket.rows.enumerated()), id: \.offset) { _, row in
                identityRow(row)
            }
        } header: {
            Text(verbatim: bucket.displayName)
        }
    }

    private func identitySection(
        title: String,
        countIdentifier: String,
        rows: [InspectorIdentityRow]
    ) -> some View {
        Section {
            valueRow(field: "Identities", value: "\(rows.count)", identifier: countIdentifier)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                identityRow(row)
            }
        } header: {
            Text(verbatim: title)
        }
    }

    // MARK: Rows

    /// A field/value row where the trailing value carries the accessibility
    /// identifier and exposes the value as its accessibility value (a string),
    /// so tests can wait for an exact value.
    private func valueRow(field: String, value: String, identifier: String) -> some View {
        HStack {
            Text(verbatim: field)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(value)
        }
    }

    private func identityRow(_ row: InspectorIdentityRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.serviceIdentifier)
                .font(.body)
            HStack(spacing: 8) {
                if !row.label.isEmpty {
                    Text(verbatim: row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: row.kind.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
        }
    }
}
#endif
