import OneTimeCodes
import SwiftUI

/// Destination picker for an incoming `otpauth://` enrollment link: attach
/// the verification code to an existing entry, or create a new entry in a
/// chosen group. Either path opens the normal entry editor with the code
/// already applied, so the user reviews and saves through the standard flow.
/// On iOS saving finishes the whole flow and cancelling the editor returns
/// here, so a wrong destination pick does not destroy the incoming code. On
/// Mac the pick finishes this sheet and opens the window's inline editor.
struct TOTPEnrollmentDestinationView: View {
    /// Navigation inside the sheet, driven by one path: group picker →
    /// editor is a normal two-element stack. The editor payload hashes by
    /// the view model's stable `id`.
    private enum EnrollmentStep: Hashable {
        case groupPicker
        case editor(EntryEditViewModel)
    }

    let databaseViewModel: DatabaseViewModel
    let onFinished: () -> Void

    @State private var model: TOTPEnrollmentViewModel
    @State private var path: [EnrollmentStep] = []
    #if os(macOS)
    @Environment(MacWorkspacePresentation.self) private var presentation: MacWorkspacePresentation?
    #endif
    @State private var replaceCandidate: TOTPEnrollmentViewModel.EntryCandidate?

    init(
        databaseViewModel: DatabaseViewModel,
        uri: OTPAuthURI,
        onFinished: @escaping () -> Void
    ) {
        self.databaseViewModel = databaseViewModel
        self.onFinished = onFinished
        _model = State(initialValue: TOTPEnrollmentViewModel(uri: uri, database: databaseViewModel))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if databaseViewModel.isReadOnly {
                    readOnlyExplanation
                } else {
                    destinationList
                }
            }
            .navigationTitle("Add Verification Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onFinished)
                        .accessibilityIdentifier("totp-enroll.cancel")
                }
            }
            .navigationDestination(for: EnrollmentStep.self) { step in
                switch step {
                case .groupPicker:
                    groupPicker
                #if os(iOS)
                case .editor(let formViewModel):
                    editor(formViewModel)
                #else
                case .editor:
                    EmptyView()
                #endif
                }
            }
            // Anchored to the stack content, not a row: rows scroll away under
            // search filtering and would tear the dialog host down with them.
            .confirmationDialog(
                "Replace existing verification code?",
                isPresented: Binding(
                    get: { replaceCandidate != nil },
                    set: { isPresented in
                        if isPresented == false {
                            replaceCandidate = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: replaceCandidate
            ) { candidate in
                Button("Replace", role: .destructive) {
                    openEditor(attachingTo: candidate)
                }
                .accessibilityIdentifier("totp-enroll.replace-confirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This entry already has a verification code. Saving will replace it.")
            }
        }
    }

    /// The Mac window has one inline editor; another one already open there keeps its unsaved work.
    private var isBlockedByOpenEditor: Bool {
        #if os(macOS)
        presentation?.currentEntryEditor(in: databaseViewModel) != nil
        #else
        false
        #endif
    }

    private var destinationList: some View {
        List {
            Section {
                summaryHeader
            }

            Section {
                Button {
                    path.append(.groupPicker)
                } label: {
                    Label("New Entry", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("totp-enroll.new-entry")
                .macHoverHighlight()
                .disabled(isBlockedByOpenEditor)
            }

            Section("Entries") {
                TextField("Search entries", text: $model.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("totp-enroll.search-field")

                let candidates = model.filteredEntryCandidates
                if candidates.isEmpty {
                    // An empty list with an empty search field means the
                    // database has nothing to attach to, not a missed query.
                    if model.hasActiveSearch {
                        ContentUnavailableView.search
                    } else {
                        ContentUnavailableView(
                            "No Entries",
                            systemImage: "tray",
                            description: Text("Choose New Entry above to save this verification code.")
                        )
                    }
                } else {
                    ForEach(candidates) { candidate in
                        entryRow(for: candidate)
                    }
                }
            }
        }
        .accessibilityIdentifier("totp-enroll.entry-list")
    }

    private var summaryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Theme.State.success)

            VStack(alignment: .leading) {
                Text(model.summaryTitle)
                    .font(.headline)
                if let subtitle = model.summarySubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Choose where to save this verification code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isBlockedByOpenEditor {
                    Text("Finish editing the open entry first.")
                        .font(.caption)
                        .foregroundStyle(Theme.State.warning)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("totp-enroll.summary")
    }

    private func entryRow(for candidate: TOTPEnrollmentViewModel.EntryCandidate) -> some View {
        Button {
            if model.requiresReplaceConfirmation(candidate) {
                replaceCandidate = candidate
            } else {
                openEditor(attachingTo: candidate)
            }
        } label: {
            VStack(alignment: .leading) {
                Text(candidate.title.isEmpty ? String(localized: "(untitled)") : candidate.title)
                    .font(.body)
                if candidate.username.isEmpty == false {
                    Text(candidate.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let folderPath = candidate.folderPath {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .accessibilityHidden(true)
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("totp-enroll.entry.\(candidate.id.uuidString)")
        .macHoverHighlight()
        .disabled(isBlockedByOpenEditor)
    }

    private var groupPicker: some View {
        List(model.groupOptions) { option in
            Button {
                openEditorCreating(in: option.id)
            } label: {
                Label(option.name, systemImage: "folder")
                    .padding(.leading, CGFloat(option.depth) * 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("totp-enroll.group.\(option.id.uuidString)")
            .macHoverHighlight()
        }
        .navigationTitle("Choose Group")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var readOnlyExplanation: some View {
        ContentUnavailableView {
            Label("Read-Only Database", systemImage: "lock.fill")
        } description: {
            Text("This database is read-only, so the verification code can’t be added to it.")
        }
    }

    #if os(iOS)
    private func editor(_ formViewModel: EntryEditViewModel) -> some View {
        EntryEditView(
            formViewModel: formViewModel,
            databaseViewModel: databaseViewModel
        ) { completion in
            // Clear the editor's presentation state first, so nothing stale
            // survives whichever way the editor completed.
            if case .editor = path.last {
                path.removeLast()
            }
            // Save (or delete) finishes the flow; cancel returns to the
            // destination list so a wrong pick does not destroy the code.
            if completion != .cancelled {
                onFinished()
            }
        }
    }
    #endif

    private func present(editor: EntryEditViewModel) {
        #if os(macOS)
        guard presentation?.beginEnrollmentEditor(editor, in: databaseViewModel) == true else { return }
        onFinished()
        #else
        path.append(.editor(editor))
        #endif
    }

    private func openEditor(attachingTo candidate: TOTPEnrollmentViewModel.EntryCandidate) {
        guard let entry = databaseViewModel.entry(withID: candidate.id),
              let sessionKey = databaseViewModel.sessionKey else { return }
        let editor = EntryEditViewModel(
            editing: entry,
            sessionKey: sessionKey,
            knownTags: databaseViewModel.tagsInDisplayOrder,
            inheritedTags: databaseViewModel.inheritedTags(forEntryID: entry.id)
        )
        editor.applyOTPAuthURI(model.uri)
        present(editor: editor)
    }

    private func openEditorCreating(in groupID: UUID) {
        let editor = EntryEditViewModel(
            createIn: groupID,
            knownTags: databaseViewModel.tagsInDisplayOrder,
            inheritedTags: databaseViewModel.inheritedTags(forGroupID: groupID)
        )
        editor.title = model.prefilledTitle
        editor.username = model.prefilledUsername
        editor.applyOTPAuthURI(model.uri)
        present(editor: editor)
    }
}
