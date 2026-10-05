#if os(macOS)
import AppKit
import SwiftUI

/// Settings ▸ SSH Agent: the opt-in agent, how to point SSH at it, and which
/// keys of the open database it serves.
struct MacSSHAgentSettingsTab: View {
    @Bindable var controller: MacSSHAgentController
    let session: DatabaseViewModel?
    @State private var candidates: [MacSSHAgentCandidate] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable SSH Agent", isOn: $controller.isEnabled)
                    .accessibilityIdentifier("settings.ssh-agent.toggle")
            } footer: {
                if controller.isUnavailable {
                    Text("The SSH agent could not start.")
                        .foregroundStyle(.red)
                }
                Text("SSH clients can sign in with the keys you choose below while their database is unlocked in KeeForge. Locking or closing the database makes its keys unavailable right away.")
            }

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
                keyRows
            } header: {
                Text("Keys")
            } footer: {
                Text("KeeForge offers an entry's OpenSSH private key attachment, the format ssh-keygen creates. Ed25519, ECDSA, and RSA keys without a passphrase are supported.")
            }
        }
        .formStyle(.grouped)
        .task(id: RefreshID(session: session)) {
            guard let session else {
                candidates = []
                return
            }
            candidates = await controller.candidates(in: session)
        }
    }

    @ViewBuilder
    private var keyRows: some View {
        if let session, session.state == .unlocked {
            if candidates.isEmpty {
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

    /// Reloads the list when the session changes, locks or unlocks, or its
    /// entries change.
    private struct RefreshID: Equatable {
        let session: ObjectIdentifier?
        let lockCycleID: Int?
        let isUnlocked: Bool
        let contentRevision: Int?

        @MainActor
        init(session: DatabaseViewModel?) {
            self.session = session.map(ObjectIdentifier.init)
            lockCycleID = session?.lockCycleID
            isUnlocked = session?.state == .unlocked
            contentRevision = session?.contentRevision
        }
    }
}
#endif
