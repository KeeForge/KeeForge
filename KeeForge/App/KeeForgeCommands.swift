import AppKit
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

    private var isEditable: Bool {
        isUnlocked && viewModel?.isReadOnly == false
    }

    private var selectedEntry: KPEntry? {
        guard isUnlocked, let viewModel, let entryID = viewModel.selectedEntryID else { return nil }
        return viewModel.entry(withID: entryID)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About KeeForge") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Entry") {
                viewModel?.requestNewEntry()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(isEditable == false)

            Button("New Group") {
                viewModel?.requestNewGroup()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(isEditable == false)

            Divider()

            Button("Open Database…") {
                openDatabase()
            }
            .keyboardShortcut("o", modifiers: .command)
            // A dirty session has to be resolved first; see openDatabase().
            .disabled(viewModel?.isSaving == true)
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
                guard let viewModel, let entry = selectedEntry else { return }
                ClipboardService.copy(viewModel.resolvingFieldReferences(entry.username))
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(selectedEntry?.username.isEmpty != false)

            Button("Copy Password") {
                copySelectedEntryPassword()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selectedEntry?.hasPassword != true)

            Button("Copy URL") {
                guard let viewModel, let entry = selectedEntry else { return }
                ClipboardService.copy(viewModel.resolvingFieldReferences(entry.url))
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(selectedEntry?.url.isEmpty != false)

            Button("Copy Verification Code") {
                copySelectedEntryTOTP()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(selectedEntry?.totpConfig == nil || viewModel?.sessionKey == nil)

            Divider()

            Button("Edit Entry") {
                viewModel?.requestEntryEdit()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(viewModel?.canEditSelectedEntry != true)

            Button(deleteSelectionTitle) {
                viewModel?.requestDeleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(viewModel?.deletableSelection == nil)
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

        CommandGroup(replacing: .help) {
            Button("KeeForge Help") {
                open(Self.helpURLString)
            }

            Button("Report a Bug") {
                open(Self.issuesURLString)
            }
        }
    }

    /// Mirrors the row context menus: a permanent delete has to say so, in the
    /// menu bar as much as in the menu that hangs off the row.
    private var deleteSelectionTitle: LocalizedStringKey {
        guard let viewModel else { return "Delete" }
        let isAlreadyRecycled = switch viewModel.deletableSelection {
        case .entry(let entryID): viewModel.isEntryInRecycleBin(entryID: entryID)
        case .group(let groupID): viewModel.isGroupInRecycleBin(groupID: groupID)
        case nil: false
        }
        return isAlreadyRecycled ? "Delete Permanently" : "Delete"
    }

    // MARK: - Actions

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

    /// ⌘O. The `.fileImporter` that adds a database lives in `DatabaseListView`,
    /// which is not on screen while a vault is open, so the menu path runs its
    /// own `NSOpenPanel` and reports failures with an `NSAlert` — a menu
    /// command has no SwiftUI host to raise an alert on.
    private func openDatabase() {
        if let viewModel, isUnlocked, viewModel.isDirty {
            // Same rule as Close Database: resolve the unsaved draft first.
            viewModel.lockRequest(manuallyTriggered: true)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DocumentPickerService.databaseContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a KeePass .kdbx database to open.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let reference = try listViewModel.addDatabase(from: url)
            openSession(reference)
        } catch DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) {
            guard let existing = listViewModel.databases.first(where: { $0.id == existingReferenceID }) else { return }
            openSession(existing)
        } catch {
            presentOpenFailure(error)
        }
    }

    private func openSession(_ reference: DatabaseReference) {
        viewModel?.lockRequest(force: true, manuallyTriggered: true)
        activeDatabaseViewModel = DatabaseViewModel(databaseReference: reference)
    }

    private func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Open Database")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func copySelectedEntryPassword() {
        guard let viewModel, let entry = selectedEntry, viewModel.sessionKey != nil else { return }

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
            ClipboardService.copy(viewModel.resolvedPassword(for: entry))
        }
    }

    /// Not behind the device-owner gate, matching the entry detail view's
    /// verification-code copy button: the code expires on its own.
    private func copySelectedEntryTOTP() {
        guard let viewModel,
              let config = selectedEntry?.totpConfig,
              let sessionKey = viewModel.sessionKey else { return }
        ClipboardService.copy(TOTPGenerator.generateCode(config: config, sessionKey: sessionKey))
    }

    private func showAboutPanel() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let commit = (bundle.object(forInfoDictionaryKey: "GITCommitHash") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let credits = NSAttributedString(
            string: String(localized: "Open-source components and their licenses are listed in Settings › About › Acknowledgments."),
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: version,
            .credits: credits,
        ]
        if let commit, commit.isEmpty == false {
            options[.version] = commit
        }

        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    private static let helpURLString = "https://github.com/KeeForge/KeeForge#readme"
    private static let issuesURLString = "https://github.com/KeeForge/KeeForge/issues"

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
