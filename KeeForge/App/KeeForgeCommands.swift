import SwiftUI

// macOS menu-bar commands. This file is a member of the KeeForgeMac target
// only (excluded from the iOS target in project.yml).

// MARK: - Focused values

/// The active database session, published by the key window via
/// `.focusedSceneValue(\.databaseViewModel, ...)` so menu commands can reach
/// it. This is the one FocusedValues plumbing pattern in the codebase.
extension FocusedValues {
    @Entry var databaseViewModel: DatabaseViewModel?
}

// MARK: - Commands

struct KeeForgeCommands: Commands {
    let listViewModel: DatabaseListViewModel
    @Binding var activeDatabaseViewModel: DatabaseViewModel?
    @FocusedValue(\.databaseViewModel) private var focusedDatabaseViewModel

    /// Prefer the focused scene's session; fall back to the app's active
    /// session so commands keep working while auxiliary panels have focus.
    private var viewModel: DatabaseViewModel? {
        focusedDatabaseViewModel ?? activeDatabaseViewModel
    }

    private var isUnlocked: Bool {
        guard let viewModel else { return false }
        if case .unlocked = viewModel.state { return true }
        return false
    }

    private var selectedEntry: KPEntry? {
        guard isUnlocked, let viewModel, let entryID = viewModel.selectedEntryID else { return nil }
        return viewModel.entry(withID: entryID)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Entry") {
                viewModel?.requestNewEntry()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(isUnlocked == false || viewModel?.isReadOnly != false)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard let viewModel else { return }
                Task {
                    await viewModel.saveHandlingError()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            // The draft stays dirty until the save lands, so `isSaving` is
            // what stops a repeated ⌘S. `DatabaseViewModel.save()` refuses
            // reentry too; this only keeps the menu item from advertising an
            // action it would ignore.
            .disabled(
                isUnlocked == false
                    || viewModel?.isDirty != true
                    || viewModel?.isReadOnly != false
                    || viewModel?.isSaving != false
            )

            Divider()

            Button("Close Database") {
                closeDatabase()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(viewModel == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Copy Username") {
                guard let entry = selectedEntry else { return }
                ClipboardService.copy(entry.username)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(selectedEntry?.username.isEmpty != false)

            Button("Copy Password") {
                copySelectedEntryPassword()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selectedEntry?.hasPassword != true)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                viewModel?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(isUnlocked == false)
        }

        CommandMenu("Database") {
            Button("Lock") {
                viewModel?.lockRequest(manuallyTriggered: true)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(isUnlocked == false)
        }
    }

    private func closeDatabase() {
        guard let viewModel else { return }

        if isUnlocked, viewModel.isDirty {
            // Surface the existing discard-changes flow instead of silently
            // dropping unsaved edits; the user can close after resolving it.
            viewModel.lockRequest(manuallyTriggered: true)
            return
        }

        viewModel.lockRequest(force: true, manuallyTriggered: true)
        activeDatabaseViewModel = nil
        listViewModel.reload()
    }

    private func copySelectedEntryPassword() {
        guard let viewModel, let entry = selectedEntry, let sessionKey = viewModel.sessionKey else { return }

        Task { @MainActor in
            // Same device-owner gate as reveal/copy in the entry detail view:
            // biometrics when available, login password / Apple Watch
            // otherwise. Only skipped when the device has no protection at all.
            if BiometricService.canAuthenticateDeviceOwner {
                do {
                    _ = try await BiometricService.authenticateDeviceOwner(reason: String(localized: "Copy password"))
                } catch {
                    return
                }
            }
            ClipboardService.copy((try? entry.password.decrypt(using: sessionKey)) ?? "")
        }
    }
}
