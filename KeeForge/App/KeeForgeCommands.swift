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
    let sessionStore: DatabaseSessionStore
    let routing: AppRoutingCoordinator
    @FocusedValue(\.databaseViewModel) private var focusedDatabaseViewModel
    @State private var passwordCopyAction = EntrySecretAction()

    /// Prefer the focused scene's session; fall back to the app's active
    /// session so commands keep working while auxiliary panels have focus.
    private var viewModel: DatabaseViewModel? {
        focusedDatabaseViewModel ?? sessionStore.activeSession
    }

    private var databaseCommands: DatabaseCommands {
        DatabaseCommands(session: viewModel, passwordCopyAction: passwordCopyAction)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About KeeForge") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .newItem) {
            // Parity with "Open Database…"; presents from the database list,
            // which hosts the creation sheet, so it is disabled while a vault
            // is open.
            Button("New Database…") {
                listViewModel.requestNewDatabase()
            }
            .disabled(databaseCommands.isUnlocked)

            Divider()

            Button("New Entry") {
                databaseCommands.newEntry()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(databaseCommands.canNewEntry == false)

            Button("New Group") {
                databaseCommands.newGroup()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(databaseCommands.canNewGroup == false)

            Divider()

            Button("Open Database…") {
                openDatabase()
            }
            .keyboardShortcut("o", modifiers: .command)
            // A dirty session has to be resolved first; see openDatabase().
            .disabled(viewModel?.isSaving == true)
        }

        CommandGroup(replacing: .saveItem) {
            // SwiftUI's `.saveItem` group is where the standard File ▸ Close
            // lives, so replacing the group took ⌘W with it. It has to be put
            // back: closing the last window is a lock trigger, and
            // `MacWindowCloseGuard` is what settles unsaved work before that
            // close commits.
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Save") {
                databaseCommands.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(databaseCommands.canSave == false)

            Divider()

            Button("Close Database") {
                closeDatabase()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(databaseCommands.canCloseDatabase == false)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Copy Username") {
                databaseCommands.copyUsername()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(databaseCommands.canCopyUsername == false)

            Button("Copy Password") {
                databaseCommands.copyPassword(activeSession: { [sessionStore] in sessionStore.activeSession })
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(databaseCommands.canCopyPassword == false)

            Button("Copy URL") {
                databaseCommands.copyURL()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(databaseCommands.canCopyURL == false)

            Button("Copy Verification Code") {
                databaseCommands.copyVerificationCode()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(databaseCommands.canCopyVerificationCode == false)

            Divider()

            Button("Edit Entry") {
                databaseCommands.editEntry()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(databaseCommands.canEditEntry == false)

            Button(deleteSelectionTitle) {
                databaseCommands.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(databaseCommands.canDelete == false)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                databaseCommands.find()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(databaseCommands.canFind == false)
        }

        CommandMenu("Database") {
            Button("Lock") {
                databaseCommands.lock()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(databaseCommands.canLock == false)
        }

        // Without a replacement macOS ships a "KeeForge Help" item that only raises
        // a "Help isn't available" alert, because the app has no help book.
        CommandGroup(replacing: .help) {
            Button("KeeForge Help") {
                open(Self.helpURLString)
            }

            Button("Report a Bug") {
                open(Self.issuesURLString)
            }
        }
    }

    private var deleteSelectionTitle: LocalizedStringKey {
        databaseCommands.deletesPermanently ? "Delete Permanently" : "Delete"
    }

    // MARK: - Actions

    private func closeDatabase() {
        routing.requestDatabaseTransition(to: .close, from: sessionStore.activeSession)
    }

    /// ⌘O. The `.fileImporter` that adds a database lives in `DatabaseListView`,
    /// which is not on screen while a vault is open, so the menu path runs its
    /// own `NSOpenPanel` and reports failures with an `NSAlert` — a menu
    /// command has no SwiftUI host to raise an alert on.
    private func openDatabase() {
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
        routing.requestDatabaseTransition(to: .open(reference), from: sessionStore.activeSession)
    }

    private func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Open Database")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
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
