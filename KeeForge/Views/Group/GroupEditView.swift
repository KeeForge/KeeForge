import SwiftUI

/// The group editor: name, icon, tags, notes and Search & AutoFill visibility in
/// one form, applied as a single `updateGroup` edit.
///
/// A plain `Form` with no `NavigationStack` of its own — presenters supply one
/// (a sheet on macOS, a navigation push on iOS), the way `EntryEditView` is
/// presented.
struct GroupEditView: View {
    @State private var formViewModel: GroupEditViewModel
    @Bindable var databaseViewModel: DatabaseViewModel
    let onComplete: () -> Void

    @State private var showDiscardConfirmation = false
    @State private var isShowingIconPicker = false
    @State private var coordinator: DatabaseEditorCoordinator
    @FocusState private var notesFocused: Bool

    private var isSavingInProgress: Bool {
        coordinator.isSavingInProgress
    }

    init(
        formViewModel: GroupEditViewModel,
        databaseViewModel: DatabaseViewModel,
        onComplete: @escaping () -> Void = {}
    ) {
        _formViewModel = State(initialValue: formViewModel)
        _coordinator = State(initialValue: DatabaseEditorCoordinator(group: formViewModel, database: databaseViewModel))
        self.databaseViewModel = databaseViewModel
        self.onComplete = onComplete
    }

    var body: some View {
        Form {
            Section("Basics") {
                fieldRow("Name") {
                    TextField("Group Name", text: $formViewModel.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("group-edit.name-field")
                }

                iconRow

                fieldRow("Tags") {
                    appliedTagStrip

                    // Single-line on purpose: Return has to submit the tag
                    // rather than insert a newline, matching the entry editor.
                    TextField("Add a tag", text: $formViewModel.pendingTagText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { formViewModel.commitPendingTag() }
                        .accessibilityIdentifier("group-edit.tags-field")

                    tagSuggestionStrip
                }
            }

            Section("Notes") {
                TextEditor(text: $formViewModel.notes)
                    .frame(minHeight: 140)
                    .focused($notesFocused)
                    .accessibilityIdentifier("group-edit.notes-field")
            }

            Section("Search & AutoFill") {
                Toggle("Hide from Search & AutoFill", isOn: $formViewModel.isHiddenFromAutoFill)
                    .accessibilityIdentifier("group-edit.autofill-toggle")

                if formViewModel.isExclusionInherited {
                    Text("A parent group is hidden from Search & AutoFill. Turn this off to show this group anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .macGroupedForm()
        .navigationTitle("Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .disabled(isSavingInProgress)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapped()
                }
                .disabled(isSavingInProgress)
                .accessibilityIdentifier("group-edit.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveTapped()
                }
                .disabled(formViewModel.canSave == false || isSavingInProgress)
                .accessibilityIdentifier("group-edit.save")
            }

            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    notesFocused = false
                }
                .accessibilityIdentifier("group-edit.keyboard-done")
            }
            #endif
        }
        .overlay {
            if coordinator.isSubmitting && databaseViewModel.isSaving == false {
                ZStack {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Saving changes...")
                            .font(.headline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.regularMaterial)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving changes")
                .accessibilityIdentifier("group-edit.saving-overlay")
            }
        }
        .sheet(isPresented: $isShowingIconPicker) {
            GroupIconPickerView(
                groupName: formViewModel.trimmedName,
                selectedIconID: formViewModel.iconID
            ) { iconID in
                formViewModel.iconID = iconID
            }
        }
        .onAppear { coordinator.activate() }
        .onChange(of: coordinator.conflictHasSettled) { _, _ in
            coordinator.completeAfterConflictIfSettled { _ in onComplete() }
        }
        .onChange(of: formViewModel.isDirty) { _, _ in
            coordinator.synchronizeUnsavedChanges()
        }
        .onChange(of: pendingEditorLockRequest != nil) { _, isPending in
            // Anything presented above the editor would swallow the prompt.
            guard isPending else { return }
            isShowingIconPicker = false
            showDiscardConfirmation = false
        }
        .onDisappear {
            coordinator.deactivate()
        }
        .alert(
            "Save your changes before locking?",
            isPresented: Binding(
                get: { pendingEditorLockRequest != nil },
                set: { _ in }
            )
        ) {
            Button("Save and Lock") {
                guard let request = pendingEditorLockRequest else { return }
                saveTapped(resuming: request)
            }
            .disabled(formViewModel.canSave == false)
            Button("Discard and Lock", role: .destructive) {
                guard let request = pendingEditorLockRequest else { return }
                coordinator.discard(resuming: request) { _ in onComplete() }
            }
            Button("Keep Editing", role: .cancel) {
                Task { await coordinator.continueEditingAfterLockRequest() }
            }
        } message: {
            Text("Your group changes haven't been saved to this database yet.")
        }
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                coordinator.discard { _ in onComplete() }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your group changes haven't been saved to this database draft yet.")
        }
        .alert(
            "Couldn’t Update Group",
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        coordinator.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    /// The group's standard KDBX icon, presenting the shared picker sheet. A
    /// custom icon is deliberately not previewed here: the payload only carries
    /// a standard `iconID`, and the draft layer keeps the custom icon untouched
    /// unless the user actually picks a different standard one.
    private var iconRow: some View {
        Button {
            isShowingIconPicker = true
        } label: {
            HStack {
                Text("Icon")
                Spacer(minLength: 8)
                StandardIconView(
                    iconID: formViewModel.iconID,
                    fallbackSystemName: "folder.fill",
                    fallbackPalette: .blue
                )
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("group-edit.icon-button")
        .accessibilityValue(String(formViewModel.iconID))
    }

    /// The tags this group already carries, one removable pill each. Nothing
    /// renders before the first tag lands, so an untagged group opens on a plain
    /// field rather than an empty container.
    ///
    /// Declared an accessibility container so the pills keep their own
    /// identifiers instead of inheriting the strip's (see `AGENTS.md`).
    @ViewBuilder
    private var appliedTagStrip: some View {
        if formViewModel.tags.isEmpty == false {
            FlowLayout(spacing: 6) {
                ForEach(Array(formViewModel.tags.enumerated()), id: \.offset) { index, tag in
                    appliedTagChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("group-edit.tags")
        }
    }

    private func appliedTagChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            formViewModel.removeTag(tag)
        } label: {
            TagCapsule(tag: tag, trailingSystemImage: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove tag \(tag)"))
        .accessibilityIdentifier(
            "group-edit.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    /// The database's other tags, one tap each. Nothing at all renders when
    /// there is nothing left to offer.
    @ViewBuilder
    private var tagSuggestionStrip: some View {
        let suggestions = formViewModel.tagSuggestions
        if suggestions.isEmpty == false {
            FlowLayout(spacing: 6) {
                // Enumerated for the identifier fallback index, which is what
                // gives an emoji-only tag — one that normalizes to nothing — a
                // usable identifier.
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, tag in
                    tagSuggestionChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("group-edit.tag-suggestions")
        }
    }

    private func tagSuggestionChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            formViewModel.appendTagSuggestion(tag)
        } label: {
            TagCapsule(tag: tag, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add tag \(tag)"))
        .accessibilityIdentifier(
            "group-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    private func fieldRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .macLabelsHidden()
                .macFormFieldStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func cancelTapped() {
        if formViewModel.isDirty {
            showDiscardConfirmation = true
        } else {
            coordinator.discard { _ in onComplete() }
        }
    }

    private var pendingEditorLockRequest: DatabaseViewModel.PendingLockRequest? {
        coordinator.pendingLockRequest
    }

    private func saveTapped(resuming lockRequest: DatabaseViewModel.PendingLockRequest? = nil) {
        Task { await coordinator.save(resuming: lockRequest) { _ in onComplete() } }
    }
}
