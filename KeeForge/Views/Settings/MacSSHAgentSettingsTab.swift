#if os(macOS)
import AppKit
import SwiftUI

/// Settings ▸ SSH Agent: the opt-in agent, how to point SSH at it, and which
/// keys of each open database it serves. With several unlocked databases the
/// user picks the one whose keys the list shows.
struct MacSSHAgentSettingsTab: View {
    @Bindable var controller: MacSSHAgentController
    /// Candidates and the session they were read from, so rows never bind to
    /// another database's selection.
    @State private var loaded: (session: ObjectIdentifier, candidates: [MacSSHAgentCandidate])?

    var body: some View {
        Form {
            Section {
                Toggle("Enable SSH Agent", isOn: $controller.isEnabled)
                    .accessibilityIdentifier("settings.ssh-agent.toggle")
            } footer: {
                switch controller.unavailability {
                case .socketInUse:
                    Text("The SSH agent could not start because another app is already using its socket.")
                        .foregroundStyle(.red)
                case .failed:
                    Text("The SSH agent could not start.")
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
                Text("SSH clients can sign in with the keys you choose below while their database is unlocked in KeeForge. Locking or closing the database makes its keys unavailable right away.")
            }

            if controller.isEnabled {
                Section {
                    LabeledContent("Socket") {
                        Text(verbatim: controller.socketPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Copy SSH Configuration") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.configurationSnippet, forType: .string)
                    }
                    .accessibilityIdentifier("settings.ssh-agent.copy-configuration")
                } header: {
                    Text("Setup")
                } footer: {
                    Text("Paste the copied lines into ~/.ssh/config to use the agent for every host, or set SSH_AUTH_SOCK to the socket path.")
                }

                Section {
                    databasePicker
                    keyRows
                } header: {
                    Text("Keys")
                } footer: {
                    Text("KeeForge offers an entry's OpenSSH private key attachment, the format ssh-keygen creates. Ed25519, ECDSA, and RSA keys without a passphrase are supported.")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: RefreshID(session: session, isAgentEnabled: controller.isEnabled)) {
            loaded = nil
            guard controller.isEnabled, let session else { return }
            let refreshed = await controller.candidates(in: session)
            guard Task.isCancelled == false else { return }
            loaded = (ObjectIdentifier(session), refreshed)
        }
    }

    private var session: DatabaseViewModel? { controller.settingsSession }

    /// Shown only when more than one database is unlocked; with one, the
    /// list is simply that database's.
    @ViewBuilder
    private var databasePicker: some View {
        let sessions = controller.settingsSessions
        if sessions.count > 1, controller.concealsKeyList == false {
            Picker("Database", selection: Binding {
                session?.databaseReference.id
            } set: {
                controller.settingsDatabaseID = $0
            }) {
                ForEach(sessions, id: \.databaseReference.id) { session in
                    Text(verbatim: session.databaseReference.displayName)
                        .tag(Optional(session.databaseReference.id))
                }
            }
            .accessibilityIdentifier("settings.ssh-agent.database-picker")
        }
    }

    @ViewBuilder
    private var keyRows: some View {
        if let session, session.state == .unlocked {
            let candidates = loaded.flatMap { $0.session == ObjectIdentifier(session) ? $0.candidates : nil } ?? []
            if controller.concealsKeyList {
                Text(verbatim: "••••••••")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Keys"))
            } else if candidates.isEmpty {
                Text("This database has no entries with a private key attachment.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    Toggle(isOn: selection(of: candidate, inDatabase: session.databaseReference.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: candidate.title)
                            detail(for: candidate.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(candidate.isSupported == false)
                    .accessibilityIdentifier("settings.ssh-agent.key-toggle.\(candidate.id.uuidString)")
                }
            }
        } else {
            Text("Unlock a database to choose which of its SSH keys the agent offers.")
                .foregroundStyle(.secondary)
        }
    }

    private func detail(for status: MacSSHAgentCandidate.Status) -> Text {
        switch status {
        case .supported(let algorithm, let fingerprint):
            Text(verbatim: "\(algorithm) · \(fingerprint)")
        case .passphraseProtected:
            Text("Keys protected by a passphrase are not supported.")
        case .unsupported:
            Text("Unsupported key format. Use an OpenSSH private key without a passphrase.")
        }
    }

    private func selection(of candidate: MacSSHAgentCandidate, inDatabase databaseID: UUID) -> Binding<Bool> {
        Binding {
            candidate.isSupported && controller.isSelected(entryID: candidate.id, inDatabase: databaseID)
        } set: { isSelected in
            controller.setSelected(isSelected, entryID: candidate.id, inDatabase: databaseID)
        }
    }

    /// Reloads the list when the agent is switched, the session changes, locks
    /// or unlocks, or its entries change.
    private struct RefreshID: Equatable {
        let isAgentEnabled: Bool
        let session: ObjectIdentifier?
        let lockCycleID: Int?
        let isUnlocked: Bool
        let contentRevision: Int?

        @MainActor
        init(session: DatabaseViewModel?, isAgentEnabled: Bool) {
            self.isAgentEnabled = isAgentEnabled
            self.session = session.map(ObjectIdentifier.init)
            lockCycleID = session?.lockCycleID
            isUnlocked = session?.state == .unlocked
            contentRevision = session?.contentRevision
        }
    }
}
#endif
