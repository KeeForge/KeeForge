import SwiftUI

struct LocalSaveRecoveryContents: View {
    @Bindable var recovery: PendingLocalRecoveryViewModel
    let reference: DatabaseReference
    let export: (DatabaseExportRequest) -> Void
    let requestDiscard: (PendingLocalSaveStore.RecoverySnapshot, Bool) -> Void
    let refresh: () async -> Void

    var body: some View {
        if let localRecovery = recovery.snapshot, !localRecovery.entries.isEmpty || localRecovery.needsRecovery || localRecovery.keyEvidence?.targetDurabilityUnconfirmed == true || localRecovery.requiresAssociationRecovery(for: reference) || recovery.targetNeedsRecovery {
            Section("Local Save Recovery") {
                if localRecovery.admission?.purpose == .ordinarySave, localRecovery.admission?.knownTarget != nil {
                    Text("The file contains this change, but its durability or recovery record is unconfirmed. You can make a new explicit save from this version without discarding recovery. Discarding the record does not undo the file change or discard your open draft.")
                } else if localRecovery.admission?.purpose == .ordinarySave {
                    Text("This local save has an unresolved outcome. Export the database and any unsaved changes before discarding this recovery record. Discarding does not undo a replacement and deletes only the snapshots listed here; later snapshots and your open draft are kept.")
                }
                if !localRecovery.entries.isEmpty {
                    Text("Each source is a full encrypted database snapshot. Open exported files with their original master key. Exporting does not discard the source.")
                }
                if localRecovery.isRevoked {
                    Text("Local writes are disabled. Export any snapshots you want to keep, then separately discard pending changes and remove the database. Add it again with the correct master key if you want to keep using it.")
                }
                if recovery.targetNeedsRecovery {
                    Text("The current database file does not match the saved key record. Keep the original and new master keys and encrypted backups. Export unsaved changes before closing this session.")
                }
                if let admission = localRecovery.admission, admission.purpose.isMasterKeyChange {
                    Text("This is a verified copy of the intended encrypted output, not proof that the original file was saved. Open it with the key chosen for that operation. Exporting does not resolve recovery.")
                    Button("Export Encrypted Output…") { export(.keyPublicationIntent(UUID(), admission, reference)) }
                        .accessibilityIdentifier("database-details.local-recovery.export-key-copy")
                } else if let evidence = localRecovery.keyEvidence {
                    Text("This encrypted copy requires the master key from the saved key change. Exporting does not change the database or discard recovery records.")
                    Button("Export Saved Database Copy…") { export(.keyPublication(UUID(), evidence, reference)) }
                        .accessibilityIdentifier("database-details.local-recovery.export-key-copy")
                }
                if localRecovery.keyEvidence?.targetDurabilityUnconfirmed == true || localRecovery.admission?.knownTarget?.isConfirmed == false {
                    Text("The current file's durability is unconfirmed. Keep an encrypted backup before closing this session.")
                }
                ForEach(localRecovery.entries) { source in
                    LabeledContent {
                        if let receipt = source.receipt {
                            Button("Export AutoFill Snapshot…") {
                                export(.pendingLocal(receipt, reference))
                            }
                            .accessibilityIdentifier("database-details.local-recovery.export")
                        } else {
                            Text("Unavailable")
                        }
                    } label: {
                        let name = URL(fileURLWithPath: source.relativePath).lastPathComponent
                        Text(DatabaseExportService.backupDate(fromFilename: name)?.formatted() ?? name)
                    }
                }
                if localRecovery.preferenceIntent != nil || localRecovery.admission?.purpose.isMasterKeyChange == true || localRecovery.keyEvidence?.pending != nil || localRecovery.requiresAssociationRecovery(for: reference) {
                    LabeledContent("Key File", value: localRecovery.recoveryKeyFileFilename ?? String(localized: "None"))
                    Button(localRecovery.preferenceIntent != nil ? String(localized: "Confirm Key File Preference")
                           : localRecovery.admission?.purpose.isMasterKeyChange == true ? String(localized: "Confirm Installed Key Change")
                           : String(localized: "Confirm Current File")) {
                        Task {
                            await recovery.confirmInstalledKeyChange(reference: reference, snapshot: localRecovery)
                            await refresh()
                        }
                    }
                    .accessibilityIdentifier("database-details.local-recovery.confirm-key")
                }
                if !localRecovery.entries.isEmpty || localRecovery.admission != nil || localRecovery.ownerUnavailable || localRecovery.retirementID != nil || (localRecovery.keyEvidence != nil && recovery.targetNeedsRecovery) || localRecovery.preferenceIntent != nil {
                    Button("Discard Local Recovery…", role: .destructive) {
                        requestDiscard(localRecovery, localRecovery.keyEvidence != nil && recovery.targetNeedsRecovery)
                    }
                    .accessibilityIdentifier("database-details.local-recovery.discard")
                }
            }
        }
        if let localRecoveryError = recovery.errorMessage {
            Section("Local Save Recovery") {
                Text(localRecoveryError)
                Button("Try Again") { Task { await recovery.retry() } }
            }
        }
    }
}
